import AppKit
import SwiftUI
import UserNotifications
import NetlaneCore

enum ConnectionView: Equatable { case noProfile, idle, connecting, connected, reconnecting, killSwitch, error, disconnecting }
enum Page: String, CaseIterable, Identifiable {
    case home, rules, servers, settings, log, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "Подключение"
        case .rules: return "Правила"
        case .servers: return "Серверы"
        case .settings: return "Настройки"
        case .log: return "Журнал"
        case .about: return "О программе"
        }
    }
    var symbol: String {
        switch self {
        case .home: return "power"
        case .rules: return "arrow.triangle.branch"
        case .servers: return "server.rack"
        case .settings: return "gearshape"
        case .log: return "list.bullet"
        case .about: return "info.circle"
        }
    }
}

enum IpState: Equatable { case unknown, loading, known(PublicIp), failed }
enum HelperState: Equatable { case checking, missing, outdated(String), ready }
struct PingValue: Equatable { var milliseconds: Int?; var detail: String }
struct LogLine: Identifiable { let id: Int; let text: String; let isError: Bool }

/// Everything the windows show and do. Lives on the main actor; slow work runs in tasks.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state: ClientState
    @Published var page: Page = .home
    @Published private(set) var view: ConnectionView = .idle
    @Published private(set) var errorText: String?
    @Published private(set) var reconnectSeconds = 0
    @Published private(set) var sessionStart: Date?
    @Published private(set) var now = Date()
    @Published private(set) var traffic: (down: Int64, up: Int64)?
    @Published private(set) var downRate = 0.0
    @Published private(set) var upRate = 0.0
    @Published private(set) var downHistory: [Double] = []
    @Published private(set) var upHistory: [Double] = []
    @Published private(set) var pings: [String: PingValue] = [:]
    @Published private(set) var pinging = false
    @Published private(set) var pingCheckedAt: Date?
    @Published private(set) var ip: IpState = .unknown
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var helper: HelperState = .checking
    @Published private(set) var refreshing: Set<String> = []
    @Published var notice: String?
    @Published var showAdd = false
    @Published var pendingDuplicate: Server?
    @Published private(set) var update: UpdateManifest?
    @Published var showUpdate = false
    @Published private(set) var updateStatus: String?
    @Published private(set) var installingUpdate = false
    /// The rule set opened on «Правила».
    @Published var editedRuleSetId: String?

    private var session: HelperSession?
    private var connectedServerId: String?
    private var wantStop = false
    private var restartAfterStop = false
    private var sawFailure = false
    private var triedFallback = false
    private var fallbackServerId: String?
    private var tunnel: String?
    private var meter = TrafficMeter()
    private var meterStarted = false
    private var ticker: Timer?
    private var noticeTask: Task<Void, Never>?
    private var autoTask: Task<Void, Never>?
    private var logCounter = 0
    private var lastSubscriptionCheck = Date.distantPast
    let startHidden = CommandLine.arguments.contains("--hidden")

    /// For `--render`: the given state, no disk, no timers, no network.
    init(demo: ClientState) {
        state = demo
        view = demo.selectedServer == nil ? .noProfile : .idle
    }

    init() {
        let loaded = StateStore.load()
        state = loaded.state
        view = loaded.state.selectedServer == nil ? .noProfile : .idle
        if let notice = loaded.notice { self.notice = notice }
        if state.openAtLogin { try? LoginItem.set(true) }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        Task { await self.start() }
    }

    private func start() async {
        refreshHelper()
        refreshIp()
        checkPings()
        refreshDueSubscriptions()
        if state.autoConnect && state.selectedServer != nil { connect() }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await checkForUpdates(manual: false)
    }

    // MARK: State

    var selectedServer: Server? { state.selectedServer }
    var isActive: Bool { session != nil }

    /// Applies a change to the stored state, saves it and reports a problem as a notice.
    @discardableResult
    func change(_ work: (inout ClientState) throws -> Void) -> Bool {
        var copy = state
        do {
            try work(&copy)
            try copy.validate()
            try StateStore.save(copy)
            state = copy
            // A change while connecting (helper prompt) or stopping must not reset the shown state.
            if !isActive && view != .connecting && view != .disconnecting { view = state.selectedServer == nil ? .noProfile : (view == .error ? .error : .idle) }
            return true
        } catch {
            say((error as? FormatError)?.message ?? "Не удалось сохранить настройки.")
            return false
        }
    }

    func say(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if !Task.isCancelled { self?.notice = nil }
        }
    }

    private func append(_ text: String) {
        for piece in text.split(separator: "\n", omittingEmptySubsequences: true) {
            logCounter += 1
            let line = String(piece)
            log.append(LogLine(id: logCounter, text: line, isError: line.contains(" ERROR ") || EngineEvent.isFailure(line)))
        }
        if log.count > 1500 { log.removeFirst(log.count - 1200) }
        EngineLog.write(text)
    }
    func clearLog() { log.removeAll() }
    var logText: String { log.map(\.text).joined(separator: "\n") }

    // MARK: Connection

    var statusTitle: String {
        switch view {
        case .noProfile: return "Добавьте сервер"
        case .idle: return "Не подключено"
        case .connecting: return "Подключение…"
        case .connected: return "Защищено"
        case .reconnecting: return "Переподключение…"
        case .killSwitch: return "Интернет заблокирован"
        case .error: return "Не удалось подключиться"
        case .disconnecting: return "Отключение…"
        }
    }

    var statusSubtitle: String {
        guard let server = selectedServer else {
            if let blocked = state.subscriptions.first(where: { Account.blocked($0) }), let reason = Account.reason(blocked) { return "Подписка не даёт серверов: " + reason }
            return "Вставьте ссылку подписки или сервера"
        }
        switch view {
        case .connecting: return "Ожидаем подтверждения от VPN-сервера…"
        case .disconnecting: return "Движок завершает соединение."
        case .reconnecting: return "Восстанавливаем соединение" + (reconnectSeconds > 0 ? ": следующая попытка через \(reconnectSeconds) с" : "")
        case .killSwitch: return "Нажмите «Отключиться», чтобы снять блокировку интернета."
        case .error: return errorText ?? "Соединение не установлено. Проверьте доступ, срок, квоту и выбранный транспорт."
        default:
            var parts = [server.name, Server.transportTitle(server.effectiveTransport) + (server.isAuto ? " (авто)" : "")]
            if let ms = pings[server.id]?.milliseconds { parts.append("\(ms) мс") }
            return parts.joined(separator: " · ")
        }
    }

    var sessionLine: String? {
        if let start = sessionStart, view == .connected || view == .reconnecting || view == .killSwitch {
            return "В сети " + SessionStats.line(seconds: Int64(now.timeIntervalSince(start)), traffic: traffic)
        }
        guard !isActive, state.lastSessionEnd != nil, state.lastSessionSeconds > 0 || state.lastSessionDown > 0 else { return nil }
        var line = "Последняя сессия: " + SessionStats.span(state.lastSessionSeconds)
        if state.lastSessionDown > 0 || state.lastSessionUp > 0 { line += " · ↓ " + SessionStats.bytes(state.lastSessionDown) + " · ↑ " + SessionStats.bytes(state.lastSessionUp) }
        return line
    }

    func toggle() {
        switch view {
        case .noProfile: showAdd = true
        case .idle, .error: connect()
        case .connecting, .connected, .reconnecting, .killSwitch: disconnect()
        case .disconnecting: break
        }
    }

    func connect() {
        guard session == nil else { say("Движок ещё завершает работу. Повторите подключение через несколько секунд."); return }
        guard let server = state.selectedServer else { showAdd = true; return }
        let profile: Profile
        do { profile = try state.sessionProfile() }
        catch { fail((error as? FormatError)?.message ?? "Профиль не прошёл проверку."); return }
        view = .connecting; errorText = nil; sawFailure = false; wantStop = false; restartAfterStop = false
        Task {
            // The helper is installed at the first connection and replaced after an update.
            let status = await Task.detached { Helper.status() }.value
            if status != .ready {
                self.helper = status == .missing ? .missing : .outdated("")
                do { try await Task.detached { try Helper.install() }.value }
                catch Helper.InstallError.cancelled { self.fail("Запрос прав администратора отменён. VPN не включён."); return }
                catch Helper.InstallError.failed(let why) { self.fail("Не удалось установить помощник: " + why); return }
                catch { self.fail("Не удалось установить помощник."); return }
            }
            self.helper = .ready
            guard self.view == .connecting, self.session == nil else { return }
            self.open(profile, server)
        }
    }

    private func open(_ profile: Profile, _ server: Server) {
        EngineLog.start("connect transport=" + profile.transport + " app=" + AppInfo.version + " engine=" + EngineSpec.version)
        tunnel = nil; meterStarted = false; traffic = nil; downHistory = []; upHistory = []; downRate = 0; upRate = 0
        connectedServerId = server.id
        session = HelperSession(profile: profile, onMessage: { [weak self] message in self?.handle(message) }, onEnd: { [weak self] in self?.ended() })
        if session == nil { connectedServerId = nil; fail("Помощник не отвечает. Переустановите его в «Настройках»."); return }
        // «Авто»: HTTP/3 first; if it has not connected in 15 seconds, HTTP/2.
        autoTask?.cancel()
        if server.isAuto && profile.transport == "http3" && !triedFallback {
            autoTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled, let self = self, self.view == .connecting else { return }
                self.fallBackToHttp2()
            }
        }
    }

    private func fallBackToHttp2() {
        guard let id = connectedServerId, !triedFallback else { return }
        triedFallback = true; fallbackServerId = id
        append("Netlane: HTTP/3 не подключился, пробуем HTTP/2")
        change { try $0.updateServer(id) { $0.autoTransport = "http2" } }
        restartAfterStop = true
        wantStop = true
        session?.stop()
    }

    private func handle(_ message: HelperProtocol.Message) {
        switch message {
        case .log(let line): append(line)
        case .tunnel(let name): tunnel = name
        case .event(let event, let detail):
            switch event {
            case .started: break
            case .connected:
                autoTask?.cancel()
                view = .connected; errorText = nil; sawFailure = false
                if sessionStart == nil { sessionStart = Date() }
                if let id = connectedServerId, let server = state.servers.first(where: { $0.id == id }), server.isAuto, server.autoTransport != server.effectiveTransport {
                    let used = server.effectiveTransport
                    change { try $0.updateServer(id) { $0.autoTransport = used } }
                }
                triedFallback = false
                refreshIp(after: 1.5)
            case .reconnecting:
                if view == .connected || view == .reconnecting { view = .reconnecting; reconnectSeconds = Int(detail ?? "") ?? 0 }
            case .killSwitch: view = .killSwitch
            case .connectionError:
                sawFailure = true
                if view == .connecting, let id = connectedServerId, let server = state.servers.first(where: { $0.id == id }), server.isAuto, server.effectiveTransport == "http3", !triedFallback { fallBackToHttp2() }
            case .stopping: if !restartAfterStop { view = .disconnecting }
            case .stopFailed: say("Движок ещё завершает работу. Дождитесь отключения.")
            case .busy: errorText = "Помощник уже занят другой сессией VPN. Подождите несколько секунд и повторите."; sawFailure = true
            case .helperError: errorText = detail ?? "Помощник сообщил об ошибке."; sawFailure = true
            case .stopped: break
            }
        default: break
        }
    }

    /// The helper closed the socket: the engine is gone, whatever the reason.
    private func ended() {
        session = nil
        autoTask?.cancel()
        let wasConnected = sessionStart != nil
        if let start = sessionStart {
            let seconds = Int64(Date().timeIntervalSince(start)), totals = traffic, name = state.servers.first { $0.id == connectedServerId }?.name
            change {
                $0.lastSessionEnd = Account.formatDate(Date()); $0.lastSessionSeconds = seconds
                $0.lastSessionDown = totals?.down ?? 0; $0.lastSessionUp = totals?.up ?? 0; $0.lastSessionServer = name
            }
        }
        sessionStart = nil; connectedServerId = nil; tunnel = nil; downRate = 0; upRate = 0
        change { $0.dropOrphans() }
        if restartAfterStop {
            restartAfterStop = false; wantStop = false
            if state.selectedServer != nil { connect(); return }
        }
        if wantStop { view = state.selectedServer == nil ? .noProfile : .idle; triedFallback = false }
        else if sawFailure || !wasConnected { fail(errorText ?? "Соединение не установлено. Проверьте доступ, срок, квоту и выбранный транспорт.") }
        else { fail("Соединение прервано: движок остановился. Подробности — в «Журнале».") }
        wantStop = false
        refreshIp(after: 1.5)
    }

    private func fail(_ text: String) {
        errorText = text
        view = .error
        // «Авто» fell back to HTTP/2 and that failed too: the next attempt starts from HTTP/3 again.
        if triedFallback, let id = fallbackServerId, state.servers.contains(where: { $0.id == id }) { change { try $0.updateServer(id) { $0.autoTransport = nil } } }
        fallbackServerId = nil
        triedFallback = false
    }

    func disconnect() {
        guard let session = session else { view = state.selectedServer == nil ? .noProfile : .idle; return }
        wantStop = true; restartAfterStop = false
        view = .disconnecting
        autoTask?.cancel()
        session.stop()
    }

    /// A change that matters to a running session (server, rules, transport) restarts it.
    private func restartIfActive(_ why: String) {
        guard let session = session, !(wantStop && !restartAfterStop) else { return }
        say(why)
        triedFallback = false
        restartAfterStop = true; wantStop = true
        view = .connecting
        autoTask?.cancel()
        session.stop()
    }

    func select(server id: String) {
        guard id != state.selectedServerId else { return }
        let name = state.servers.first { $0.id == id }?.name ?? ""
        if change({ try $0.selectServer(id) }) {
            if view == .error { view = .idle; errorText = nil }
            restartIfActive("Переключаю на «" + name + "»…")
        }
    }

    func select(ruleSet id: String) {
        guard id != state.selectedRuleSetId else { return }
        if change({ try $0.selectRuleSet(id) }) { restartIfActive("Набор правил изменён: VPN переподключается.") }
    }

    /// nil follows the profile; "auto", "http2" or "http3" is the user's choice.
    func setTransport(_ value: String?, for id: String) {
        guard let server = state.servers.first(where: { $0.id == id }), server.chosenTransport != value else { return }
        if change({ try $0.updateServer(id) { $0.chosenTransport = value; if value == "auto" { $0.autoTransport = nil } } }), id == connectedServerId {
            restartIfActive("Транспорт изменён: VPN переподключается.")
        }
    }

    func setKillSwitch(_ on: Bool) {
        if change({ $0.killSwitch = on }), isActive { say("Kill Switch применится при следующем подключении.") }
    }

    // MARK: Once a second

    private func tick() {
        now = Date()
        if view == .connected || view == .reconnecting {
            if let name = tunnel, let counters = Traffic.counters(of: name) {
                if !meterStarted { meter.start(received: counters.received, sent: counters.sent); meterStarted = true }
                meter.update(received: counters.received, sent: counters.sent, time: ProcessInfo.processInfo.systemUptime)
                traffic = (meter.down, meter.up); downRate = meter.downRate; upRate = meter.upRate
                downHistory.append(meter.downRate); upHistory.append(meter.upRate)
                if downHistory.count > 60 { downHistory.removeFirst(); upHistory.removeFirst() }
            }
        }
        if now.timeIntervalSince(lastSubscriptionCheck) > 600 { refreshDueSubscriptions() }
    }

    // MARK: Ping and public IP

    func checkPings() {
        guard !pinging, !state.servers.isEmpty else { return }
        pinging = true
        let servers = state.servers
        Task {
            await withTaskGroup(of: (String, Latency.Result).self) { group in
                for server in servers { group.addTask { (server.id, await Latency.measure(server.toProfile())) } }
                for await (id, result) in group { self.pings[id] = PingValue(milliseconds: result.milliseconds, detail: result.detail) }
            }
            self.pinging = false
            self.pingCheckedAt = Date()
        }
    }

    func refreshIp(after delay: Double = 0) {
        guard !state.hidePublicIp else { ip = .unknown; return }
        ip = .loading
        Task {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            do { self.ip = .known(try await Net.publicIp()) } catch { self.ip = .failed }
        }
    }

    /// The «Ваш IP» value and its explanation.
    var ipLine: (text: String, hint: String, canRetry: Bool) {
        if state.hidePublicIp { return ("не проверяется", "Проверка внешнего IP выключена в «Настройках».", false) }
        let set = state.selectedRuleSet
        if view == .connected && set.routing.mode == "selective" {
            return ("только для «" + set.name + "»", "Через VPN идут только адреса набора «" + set.name + "»: они видят IP сервера, остальные сайты — ваш обычный IP.", false)
        }
        switch ip {
        case .loading, .unknown: return ("проверяю…", "", false)
        case .failed: return ("не удалось проверить", "Щёлкните, чтобы проверить ещё раз.", true)
        case .known(let value): return (value.text, view == .connected ? "Так вас видят сайты: адрес VPN-сервера." : "VPN выключен: сайты видят ваш обычный IP.", true)
        }
    }

    // MARK: Servers and subscriptions

    /// «Вставить»: a subscription link, a tt:// link or a TOML profile. Returns true when something was added.
    @discardableResult
    func add(text raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { say("Нет ссылки tt:// или ссылки подписки."); return false }
        if text.lowercased().hasPrefix("http") {
            guard Subscription.looksLikeUrl(text) else { say("Это не ссылка подписки: нужна ссылка https://…/sub/… из панели."); return false }
            var created: Subscription?
            guard change({ created = try $0.addSubscription(text) }), let subscription = created else { return false }
            refresh(subscription: subscription.id, announce: true)
            return true
        }
        do {
            let server = Server.from(try Profile.import(text))
            if state.findDuplicate(server) != nil { pendingDuplicate = server; return true }
            return finishAdd(server, .addCopy)
        } catch {
            say((error as? FormatError)?.message ?? "Не удалось импортировать профиль.")
            return false
        }
    }

    @discardableResult
    func finishAdd(_ server: Server, _ choice: DuplicateChoice) -> Bool {
        pendingDuplicate = nil
        guard change({ try $0.addServer(server, choice) }) else { return false }
        say("Сервер «" + server.name + "» добавлен.")
        checkPings()
        return true
    }

    func remove(server id: String) {
        if id == connectedServerId { say("Сначала отключитесь от этого сервера."); return }
        change { try $0.removeServer(id) }
    }
    func rename(server id: String, to name: String) {
        change { try $0.updateServer(id) { $0.name = name.trimmingCharacters(in: .whitespaces) } }
    }

    func refresh(subscription id: String, announce: Bool) {
        guard let subscription = state.subscriptions.first(where: { $0.id == id }), !refreshing.contains(id) else { return }
        refreshing.insert(id)
        Task {
            defer { self.refreshing.remove(id) }
            do {
                let feed = try SubscriptionFeed.parse(try await Net.subscription(subscription.url))
                var result = FeedResult()
                let connected = self.connectedServerId
                guard self.change({ result = try $0.applyFeed(id, feed, connectedServerId: connected) }) else { return }
                if announce {
                    if feed.servers.isEmpty, let sub = self.state.subscriptions.first(where: { $0.id == id }), let reason = Account.reason(sub) { self.say("Подписка не даёт серверов: " + reason + ".") }
                    else { self.say(result.added > 0 ? "Подписка обновлена: добавлено серверов — \(result.added)." : "Подписка обновлена.") }
                } else if result.settingsChanged && self.isActive { self.say("Правила и DNS подписки обновлены. Применятся при следующем подключении.") }
                if result.currentChanged { self.restartIfActive("Доступ к серверу изменился: VPN переподключается.") }
                if result.added > 0 { self.checkPings() }
                self.warnAboutAccess()
            } catch {
                let why = (error as? FormatError)?.message ?? error.localizedDescription
                self.change { $0.setSubscriptionError(id, why) }
                if announce { self.say("Не удалось загрузить подписку: " + why) }
            }
        }
    }

    private func refreshDueSubscriptions() {
        lastSubscriptionCheck = Date()
        for subscription in state.subscriptions where subscription.isDue(now: Date()) { refresh(subscription: subscription.id, announce: false) }
    }

    func remove(subscription id: String) {
        let connected = connectedServerId
        change { try $0.removeSubscription(id, connectedServerId: connected) }
    }

    /// Once a day: the access ends within three days or the monthly traffic is almost used up.
    private func warnAboutAccess() {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        for subscription in state.subscriptions where subscription.warnedOn != today {
            guard let text = Account.warning(subscription, now: Date()) else { continue }
            change { state in if let i = state.subscriptions.firstIndex(where: { $0.id == subscription.id }) { state.subscriptions[i].warnedOn = today } }
            say(text)
            guard Bundle.main.bundleIdentifier != nil else { continue }
            let center = UNUserNotificationCenter.current()
            center.requestAuthorization(options: [.alert]) { granted, _ in
                guard granted else { return }
                let content = UNMutableNotificationContent()
                content.title = "Netlane"; content.body = text
                center.add(UNNotificationRequest(identifier: "access-" + subscription.id, content: content, trigger: nil))
            }
        }
    }

    /// The line under the name at the bottom of the navigation.
    var accountLine: (title: String, detail: String, level: Account.Level) {
        guard let server = selectedServer else { return ("Netlane", state.subscriptions.isEmpty ? "нет серверов" : "нет серверов в подписке", .normal) }
        guard let subscription = state.subscription(of: server) else { return (server.username, "без подписки", .normal) }
        let summary = Account.summary(subscription, now: now) ?? Plural.locations(state.servers.filter { $0.subscriptionId == subscription.id }.count)
        return (server.username, subscription.lastError == nil ? summary : "подписка не обновилась", subscription.lastError == nil ? Account.level(subscription, now: now) : .warning)
    }

    // MARK: Helper

    func refreshHelper() {
        Task {
            let status = await Task.detached { Helper.status() }.value
            switch status {
            case .missing: self.helper = .missing
            case .outdated(let version): self.helper = .outdated(version)
            case .ready: self.helper = .ready
            }
        }
    }
    func installHelper() {
        guard !isActive else { say("Сначала отключите VPN."); return }
        Task {
            do { try await Task.detached { try Helper.install() }.value; self.say("Помощник установлен.") }
            catch Helper.InstallError.cancelled {}
            catch Helper.InstallError.failed(let why) { self.say("Не удалось установить помощник: " + why) }
            catch { self.say("Не удалось установить помощник.") }
            self.refreshHelper()
        }
    }
    func uninstallHelper() {
        guard !isActive else { say("Сначала отключите VPN."); return }
        Task {
            do { try await Task.detached { try Helper.uninstall() }.value; self.say("Помощник удалён.") }
            catch Helper.InstallError.cancelled {}
            catch Helper.InstallError.failed(let why) { self.say("Не удалось удалить помощник: " + why) }
            catch { self.say("Не удалось удалить помощник.") }
            self.refreshHelper()
        }
    }

    // MARK: Updates

    func checkForUpdates(manual: Bool) async {
        if manual { updateStatus = "Проверяю…" }
        do {
            let manifest = try await Updater.fetchManifest()
            if manifest.isNewer(than: AppInfo.version) {
                update = manifest
                updateStatus = "Доступна версия " + manifest.version + "."
                if manual || state.skippedUpdateVersion != manifest.version { showUpdate = true }
            } else {
                update = nil
                updateStatus = "Установлена последняя версия."
            }
        } catch {
            if manual { updateStatus = "Не удалось проверить обновления: " + ((error as? FormatError)?.message ?? error.localizedDescription) }
        }
    }
    func postponeUpdate() {
        showUpdate = false
        if let version = update?.version { change { $0.skippedUpdateVersion = version } }
    }
    func installUpdate() {
        guard let manifest = update, !installingUpdate else { return }
        installingUpdate = true
        updateStatus = "Скачиваю версию " + manifest.version + "…"
        Task {
            do { try await Updater.install(manifest) { [weak self] stage in self?.updateStatus = stage } }
            catch {
                self.installingUpdate = false
                self.updateStatus = (error as? FormatError)?.message ?? error.localizedDescription
            }
        }
    }
}

extension AppModel {
    /// A connected session with made-up numbers, for the README picture.
    func showDemoSession() {
        now = Date()
        view = .connected
        sessionStart = now.addingTimeInterval(-2537)
        traffic = (1_932_735_283, 220_200_960)
        var down: [Double] = [], up: [Double] = []
        for i in 0..<60 {
            let x = Double(i)
            let downWave: Double = 700_000 * sin(x / 5)
            let downNoise = Double((i * 7919) % 400_000)
            down.append(900_000 + downWave + downNoise)
            let upWave: Double = 80_000 * sin(x / 7 + 1)
            let upNoise = Double((i * 104_729) % 60_000)
            up.append(120_000 + upWave + upNoise)
        }
        downHistory = down
        upHistory = up
        downRate = downHistory.last ?? 0
        upRate = upHistory.last ?? 0
        for (i, server) in state.servers.enumerated() { pings[server.id] = PingValue(milliseconds: [38, 47, 61, 112][i % 4], detail: "") }
        pingCheckedAt = now.addingTimeInterval(-120)
        ip = .known(PublicIp(address: "203.0.113.24", country: "NL"))
        helper = .ready
    }
}

extension Plural {
    static func locations(_ n: Int) -> String { form(n, "локация", "локации", "локаций") }
}
