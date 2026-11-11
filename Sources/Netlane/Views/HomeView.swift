import SwiftUI
import NetlaneCore

/// «Подключение»: status and the big button in the middle, the locations under them, and the
/// «Подключение» block on the right. Both columns stay where they are in every state.
struct HomeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 28) {
                VStack(spacing: 0) {
                    StatusBlock()
                    LocationTable().padding(.top, 22)
                }
                .frame(minWidth: 340, idealWidth: 360, maxWidth: 400)
                Group {
                    if model.view == .error { ErrorBlock() } else { ConnectionBlock() }
                }
                .frame(width: 276)
                .padding(.top, 14)
            }
            .padding(.horizontal, 24).padding(.top, 26)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, 24)
            HStack {
                Text("v" + AppInfo.version)
                Spacer()
                Text("Профиль хранится только на этом Mac")
            }
            .font(.system(size: 11)).foregroundColor(Theme.faint)
            .padding(.horizontal, 26).frame(height: 32)
        }
    }
}

private struct StatusBlock: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    if model.view == .connected { Circle().fill(Theme.protected.opacity(0.2)).frame(width: 20, height: 20) }
                    Circle().fill(Theme.dot(model.view)).frame(width: 10, height: 10)
                }
                .frame(width: 20, height: 20)
                Text(model.statusTitle).font(.system(size: 24, weight: .semibold)).foregroundColor(Theme.ink)
            }
            Text(model.statusSubtitle)
                .font(.system(size: 12)).foregroundColor(model.view == .error ? Theme.danger : Theme.muted)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            Button(action: { model.toggle() }) { Text(buttonTitle) }
                .buttonStyle(PrimaryButtonStyle(fill: stopping ? Theme.stop : Theme.accent, ink: stopping ? .white : Theme.accentInk))
                .disabled(model.view == .disconnecting)
                .keyboardShortcut(.defaultAction)
                .frame(width: 240)
                .padding(.top, 18)
            Text(model.sessionLine ?? " ")
                .font(.system(size: 11)).foregroundColor(Theme.muted).monospacedDigit()
                .padding(.top, 14)
        }
        .frame(maxWidth: .infinity)
    }

    private var stopping: Bool {
        let active: [ConnectionView] = [.connecting, .connected, .reconnecting, .killSwitch, .disconnecting]
        return active.contains(model.view)
    }
    private var buttonTitle: String {
        switch model.view {
        case .noProfile: return "Добавить сервер"
        case .idle: return "Подключиться"
        case .error: return "Повторить"
        case .connecting: return "Отменить"
        default: return "Отключиться"
        }
    }
}

/// Locations: flag, name, transport, ping. A click selects (and switches a running VPN).
private struct LocationTable: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Локация").frame(maxWidth: .infinity, alignment: .leading)
                Text("Транспорт").frame(width: 84, alignment: .leading)
                Text("Пинг").frame(width: 46, alignment: .trailing)
                Button(action: { model.checkPings() }) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(model.pinging ? 360 : 0))
                        .animation(model.pinging ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: model.pinging)
                }
                .buttonStyle(.plain).frame(width: 22).disabled(model.pinging || model.state.servers.isEmpty)
                .help(model.pinging ? "Проверяю пинг…" : "Проверить пинг всех серверов")
            }
            .font(.system(size: 11)).foregroundColor(Theme.faint)
            .padding(.horizontal, 12).frame(height: 26)
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.state.servers) { server in row(server) }
                    Button(action: { model.showAdd = true }) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.accent)
                            Text("Добавить подписку или сервер").font(.system(size: 12)).foregroundColor(Theme.muted)
                        }
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                    HStack {
                        Text(pingNote).font(.system(size: 11)).foregroundColor(Theme.faint)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.top, 6)
                }
                .padding(.top, 4)
            }
        }
    }

    private var pingNote: String {
        if model.pinging { return "Проверяю пинг…" }
        guard let at = model.pingCheckedAt else { return " " }
        return "Пинг проверен " + SessionStats.ago(model.now.timeIntervalSince(at))
    }

    private func row(_ server: Server) -> some View {
        let selected = server.id == model.state.selectedServerId
        let ping = model.pings[server.id]
        let answered = ping?.milliseconds != nil
        let pingText: String = ping == nil ? "—" : answered ? "\(ping?.milliseconds ?? 0) мс" : "нет ответа"
        return Button(action: { model.select(server: server.id) }) {
            HStack(spacing: 0) {
                Text(ServerName.flag(server.country) ?? "🌐").font(.system(size: 16)).frame(width: 30, alignment: .leading)
                Text(server.name).font(.system(size: 13, weight: selected ? .semibold : .regular)).foregroundColor(server.orphaned ? Theme.faint : Theme.ink).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(Server.transportTitle(server.isAuto ? "auto" : server.effectiveTransport)).font(.system(size: 12)).foregroundColor(Theme.muted).frame(width: 84, alignment: .leading)
                Text(pingText)
                    .font(.system(size: 12)).foregroundColor(ping != nil && !answered ? Theme.faint : Theme.ink).monospacedDigit()
                    .frame(width: 68, alignment: .trailing)
            }
            .padding(.horizontal, 12).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.selection : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(ping?.detail ?? "")
        .contextMenu {
            Button("Проверить пинг") { model.checkPings() }
            Button("Открыть «Серверы»") { model.page = .servers }
        }
    }
}

/// The right column: how the session is set up, and its speed while it runs.
private struct ConnectionBlock: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: "Подключение")
            row("Ваш IP") {
                let line = model.ipLine
                Button(action: { if line.canRetry { model.refreshIp() } }) {
                    Text(line.text).font(.system(size: 12)).foregroundColor(Theme.muted).lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.plain).help(line.hint)
            }
            row("Набор правил") {
                Menu {
                    ForEach(model.state.availableRuleSets) { set in
                        Button(action: { model.select(ruleSet: set.id) }) {
                            if set.id == model.state.selectedRuleSet.id { Label(set.name, systemImage: "checkmark") } else { Text(set.name) }
                        }
                    }
                    Divider()
                    Button("Настроить наборы…") { model.page = .rules }
                } label: {
                    Text(model.state.selectedRuleSet.name).font(.system(size: 12)).lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 150, alignment: .trailing)
                .help("Набор правил маршрутизации. Переключение во время работы VPN переподключает его.")
            }
            if let server = model.selectedServer {
                row("Транспорт") {
                    SegmentedChoice(options: [Choice("auto", "Авто"), Choice("http2", "HTTP/2"), Choice("http3", "HTTP/3")],
                                    selected: server.isAuto ? "auto" : server.effectiveTransport) { model.setTransport($0, for: server.id) }
                        .frame(width: 192)
                        .help("Авто: сначала HTTP/3, а если сеть его не пропускает — HTTP/2; удачный запоминается. HTTP/3 (QUIC, UDP) ровнее для звонков и видео, HTTP/2 (TCP) — если сеть режет UDP. Во время работы VPN переключение переподключает его.")
                }
            }
            row("DNS") {
                let dns = model.state.effectiveDns(for: model.selectedServer)
                Button(dns.managed ? "от администратора" : dns.servers.isEmpty ? "стандартный" : "личный") { model.page = .settings }
                    .buttonStyle(LinkButtonStyle()).help(dns.servers.isEmpty ? "Настроить DNS" : dns.servers.joined(separator: ", "))
            }
            row("Kill Switch") {
                Toggle("", isOn: Binding(get: { model.state.killSwitch }, set: { model.setKillSwitch($0) }))
                    .toggleStyle(.switch).labelsHidden().tint(Theme.accent)
                    .help("Блокировать интернет, если VPN оборвался. Применяется при следующем подключении.")
            }
            if model.view == .connected || model.view == .reconnecting {
                VStack(spacing: 10) {
                    SpeedLane(title: "Приём", arrow: "↓", color: Theme.accent, values: model.downHistory, current: model.downRate)
                    SpeedLane(title: "Отдача", arrow: "↑", color: Theme.upload, values: model.upHistory, current: model.upRate)
                }
                .padding(.top, 12)
            }
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).font(.system(size: 13)).foregroundColor(Theme.ink)
            Spacer(minLength: 8)
            content()
        }
        .frame(height: 36)
    }
}

/// Instead of the right column when the connection failed: what happened and what to try.
private struct ErrorBlock: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Что случилось")
            Text(model.errorText ?? "Соединение не установлено.").font(.system(size: 12)).foregroundColor(Theme.ink).fixedSize(horizontal: false, vertical: true)
            Text("Что попробовать").font(.system(size: 11)).foregroundColor(Theme.faint).padding(.top, 4)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(["Обновите подписку: доступ или адрес сервера могли измениться.", "Смените транспорт: HTTP/2, если сеть режет UDP.", "Выберите другую локацию.", "Проверьте срок доступа и остаток трафика на странице «Серверы»."], id: \.self) { tip in
                    Text("· " + tip).font(.system(size: 12)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let last = model.log.last(where: { $0.isError }) {
                Text(last.text).font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.danger).lineLimit(4).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
            }
            HStack(spacing: 8) {
                if let server = model.selectedServer {
                    Menu("Сменить транспорт…") {
                        Button("Авто") { model.setTransport("auto", for: server.id) }
                        Button("HTTP/2") { model.setTransport("http2", for: server.id) }
                        Button("HTTP/3") { model.setTransport("http3", for: server.id) }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                Spacer()
                Button("Журнал") { model.page = .log }.buttonStyle(LinkButtonStyle())
            }
            .padding(.top, 2)
        }
    }
}
