import SwiftUI
import NetlaneCore

/// Two panes: navigation on the left, the page on the right.
struct MainWindow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar().frame(width: 196)
            Rectangle().fill(Theme.line).frame(width: 1)
            ZStack(alignment: .bottom) {
                page.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if let notice = model.notice {
                    Text(notice)
                        .font(.system(size: 12)).foregroundColor(Theme.ink)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.raised))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.lineStrong))
                        .padding(.horizontal, 24).padding(.bottom, 40)
                        .onTapGesture { model.notice = nil }
                        .transition(.opacity)
                }
            }
        }
        .background(Theme.ground)
        .foregroundColor(Theme.ink)
        .frame(minWidth: 860, minHeight: 520)
        .preferredColorScheme(.dark)
        .animation(.easeOut(duration: 0.15), value: model.notice)
        .sheet(isPresented: $model.showAdd) { AddSheet().environmentObject(model) }
        .sheet(isPresented: $model.showUpdate) { UpdateSheet().environmentObject(model) }
        .confirmationDialog("Сервер уже добавлен", isPresented: Binding(get: { model.pendingDuplicate != nil }, set: { if !$0 { model.pendingDuplicate = nil } }), presenting: model.pendingDuplicate) { server in
            Button("Обновить существующий") { model.finishAdd(server, .update) }
            Button("Добавить копию") { model.finishAdd(server, .addCopy) }
            Button("Отмена", role: .cancel) { model.pendingDuplicate = nil }
        } message: { server in
            Text("Сервер " + server.hostname + " с пользователем " + server.username + " уже есть в списке.")
        }
    }

    @ViewBuilder private var page: some View {
        switch model.page {
        case .home: HomeView()
        case .rules: RulesView()
        case .servers: ServersView()
        case .settings: SettingsView()
        case .log: LogView()
        case .about: AboutView()
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Page.allCases) { page in
                Button(action: { model.page = page }) {
                    HStack(spacing: 12) {
                        Image(systemName: page.symbol)
                            .font(.system(size: 14))
                            .foregroundColor(model.page == page ? Theme.accent : Theme.faint)
                            .frame(width: 20)
                        Text(page.title).font(.system(size: 14)).foregroundColor(model.page == page ? Theme.ink : Theme.muted)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 9).fill(model.page == page ? Theme.selection : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if let update = model.update {
                Button("Доступна v" + update.version) { model.showUpdate = true }
                    .buttonStyle(LinkButtonStyle()).padding(.horizontal, 12).padding(.bottom, 8)
            }
            Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, 4)
            let account = model.accountLine
            Button(action: accountTapped) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.title).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.ink).lineLimit(1)
                    Text(account.detail).font(.system(size: 11)).foregroundColor(Theme.level(account.level)).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.state.subscription(of: model.selectedServer) == nil ? "Сервер добавлен вручную." : "Обновить подписку")
        }
        .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 10)
        .background(Theme.card)
    }

    private func accountTapped() {
        if let subscription = model.state.subscription(of: model.selectedServer) { model.refresh(subscription: subscription.id, announce: true) }
        else if model.selectedServer == nil { model.showAdd = true }
    }
}

/// «Добавить подписку или сервер»: a link is pasted, or a TOML profile is opened.
struct AddSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Добавить подписку или сервер", subtitle: "Вставьте ссылку подписки https://…/sub/… из панели. Один сервер по ссылке tt:// тоже подойдёт. Ссылку выдаёт администратор сервера.")
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 96)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
            HStack(spacing: 8) {
                Button("Вставить из буфера") { text = NSPasteboard.general.string(forType: .string) ?? "" }.buttonStyle(QuietButtonStyle())
                Button("Открыть файл TOML…", action: openFile).buttonStyle(QuietButtonStyle())
                Spacer()
                Button("Отмена") { dismiss() }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Добавить") { if model.add(text: text) { dismiss() } }
                    .buttonStyle(QuietButtonStyle(tint: Theme.accent)).keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let notice = model.notice { Text(notice).font(.system(size: 11)).foregroundColor(Theme.warning).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(22)
        .frame(width: 520)
        .background(Theme.ground)
        .preferredColorScheme(.dark)
        .onAppear { if let pasted = NSPasteboard.general.string(forType: .string), pasted.hasPrefix("tt://?") || Subscription.looksLikeUrl(pasted) { text = pasted.trimmingCharacters(in: .whitespacesAndNewlines) } }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.title = "Профиль TrustTunnel (*.toml)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 32768, let content = try? String(contentsOf: url, encoding: .utf8) else {
            model.say("Не удалось открыть TOML. Нужен профиль, экспортированный панелью."); return
        }
        text = content
    }
}

struct UpdateSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Доступна версия " + (model.update?.version ?? ""), subtitle: "Установлена " + AppInfo.version + ". Архив проверяется по SHA-256, после установки Netlane откроется снова.")
            if let notes = model.update?.notes { Text(notes).font(.system(size: 12)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true) }
            if let status = model.updateStatus, model.installingUpdate || status.contains("Не удалось") || status.contains("Перенесите") || status.contains("сумма") {
                Text(status).font(.system(size: 11)).foregroundColor(Theme.warning).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Страница релизов") { if let url = URL(string: UpdateFeed.releasesPage) { NSWorkspace.shared.open(url) } }.buttonStyle(LinkButtonStyle())
                Spacer()
                Button("Позже") { model.postponeUpdate(); dismiss() }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                Button(model.installingUpdate ? "Устанавливаю…" : "Обновить") { model.installUpdate() }
                    .buttonStyle(QuietButtonStyle(tint: Theme.accent)).keyboardShortcut(.defaultAction).disabled(model.installingUpdate)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(Theme.ground)
        .preferredColorScheme(.dark)
    }
}
