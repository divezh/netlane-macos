import Foundation

/// Profile names from the panel look like «🇳🇱 Амстердам»: a flag, then the name. The country code is
/// kept separately, the same way the Windows client stores it.
public enum ServerName {
    public static func split(_ raw: String?) -> (country: String?, name: String?) {
        guard let raw = raw else { return (nil, nil) }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var country: String?
        let scalars = Array(text.unicodeScalars.prefix(2))
        if scalars.count == 2, scalars.allSatisfy({ $0.value >= 0x1F1E6 && $0.value <= 0x1F1FF }) {
            country = String(scalars.map { Character(UnicodeScalar(UInt8(65 + $0.value - 0x1F1E6))) })
            text = String(String.UnicodeScalarView(text.unicodeScalars.dropFirst(2))).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (country, text.isEmpty ? nil : text)
    }
    /// «NL» → 🇳🇱; nil when the code is not two Latin letters.
    public static func flag(_ country: String?) -> String? {
        guard let country = country, country.count == 2, Text.matches(country, "^[A-Z]{2}$") else { return nil }
        return String(String.UnicodeScalarView(country.unicodeScalars.compactMap { UnicodeScalar(0x1F1E6 + $0.value - 65) }))
    }
}

/// One VPN server. Routing and Kill Switch live in the rule set and the shared options instead.
public struct Server: Codable, Equatable, Identifiable, Sendable {
    public var id = Text.newId()
    public var name = ""
    public var country: String?
    public var hostname = ""
    public var address = ""
    public var username = ""
    public var password = ""
    /// The transport the panel or the profile gives; a subscription refresh overwrites it.
    public var transport = "http2"
    /// The user's choice, kept across refreshes: nil (follow `transport`), "auto", "http2" or "http3".
    public var chosenTransport: String?
    /// In "auto": the transport that last connected (nil → HTTP/3 first).
    public var autoTransport: String?
    /// Servers from a subscription: its id and the node id in its feed; nil when added by hand.
    public var subscriptionId: String?
    public var remoteId: String?
    /// Left its subscription while connected; removed when the session ends.
    public var orphaned = false
    public init() {}

    public var isAuto: Bool { chosenTransport == "auto" }
    /// What the engine is started with.
    public var effectiveTransport: String { chosenTransport == "auto" ? (autoTransport ?? "http3") : (chosenTransport ?? transport) }

    public mutating func validate() throws {
        if !Text.matches(id, "^[0-9a-f]{32}$") { throw FormatError("Повреждённый идентификатор сервера.") }
        try Server.validateName(name)
        if let country = country, !Text.matches(country, "^[A-Z]{2}$") { throw FormatError("Страна сервера — две латинские буквы.") }
        if let chosen = chosenTransport, !["auto", "http2", "http3"].contains(chosen) { chosenTransport = nil }
        if let auto = autoTransport, !["http2", "http3"].contains(auto) { autoTransport = nil }
        if let remote = remoteId, !Text.matches(remote, "^[A-Za-z0-9_-]{1,64}$") { throw FormatError("Повреждённый идентификатор сервера подписки.") }
        var profile = toProfile()
        try profile.validate()
    }
    public static func validateName(_ name: String) throws {
        if Text.isBlank(name) || name.count > 64 || Text.hasControl(name) { throw FormatError("Название сервера — от 1 до 64 символов.") }
    }
    public func toProfile() -> Profile {
        var profile = Profile()
        profile.hostname = hostname; profile.address = address; profile.username = username; profile.password = password
        profile.transport = effectiveTransport; profile.name = name
        return profile
    }
    public static func from(_ profile: Profile) -> Server {
        var server = Server()
        server.hostname = profile.hostname; server.address = profile.address; server.username = profile.username
        server.password = profile.password; server.transport = profile.transport; server.name = defaultName(profile.hostname)
        let parts = ServerName.split(profile.name)
        if let name = parts.name, name.count <= 64, !Text.hasControl(name) { server.name = name }
        server.country = parts.country
        return server
    }
    /// A profile without its own name or flag got the host name: an update must not overwrite a name the user chose.
    var hasOwnName: Bool { country != nil || name != Server.defaultName(hostname) }
    static func defaultName(_ hostname: String) -> String { hostname.count <= 64 ? hostname : String(hostname.prefix(63)) + "…" }
    public static func transportTitle(_ value: String) -> String { value == "http3" ? "HTTP/3" : value == "auto" ? "Авто" : "HTTP/2" }
}

public enum DuplicateChoice { case update, addCopy }

public struct RuleSet: Codable, Equatable, Identifiable, Sendable {
    public var id = Text.newId()
    public var name = ""
    public var builtin = false
    public var subscriptionId: String?
    public var remoteId: String?
    public var routing = Routing()
    public init() {}
    /// Comes from a subscription: the administrator edits it, the user can only copy it.
    public var managed: Bool { subscriptionId != nil }
}

/// Everything the client keeps between runs: servers, rule sets, selections and shared options.
public struct ClientState: Codable, Equatable, Sendable {
    public static let currentVersion = 1, maxServers = 50, maxRuleSets = 20, maxSubscriptions = 10
    public static let builtinName = "Весь трафик"

    public var version = ClientState.currentVersion
    public var servers: [Server] = []
    public var selectedServerId: String?
    public var ruleSets: [RuleSet] = []
    public var selectedRuleSetId: String?
    public var dnsServers: [String] = []
    public var subscriptions: [Subscription] = []
    public var killSwitch = true
    public var antiDpi = false
    public var openAtLogin = false
    public var autoConnect = false
    /// Closing the window keeps the app in the menu bar.
    public var keepInMenuBar = true
    /// Off by default: the public IP is checked through cloudflare.com/cdn-cgi/trace unless turned off.
    public var hidePublicIp = false
    /// The last finished session, shown while disconnected.
    public var lastSessionEnd: String?
    public var lastSessionSeconds: Int64 = 0
    public var lastSessionDown: Int64 = 0
    public var lastSessionUp: Int64 = 0
    public var lastSessionServer: String?
    /// The version the user chose to postpone.
    public var skippedUpdateVersion: String?
    /// DNS entries left out by the last validate(); not stored.
    public var droppedDns: [String] = []

    enum CodingKeys: String, CodingKey {
        case version, servers, selectedServerId, ruleSets, selectedRuleSetId, dnsServers, subscriptions, killSwitch, antiDpi, openAtLogin
        case autoConnect, keepInMenuBar, hidePublicIp, lastSessionEnd, lastSessionSeconds, lastSessionDown, lastSessionUp, lastSessionServer, skippedUpdateVersion
    }

    public init() { ensureBuiltin(); selectedRuleSetId = ruleSets[0].id }

    public var selectedServer: Server? { servers.first { $0.id == selectedServerId } }
    public var builtinRuleSet: RuleSet { ruleSets.first { $0.builtin }! }
    public var selectedRuleSet: RuleSet { availableRuleSets.first { $0.id == selectedRuleSetId } ?? builtinRuleSet }
    /// Own sets plus the sets of the selected server's subscription.
    public var availableRuleSets: [RuleSet] {
        let source = selectedServer?.subscriptionId
        return ruleSets.filter { !$0.managed || $0.subscriptionId == source }
    }
    public func subscription(of server: Server?) -> Subscription? {
        guard let id = server?.subscriptionId else { return nil }
        return subscriptions.first { $0.id == id }
    }

    /// Keeps the built-in set present, first and unchanged, whatever was stored.
    mutating func ensureBuiltin() {
        var builtin = ruleSets.first { $0.builtin } ?? RuleSet()
        ruleSets.removeAll { $0.builtin }
        builtin.builtin = true; builtin.name = ClientState.builtinName; builtin.routing = Routing(); builtin.subscriptionId = nil; builtin.remoteId = nil
        ruleSets.insert(builtin, at: 0)
    }

    public mutating func validate() throws {
        if version != ClientState.currentVersion { throw FormatError("Неизвестный формат настроек.") }
        if AppVersion(skippedUpdateVersion) == nil { skippedUpdateVersion = nil }
        droppedDns = []
        dnsServers = DnsSettings.sanitize(dnsServers, dropped: &droppedDns)
        ensureBuiltin()
        if servers.count > ClientState.maxServers { throw FormatError("Не больше 50 серверов.") }
        if ruleSets.count > ClientState.maxRuleSets { throw FormatError("Не больше 20 наборов правил.") }
        if Set(servers.map(\.id)).count != servers.count || Set(ruleSets.map(\.id)).count != ruleSets.count
            || subscriptions.count > ClientState.maxSubscriptions || Set(subscriptions.map(\.id)).count != subscriptions.count {
            throw FormatError("Повторяющиеся записи в настройках.")
        }
        for i in subscriptions.indices { try subscriptions[i].validate() }
        let known = Set(subscriptions.map(\.id))
        ruleSets.removeAll { $0.managed && !known.contains($0.subscriptionId!) }
        for i in servers.indices {
            try servers[i].validate()
            // A server whose subscription is gone becomes an ordinary one.
            if let source = servers[i].subscriptionId, !known.contains(source) { servers[i].subscriptionId = nil; servers[i].remoteId = nil }
        }
        var names = Set<String>()
        for i in ruleSets.indices {
            try ClientState.validateRuleSetName(ruleSets[i].name)
            if !ruleSets[i].managed && !names.insert(ruleSets[i].name.trimmingCharacters(in: .whitespaces).lowercased()).inserted { throw FormatError("Набор правил с таким названием уже есть.") }
            try ruleSets[i].routing.validate()
        }
        if selectedServerId != nil && selectedServer == nil { selectedServerId = servers.first?.id }
        if !ruleSets.contains(where: { $0.id == selectedRuleSetId }) { selectedRuleSetId = ruleSets[0].id }
    }

    static func validateRuleSetName(_ name: String) throws {
        if Text.isBlank(name) || name.count > 40 || Text.hasControl(name) { throw FormatError("Название набора — от 1 до 40 символов.") }
    }

    /// The DNS servers a session with this server uses: the subscription's, else the user's.
    public func effectiveDns(for server: Server?) -> (servers: [String], managed: Bool) {
        if let managed = subscription(of: server)?.managedDns { return (managed, true) }
        return (dnsServers, false)
    }

    /// The single profile the engine runs: selected server + selected set + shared options.
    public func sessionProfile() throws -> Profile {
        guard let server = selectedServer else { throw FormatError("Сервер не выбран.") }
        var profile = server.toProfile()
        profile.routing = selectedRuleSet.routing
        profile.dnsServers = try DnsSettings.normalize(effectiveDns(for: server).servers)
        profile.killSwitch = killSwitch
        profile.antiDpi = antiDpi
        try profile.validate()
        return profile
    }

    // MARK: Servers

    public mutating func selectServer(_ id: String?) throws {
        if let id = id, !servers.contains(where: { $0.id == id }) { throw FormatError("Сервер не найден.") }
        selectedServerId = id
        if !availableRuleSets.contains(where: { $0.id == selectedRuleSetId }) { selectedRuleSetId = builtinRuleSet.id }
    }
    public mutating func selectRuleSet(_ id: String) throws {
        if !availableRuleSets.contains(where: { $0.id == id }) { throw FormatError("Набор правил не найден.") }
        selectedRuleSetId = id
    }
    /// Same server = same host (any case) and the same VPN user.
    public func findDuplicate(_ incoming: Server) -> Server? {
        servers.first { $0.hostname.lowercased() == incoming.hostname.lowercased() && $0.username == incoming.username }
    }
    /// Import: a new server goes to the end and is selected; `.update` rewrites the duplicate in place.
    @discardableResult
    public mutating func addServer(_ server: Server, _ choice: DuplicateChoice) throws -> Server {
        var incoming = server
        try incoming.validate()
        if choice == .update, let existing = findDuplicate(incoming), let i = servers.firstIndex(where: { $0.id == existing.id }) {
            servers[i].hostname = incoming.hostname; servers[i].address = incoming.address; servers[i].username = incoming.username
            servers[i].password = incoming.password; servers[i].transport = incoming.transport
            if incoming.hasOwnName { servers[i].name = incoming.name; servers[i].country = incoming.country }
            selectedServerId = servers[i].id
            return servers[i]
        }
        if servers.count >= ClientState.maxServers { throw FormatError("Не больше 50 серверов.") }
        if servers.contains(where: { $0.id == incoming.id }) { incoming.id = Text.newId() }
        servers.append(incoming)
        selectedServerId = incoming.id
        return incoming
    }
    public mutating func removeServer(_ id: String) throws {
        guard let i = servers.firstIndex(where: { $0.id == id }) else { throw FormatError("Сервер не найден.") }
        servers.remove(at: i)
        if selectedServerId == id { selectedServerId = servers.first?.id }
    }
    public mutating func updateServer(_ id: String, _ change: (inout Server) -> Void) throws {
        guard let i = servers.firstIndex(where: { $0.id == id }) else { throw FormatError("Сервер не найден.") }
        var copy = servers[i]
        change(&copy)
        try copy.validate()
        servers[i] = copy
    }

    // MARK: Rule sets

    func editableIndex(_ id: String) throws -> Int {
        guard let i = ruleSets.firstIndex(where: { $0.id == id }) else { throw FormatError("Набор правил не найден.") }
        if ruleSets[i].managed { throw FormatError("Набор управляется администратором. Можно создать личную копию.") }
        if ruleSets[i].builtin { throw FormatError("Встроенный набор «Весь трафик» нельзя изменить.") }
        return i
    }
    func checkUniqueName(_ name: String, except: String?) throws {
        try ClientState.validateRuleSetName(name)
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        if ruleSets.contains(where: { !$0.managed && $0.id != except && $0.name.trimmingCharacters(in: .whitespaces).lowercased() == wanted }) {
            throw FormatError("Набор правил с таким названием уже есть.")
        }
    }
    /// A free name for a new set: «Мои правила», «Мои правила 2», …
    public func freeRuleSetName(_ base: String) -> String {
        var candidate = String(base.prefix(36)), n = 2
        while (try? checkUniqueName(candidate, except: nil)) == nil { candidate = String(base.prefix(36)) + " \(n)"; n += 1 }
        return candidate
    }
    @discardableResult
    public mutating func addRuleSet(_ name: String, _ routing: Routing = Routing()) throws -> RuleSet {
        if ruleSets.count >= ClientState.maxRuleSets { throw FormatError("Не больше 20 наборов правил.") }
        try checkUniqueName(name, except: nil)
        var set = RuleSet()
        set.name = name.trimmingCharacters(in: .whitespaces); set.routing = routing
        try set.routing.validate()
        ruleSets.append(set)
        return set
    }
    public mutating func renameRuleSet(_ id: String, _ name: String) throws {
        let i = try editableIndex(id)
        try checkUniqueName(name, except: id)
        ruleSets[i].name = name.trimmingCharacters(in: .whitespaces)
    }
    public mutating func removeRuleSet(_ id: String) throws {
        let i = try editableIndex(id)
        ruleSets.remove(at: i)
        if selectedRuleSetId == id { selectedRuleSetId = ruleSets[0].id }
    }
    public mutating func updateRuleSet(_ id: String, _ routing: Routing) throws {
        let i = try editableIndex(id)
        var value = routing
        try value.validate()
        ruleSets[i].routing = value
    }

    // MARK: Storage

    public func encoded() throws -> Data {
        var copy = self
        try copy.validate()
        let data = try JSONEncoder().encode(copy)
        if data.count > 1 << 20 { throw FormatError("Настройки слишком большие.") }
        return data
    }
    public static func decoded(_ data: Data) throws -> ClientState {
        if data.count > 1 << 20 { throw FormatError("Повреждённый файл настроек.") }
        var state: ClientState
        do { state = try JSONDecoder().decode(ClientState.self, from: data) }
        catch { throw FormatError("Повреждённый файл настроек.") }
        try state.validate()
        return state
    }
}
