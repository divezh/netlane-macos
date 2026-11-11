import SwiftUI
import NetlaneCore

/// «Серверы»: subscriptions with their access details, and every server with its transport.
struct ServersView: View {
    @EnvironmentObject var model: AppModel
    @State private var renaming: Server?
    @State private var newName = ""
    @State private var removing: Subscription?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                PageHeader(title: "Серверы")
                Spacer()
                Button(action: { model.showAdd = true }) { Label("Добавить", systemImage: "plus") }.buttonStyle(QuietButtonStyle(tint: Theme.accent))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !model.state.subscriptions.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            SectionTitle(text: "Подписки")
                            ForEach(model.state.subscriptions) { subscription in subscriptionRow(subscription) }
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        SectionTitle(text: "Серверы")
                        if model.state.servers.isEmpty {
                            Text("Серверов пока нет. Нажмите «Добавить» и вставьте ссылку подписки от администратора.")
                                .font(.system(size: 12)).foregroundColor(Theme.muted).padding(.vertical, 10)
                        }
                        ForEach(model.state.servers) { server in serverRow(server) }
                    }
                }
            }
        }
        .padding(24)
        .sheet(item: $renaming) { server in
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: "Название сервера", subtitle: server.hostname)
                TextField("Название", text: $newName).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Отмена") { renaming = nil }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                    Button("Сохранить") { model.rename(server: server.id, to: newName); renaming = nil }
                        .buttonStyle(QuietButtonStyle(tint: Theme.accent)).keyboardShortcut(.defaultAction)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(22).frame(width: 380).background(Theme.ground).preferredColorScheme(.dark)
        }
        .confirmationDialog("Удалить подписку?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { subscription in
            Button("Удалить подписку и её серверы", role: .destructive) { model.remove(subscription: subscription.id); removing = nil }
            Button("Отмена", role: .cancel) { removing = nil }
        } message: { subscription in
            Text("«" + subscription.displayName + "»: её серверы и наборы правил исчезнут из списка.")
        }
    }

    private func subscriptionRow(_ subscription: Subscription) -> some View {
        let busy = model.refreshing.contains(subscription.id)
        let level = Account.level(subscription, now: model.now)
        let tint = level == .normal ? Theme.muted : Theme.level(level)
        let updated = subscription.updatedDate.map { "обновлена " + SessionStats.ago(model.now.timeIntervalSince($0)) } ?? "ещё не загружена"
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(subscription.displayName).font(.system(size: 13, weight: .semibold))
                if let details = Account.details(subscription) {
                    Text(details).font(.system(size: 11)).foregroundColor(tint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(busy ? "обновляется…" : updated + " · каждые " + String(subscription.updateHours) + " ч").font(.system(size: 11)).foregroundColor(Theme.faint)
                if let error = subscription.lastError { Text(error).font(.system(size: 11)).foregroundColor(Theme.danger).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            Button("Обновить") { model.refresh(subscription: subscription.id, announce: true) }.buttonStyle(QuietButtonStyle()).disabled(busy)
            Button("Удалить") { removing = subscription }.buttonStyle(QuietButtonStyle(tint: Theme.danger))
        }
        .padding(.vertical, 8)
    }

    private func serverRow(_ server: Server) -> some View {
        let source = model.state.subscription(of: server)
        let choice = server.chosenTransport ?? "profile"
        let origin = source == nil ? "добавлен вручную" : "подписка «" + (source?.displayName ?? "") + "»"
        let caption = server.hostname + " · " + origin + (server.orphaned ? " · удалён из подписки" : "")
        return HStack(spacing: 10) {
            Text(ServerName.flag(server.country) ?? "🌐").font(.system(size: 16)).frame(width: 26, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name).font(.system(size: 13)).foregroundColor(server.orphaned ? Theme.faint : Theme.ink).lineLimit(1)
                Text(caption)
                    .font(.system(size: 11)).foregroundColor(Theme.faint).lineLimit(1)
            }
            Spacer(minLength: 8)
            DropdownButton(title: choice == "profile" ? Server.transportTitle(server.transport) : Server.transportTitle(choice)) {
                [.item("Как в профиле (" + Server.transportTitle(server.transport) + ")", checked: choice == "profile") { model.setTransport(nil, for: server.id) },
                 .item("Авто", checked: choice == "auto") { model.setTransport("auto", for: server.id) },
                 .item("HTTP/2", checked: choice == "http2") { model.setTransport("http2", for: server.id) },
                 .item("HTTP/3", checked: choice == "http3") { model.setTransport("http3", for: server.id) }]
            }
            Menu {
                Button("Выбрать") { model.select(server: server.id); model.page = .home }
                if source == nil { Button("Переименовать…") { newName = server.name; renaming = server } }
                Button("Удалить", role: .destructive) { model.remove(server: server.id) }.disabled(source != nil)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28)
        }
        .padding(.horizontal, 10).frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 8).fill(server.id == model.state.selectedServerId ? Theme.selection : Color.clear))
    }
}
