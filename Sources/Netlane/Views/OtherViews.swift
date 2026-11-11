import SwiftUI
import NetlaneCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var dns = ""
    @State private var dnsProblem: String?
    @State private var loaded = false

    private func flag(_ path: WritableKeyPath<ClientState, Bool>, after: ((Bool) -> Void)? = nil) -> Binding<Bool> {
        Binding(get: { model.state[keyPath: path] }, set: { value in
            if model.change({ $0[keyPath: path] = value }) { after?(value) }
        })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Настройки")
                group("Защита") {
                    ToggleRow(title: "Kill Switch", detail: "Блокировать интернет, если VPN оборвался. Обычная сеть вернётся после «Отключиться».",
                              isOn: Binding(get: { model.state.killSwitch }, set: { model.setKillSwitch($0) }))
                    ToggleRow(title: "Anti-DPI", detail: "Дополнительные меры против распознавания VPN. Включайте при обрывах и блокировках.", isOn: flag(\.antiDpi))
                    Text("Kill Switch и Anti-DPI применяются при следующем подключении.").font(.system(size: 11)).foregroundColor(Theme.faint)
                }
                group("DNS для VPN") {
                    let effective = model.state.effectiveDns(for: model.selectedServer)
                    if effective.managed {
                        Text("Для выбранного сервера DNS задаёт администратор подписки: " + effective.servers.joined(separator: ", ") + ". Ваш список ниже действует для серверов, добавленных вручную.")
                            .font(.system(size: 11)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    TextEditor(text: $dns)
                        .font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden).padding(8).frame(height: 76)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card)).overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
                    HStack {
                        Text(dnsProblem ?? "По одному в строке: 1.1.1.1, 9.9.9.9:53, tls://dns.example или https://dns.example/dns-query. Пусто — стандартный DNS сервера.")
                            .font(.system(size: 11)).foregroundColor(dnsProblem == nil ? Theme.faint : Theme.danger).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("Сохранить", action: saveDns).buttonStyle(QuietButtonStyle(tint: Theme.accent))
                            .disabled(dns.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } == model.state.dnsServers)
                    }
                }
                group("Конфиденциальность") {
                    ToggleRow(title: "Показывать внешний IP", detail: "Узнавать ваш адрес и страну через cloudflare.com, чтобы показать на главной, как вас видят сайты.",
                              isOn: Binding(get: { !model.state.hidePublicIp }, set: { value in if model.change({ $0.hidePublicIp = !value }) { model.refreshIp() } }))
                }
                group("Запуск") {
                    ToggleRow(title: "Открывать при входе в систему", detail: "Netlane стартует без окна, со значком в строке меню.", isOn: flag(\.openAtLogin) { on in
                        do { try LoginItem.set(on) } catch { model.say("Не удалось изменить автозапуск: " + error.localizedDescription) }
                    })
                    ToggleRow(title: "Подключаться к последнему серверу при запуске", detail: "Сразу включить VPN с выбранным сервером и набором правил.", isOn: flag(\.autoConnect))
                    ToggleRow(title: "Закрытие окна оставляет Netlane в строке меню", detail: "Красная кнопка прячет окно, VPN продолжает работать. Выход — в меню значка или ⌘Q.", isOn: flag(\.keepInMenuBar))
                }
                group("Помощник VPN") {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(helperTitle).font(.system(size: 13))
                            Text("Создавать сетевой туннель в macOS может только администратор. Помощник устанавливается один раз с паролем администратора и затем включает VPN без запросов. Он запускает только движок TrustTunnel, скопированный при установке.")
                                .font(.system(size: 11)).foregroundColor(Theme.faint).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Button(model.helper == .ready ? "Переустановить" : "Установить") { model.installHelper() }.buttonStyle(QuietButtonStyle())
                        if model.helper != .missing && model.helper != .checking { Button("Удалить") { model.uninstallHelper() }.buttonStyle(QuietButtonStyle(tint: Theme.danger)) }
                    }
                    .padding(.vertical, 6)
                }
                group("Обновления") {
                    HStack {
                        Text(model.updateStatus ?? "Версия " + AppInfo.version).font(.system(size: 12)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if model.update != nil { Button("Обновить…") { model.showUpdate = true }.buttonStyle(QuietButtonStyle(tint: Theme.accent)) }
                        Button("Проверить") { Task { await model.checkForUpdates(manual: true) } }.buttonStyle(QuietButtonStyle())
                    }
                    .padding(.vertical, 6)
                }
            }
            .padding(24)
        }
        .onAppear {
            if !loaded { dns = model.state.dnsServers.joined(separator: "\n"); loaded = true }
            model.refreshHelper()
        }
    }

    private var helperTitle: String {
        switch model.helper {
        case .checking: return "Проверяю…"
        case .missing: return "Не установлен: появится при первом подключении"
        case .outdated: return "Установлена другая версия: обновится при подключении"
        case .ready: return "Установлен и работает"
        }
    }

    private func saveDns() {
        do {
            let servers = try DnsSettings.parse(dns)
            dnsProblem = nil
            if model.change({ $0.dnsServers = servers }) {
                dns = servers.joined(separator: "\n")
                if model.isActive { model.say("DNS применится при следующем подключении.") }
            }
        } catch { dnsProblem = (error as? FormatError)?.message ?? error.localizedDescription }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(text: title)
            content()
        }
    }
}

/// «Журнал»: what the engine printed in this run of the app.
struct LogView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                PageHeader(title: "Журнал", subtitle: "Строки журнала движка. Пригодится, если подключение не устанавливается: приложите их к вопросу администратору. Пароль в журнал не попадает.")
                Spacer(minLength: 8)
                Button("Скопировать") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.logText, forType: .string)
                    model.say(model.log.isEmpty ? "Журнал пуст." : "Журнал скопирован в буфер обмена.")
                }.buttonStyle(QuietButtonStyle())
                Button("Показать файл") {
                    if FileManager.default.fileExists(atPath: EngineLog.file.path) { NSWorkspace.shared.activateFileViewerSelecting([EngineLog.file]) } else { model.say("Файл ещё не создан.") }
                }.buttonStyle(QuietButtonStyle())
                Button("Очистить") { model.clearLog() }.buttonStyle(QuietButtonStyle())
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if model.log.isEmpty { Text("Журнал движка пуст.").font(.system(size: 12)).foregroundColor(Theme.faint).padding(4) }
                        ForEach(model.log) { line in
                            Text(line.text).font(.system(size: 11, design: .monospaced)).foregroundColor(line.isError ? Theme.danger : Theme.muted)
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).id(line.id)
                        }
                    }
                    .padding(10)
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                .onAppear { if let last = model.log.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                .onChange(of: model.log.count) { _ in if let last = model.log.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
        .padding(24)
    }
}

struct AboutView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Netlane для macOS").font(.system(size: 20, weight: .semibold))
                    Text("Версия " + AppInfo.version + " · движок TrustTunnel " + EngineSpec.version).font(.system(size: 12)).foregroundColor(Theme.muted)
                }
            }
            Text("VPN-клиент на базе TrustTunnel. Подключается к вашему серверу по ссылке подписки. Телеметрии нет: приложение обращается только к вашим серверам и подпискам, к GitHub за обновлениями и к Cloudflare, чтобы показать внешний IP.")
                .font(.system(size: 12)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 520, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                link("Исходный код и релизы", "https://github.com/" + UpdateFeed.repository)
                link("Движок TrustTunnel (Apache 2.0)", "https://github.com/TrustTunnel/TrustTunnelClient")
                link("Сообщить о проблеме", "https://github.com/" + UpdateFeed.repository + "/issues")
            }
            Text("Лицензия MIT. Сторонние компоненты перечислены в THIRD_PARTY_NOTICES.md.").font(.system(size: 11)).foregroundColor(Theme.faint)
            Spacer()
        }
        .padding(24)
    }

    private func link(_ title: String, _ address: String) -> some View {
        Button(title) { if let url = URL(string: address) { NSWorkspace.shared.open(url) } }.buttonStyle(LinkButtonStyle())
    }
}
