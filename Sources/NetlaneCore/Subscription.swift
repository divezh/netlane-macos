import Foundation

/// A subscription link from the panel: one URL that lists all locations of the user.
public struct Subscription: Codable, Equatable, Identifiable, Sendable {
    public static let defaultHours = 12
    public var id = Text.newId()
    public var url = ""
    public var name: String?
    public var updateHours = Subscription.defaultHours
    public var updatedAt: String?
    public var lastError: String?
    public var managedDns: [String]?
    public var settingsRevision: Int64 = 0
    /// What the panel says about the access itself: status, end date, monthly quota.
    public var accountStatus: String?
    public var expiresAt: String?
    public var quotaBytes: Int64 = 0
    public var quotaUsedBytes: Int64 = 0
    public var quotaMonth: String?
    /// The local date (yyyy-MM-dd) a «доступ скоро закончится» notice was last shown; one a day.
    public var warnedOn: String?
    public init() {}

    public mutating func validate() throws {
        if !Text.matches(id, "^[0-9a-f]{32}$") { throw FormatError("Повреждённый идентификатор подписки.") }
        if !Subscription.looksLikeUrl(url) || url.count > 2048 { throw FormatError("Адрес подписки должен начинаться с https:// и вести на /sub/.") }
        if let dns = managedDns { managedDns = try DnsSettings.normalize(dns) }
        if updateHours < 1 || updateHours > 24 { updateHours = Subscription.defaultHours }
        if let value = name, value.count > 64 || Text.hasControl(value) { name = nil }
        if !Account.knownStatus(accountStatus) { accountStatus = nil }
        if let end = expiresAt, end.count > 40 || Account.parseDate(end) == nil { expiresAt = nil }
        if quotaBytes < 0 || quotaUsedBytes < 0 { quotaBytes = 0; quotaUsedBytes = 0 }
        if let month = quotaMonth, !Text.matches(month, #"^\d{4}-\d{2}$"#) { quotaMonth = nil }
    }

    /// https://<host>/…/sub/<token>, as the panel issues them.
    public static func looksLikeUrl(_ text: String?) -> Bool {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !Text.hasWhitespace(text), text.allSatisfy({ $0.isASCII }),
              let parts = URLComponents(string: text), parts.scheme == "https", let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil
        else { return false }
        return Text.matches(parts.path, "/sub/[A-Za-z0-9_-]+$")
    }
    public var displayName: String {
        ServerName.split(name).name ?? URLComponents(string: url)?.host ?? url
    }
    public var updatedDate: Date? { updatedAt.flatMap(Account.parseDate) }
    /// Time for a background refresh: never refreshed, or older than the feed's own interval.
    public func isDue(now: Date) -> Bool {
        guard let updated = updatedDate else { return true }
        return now.timeIntervalSince(updated) >= Double(updateHours) * 3600
    }
}

/// A parsed subscription response; every server is checked like an imported tt:// link.
public struct SubscriptionFeed: Sendable {
    public var name: String?
    public var updateHours = Subscription.defaultHours
    public var servers: [Server] = []
    public var ruleSets: [RuleSet] = []
    public var dns: [String]?
    public var settingsRevision: Int64 = 0
    public var accountStatus: String?, expiresAt: String?, quotaMonth: String?
    public var quotaBytes: Int64 = 0, quotaUsedBytes: Int64 = 0

    static func broken(_ why: String) -> FormatError { FormatError("Подписка повреждена: " + why + ".") }

    public static func parse(_ json: String) throws -> SubscriptionFeed {
        guard let root = Loose.object(json, limit: 1 << 20) else { throw broken("ответ не похож на подписку") }
        guard Loose.integer(root["version"]) == 1 else { throw broken("неизвестная версия формата, обновите программу") }
        guard let items = root["servers"] as? [Any] else { throw broken("нет списка серверов") }
        if items.count > ClientState.maxServers { throw broken("больше 50 серверов") }
        var feed = SubscriptionFeed()
        if let hours = Loose.integer(root["update_hours"]), hours >= 1, hours <= 24 { feed.updateHours = Int(hours) }
        if let name = Loose.string(root, "name"), name.count <= 64, !Text.hasControl(name), !Text.isBlank(name) { feed.name = name.trimmingCharacters(in: .whitespaces) }
        // The feed's «client» block advertises the Windows client; macOS has its own update channel.
        if let account = root["account"] as? [String: Any], let status = Loose.string(account, "status"), Account.knownStatus(status) {
            // An unknown status from a newer panel is ignored rather than breaking the feed.
            feed.accountStatus = status
            if let end = Loose.string(account, "expires_at"), end.count <= 40, Account.parseDate(end) != nil { feed.expiresAt = end }
            feed.quotaBytes = max(0, Loose.integer(account["quota_bytes"]) ?? 0)
            feed.quotaUsedBytes = feed.quotaBytes > 0 ? max(0, Loose.integer(account["quota_used_bytes"]) ?? 0) : 0
            if feed.quotaBytes > 0, let month = Loose.string(account, "quota_month"), Text.matches(month, #"^\d{4}-\d{2}$"#) { feed.quotaMonth = month }
        }
        var ids = Set<String>()
        for item in items {
            guard let entry = item as? [String: Any] else { throw broken("неверная запись сервера") }
            guard let id = Loose.string(entry, "id"), Text.matches(id, "^[A-Za-z0-9_-]{1,64}$"), ids.insert(id).inserted else { throw broken("неверный или повторяющийся id сервера") }
            guard let link = Loose.string(entry, "link"), link.hasPrefix("tt://?") else { throw broken("у сервера нет ссылки tt://") }
            var server: Server
            do { server = Server.from(try Profile.import(link)) }
            catch let error as FormatError { throw broken("сервер «" + id + "»: " + error.message) }
            let parts = ServerName.split(Loose.string(entry, "name"))
            if let display = parts.name, display.count <= 64, !Text.hasControl(display) { server.name = display }
            if let code = Loose.string(entry, "country"), Text.matches(code, "^[A-Z]{2}$") { server.country = code }
            else if let country = parts.country { server.country = country }
            server.remoteId = id
            do { try server.validate() } catch let error as FormatError { throw broken("сервер «" + id + "»: " + error.message) }
            feed.servers.append(server)
        }
        if let settings = root["client_settings"] {
            guard let config = settings as? [String: Any], Loose.integer(config["version"]) == 1, let revision = Loose.integer(config["revision"]), revision >= 0,
                  let sets = config["rule_sets"] as? [Any], sets.count <= 10 else { throw broken("неверные настройки маршрутизации") }
            feed.settingsRevision = revision
            if let dns = config["dns_servers"], !(dns is NSNull) {
                guard let entries = dns as? [String] else { throw broken("неверные DNS-серверы") }
                do { feed.dns = try DnsSettings.normalize(entries) } catch let error as FormatError { throw broken("DNS: " + error.message) }
            }
            var setIds = Set<String>(), names = Set<String>()
            for raw in sets {
                guard let entry = raw as? [String: Any], let routing = entry["routing"] else { throw broken("нет правил набора") }
                guard let id = Loose.string(entry, "id"), Text.matches(id, "^[A-Za-z0-9_-]{1,64}$"), setIds.insert(id).inserted,
                      let title = Loose.string(entry, "name"), !Text.isBlank(title), title.count <= 40, !Text.hasControl(title),
                      names.insert(title.trimmingCharacters(in: .whitespaces).lowercased()).inserted else { throw broken("неверное название или id набора") }
                guard var rules = Routing.fromLoose(routing) else { throw broken("неверные правила набора") }
                do { try rules.validate() } catch let error as FormatError { throw broken("набор «" + title + "»: " + error.message) }
                var set = RuleSet()
                set.remoteId = id; set.name = title.trimmingCharacters(in: .whitespaces); set.routing = rules
                feed.ruleSets.append(set)
            }
        }
        return feed
    }
}

public struct FeedResult: Equatable, Sendable {
    public var added = 0, updated = 0, removed = 0
    /// The connected server's access data changed: the session should be restarted.
    public var currentChanged = false
    public var settingsChanged = false
    public init(added: Int = 0, updated: Int = 0, removed: Int = 0, currentChanged: Bool = false, settingsChanged: Bool = false) {
        self.added = added; self.updated = updated; self.removed = removed; self.currentChanged = currentChanged; self.settingsChanged = settingsChanged
    }
}

extension ClientState {
    /// Adds a subscription by URL, or returns the one that already has it.
    @discardableResult
    public mutating func addSubscription(_ rawUrl: String) throws -> Subscription {
        let url = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = subscriptions.first(where: { $0.url == url }) { return existing }
        if subscriptions.count >= ClientState.maxSubscriptions { throw FormatError("Не больше 10 подписок.") }
        var created = Subscription()
        created.url = url
        try created.validate()
        subscriptions.append(created)
        return created
    }

    /// Merges a feed into the subscription's servers by node id. A connected server that left the feed
    /// is kept (orphaned) until the session ends; see dropOrphans.
    @discardableResult
    public mutating func applyFeed(_ subscriptionId: String, _ feed: SubscriptionFeed, connectedServerId: String?, now: Date = Date()) throws -> FeedResult {
        guard let s = subscriptions.firstIndex(where: { $0.id == subscriptionId }) else { throw FormatError("Подписка не найдена.") }
        let mine = servers.filter { $0.subscriptionId == subscriptionId }
        let added = feed.servers.filter { f in !mine.contains { $0.remoteId == f.remoteId } }.count
        let leaving = mine.filter { m in !feed.servers.contains { $0.remoteId == m.remoteId } && m.id != connectedServerId }.count
        if servers.count - leaving + added > ClientState.maxServers { throw FormatError("Не больше 50 серверов: удалите лишние, чтобы добавить серверы подписки.") }
        let oldSets = ruleSets.filter { $0.subscriptionId == subscriptionId }
        if ruleSets.count - oldSets.count + feed.ruleSets.count > ClientState.maxRuleSets { throw FormatError("Не больше 20 наборов: удалите лишние наборы перед обновлением подписки.") }

        var result = FeedResult()
        func shape(_ sets: [RuleSet]) -> [[String]] {
            sets.sorted { ($0.remoteId ?? "") < ($1.remoteId ?? "") }.map { [$0.remoteId ?? "", $0.name, $0.routing.mode] + $0.routing.destinations }
        }
        result.settingsChanged = subscriptions[s].settingsRevision != feed.settingsRevision || subscriptions[s].managedDns != feed.dns || shape(oldSets) != shape(feed.ruleSets)
        for incoming in feed.ruleSets {
            if let i = ruleSets.firstIndex(where: { $0.subscriptionId == subscriptionId && $0.remoteId == incoming.remoteId }) {
                ruleSets[i].name = incoming.name; ruleSets[i].routing = incoming.routing
            } else {
                var set = incoming
                set.id = Text.newId(); set.subscriptionId = subscriptionId
                ruleSets.append(set)
            }
        }
        ruleSets.removeAll { set in set.subscriptionId == subscriptionId && !feed.ruleSets.contains { $0.remoteId == set.remoteId } }
        subscriptions[s].managedDns = feed.dns
        subscriptions[s].settingsRevision = feed.settingsRevision
        subscriptions[s].accountStatus = feed.accountStatus; subscriptions[s].expiresAt = feed.expiresAt; subscriptions[s].quotaMonth = feed.quotaMonth
        subscriptions[s].quotaBytes = feed.quotaBytes; subscriptions[s].quotaUsedBytes = feed.quotaUsedBytes

        for var incoming in feed.servers {
            guard let i = servers.firstIndex(where: { $0.subscriptionId == subscriptionId && $0.remoteId == incoming.remoteId }) else {
                incoming.subscriptionId = subscriptionId
                if servers.contains(where: { $0.id == incoming.id }) { incoming.id = Text.newId() }
                servers.append(incoming)
                result.added += 1
                continue
            }
            let old = servers[i]
            let access = old.hostname != incoming.hostname || old.address != incoming.address || old.username != incoming.username || old.password != incoming.password
            let look = old.transport != incoming.transport || old.name != incoming.name || old.country != incoming.country || old.orphaned
            if access || look {
                servers[i].hostname = incoming.hostname; servers[i].address = incoming.address; servers[i].username = incoming.username
                servers[i].password = incoming.password; servers[i].transport = incoming.transport; servers[i].name = incoming.name
                servers[i].country = incoming.country; servers[i].orphaned = false
                result.updated += 1
                if access && old.id == connectedServerId { result.currentChanged = true }
            }
        }
        for gone in mine where !feed.servers.contains(where: { $0.remoteId == gone.remoteId }) {
            result.removed += 1
            if gone.id == connectedServerId, let i = servers.firstIndex(where: { $0.id == gone.id }) { servers[i].orphaned = true }
            else { servers.removeAll { $0.id == gone.id } }
        }
        subscriptions[s].name = feed.name; subscriptions[s].updateHours = feed.updateHours
        subscriptions[s].updatedAt = Account.formatDate(now); subscriptions[s].lastError = nil
        fixSelection(prefer: subscriptionId)
        return result
    }

    /// After the session ends: servers that left their subscription go away.
    public mutating func dropOrphans() {
        let orphans = servers.filter { $0.orphaned }
        if orphans.isEmpty { return }
        servers.removeAll { $0.orphaned }
        fixSelection(prefer: orphans.compactMap(\.subscriptionId).first)
    }

    /// Removes the subscription and its servers; a connected one stays as an orphan.
    public mutating func removeSubscription(_ id: String, connectedServerId: String?) throws {
        guard subscriptions.contains(where: { $0.id == id }) else { throw FormatError("Подписка не найдена.") }
        subscriptions.removeAll { $0.id == id }
        ruleSets.removeAll { $0.subscriptionId == id }
        for server in servers where server.subscriptionId == id {
            if server.id == connectedServerId, let i = servers.firstIndex(where: { $0.id == server.id }) { servers[i].orphaned = true; servers[i].subscriptionId = nil }
            else { servers.removeAll { $0.id == server.id } }
        }
        fixSelection(prefer: nil)
    }

    public mutating func setSubscriptionError(_ id: String, _ message: String?) {
        if let i = subscriptions.firstIndex(where: { $0.id == id }) { subscriptions[i].lastError = message }
    }

    /// A selected server that is gone: the subscription's first live server, else the first one.
    mutating func fixSelection(prefer: String?) {
        if selectedServer == nil {
            let next = servers.first { !$0.orphaned && prefer != nil && $0.subscriptionId == prefer } ?? servers.first { !$0.orphaned }
            selectedServerId = next?.id
        }
        if !availableRuleSets.contains(where: { $0.id == selectedRuleSetId }) { selectedRuleSetId = builtinRuleSet.id }
    }
}

/// How the client talks about the access a subscription gives.
public enum Account {
    public enum Level { case normal, warning, danger }

    static func knownStatus(_ status: String?) -> Bool { ["active", "pending", "disabled", "expired", "exhausted"].contains(status ?? "") }

    /// ISO 8601 with or without fractional seconds; no time zone means UTC.
    public static func parseDate(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter(); withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter(); plain.formatOptions = [.withInternetDateTime]
        var candidates = [text]
        if !text.hasSuffix("Z") && !Text.matches(text, #"[+-]\d{2}:?\d{2}$"#) { candidates.append(text + "Z") }
        if Text.matches(text, #"^\d{4}-\d{2}-\d{2}$"#) { candidates.append(text + "T00:00:00Z") }
        for candidate in candidates {
            // More than three fractional digits (as .NET writes) are cut to milliseconds.
            let trimmed = candidate.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
            if let date = withFraction.date(from: trimmed) ?? plain.date(from: trimmed) {
                let year = Calendar(identifier: .gregorian).component(.year, from: date)
                return year >= 2000 && year <= 2200 ? date : nil
            }
        }
        return nil
    }
    public static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
    static func local(_ date: Date, _ format: String, zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU"); formatter.timeZone = zone; formatter.dateFormat = format
        return formatter.string(from: date)
    }
    static func decimal(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded).replacingOccurrences(of: ".", with: ",")
    }
    /// 1 ГБ here is 1024³ bytes, as the panel sets quotas.
    public static func size(_ bytes: Int64) -> String {
        let gb = 1024.0 * 1024 * 1024, mb = 1024.0 * 1024
        if Double(bytes) >= gb { let v = Double(bytes) / gb; return (v < 100 ? decimal(v) : String(Int(v))) + " ГБ" }
        return String(Int(max(0, (Double(bytes) / mb).rounded()))) + " МБ"
    }
    /// «12,4/50 ГБ» or «12,4 из 50 ГБ»: one unit when both sizes share it.
    static func usage(_ s: Subscription, _ between: String) -> String {
        var used = size(s.quotaUsedBytes)
        let total = size(s.quotaBytes), unit = String(total.suffix(3))
        if used.hasSuffix(unit) { used = String(used.dropLast(3)) }
        return used + (between == "/" ? "/" : " " + between + " ") + total
    }
    static func end(_ s: Subscription) -> Date? { s.expiresAt.flatMap(parseDate) }
    /// The panel no longer gives servers for one of these reasons.
    public static func blocked(_ s: Subscription) -> Bool { ["disabled", "expired", "pending", "exhausted"].contains(s.accountStatus ?? "") }
    public static func reason(_ s: Subscription, zone: TimeZone = .current) -> String? {
        switch s.accountStatus {
        case "disabled": return "доступ отключён администратором"
        case "expired": return end(s).map { "доступ истёк " + local($0, "dd.MM.yyyy", zone: zone) } ?? "срок доступа истёк"
        case "exhausted": return "трафик на месяц исчерпан"
        case "pending": return "доступ ещё не включён"
        default: return nil
        }
    }
    public static func level(_ s: Subscription?, now: Date) -> Level {
        guard let s = s, s.accountStatus != nil else { return .normal }
        if blocked(s) { return .danger }
        if let end = end(s), end.timeIntervalSince(now) <= 3 * 86400 { return .warning }
        if s.quotaBytes > 0 && Double(s.quotaUsedBytes) >= Double(s.quotaBytes) * 0.9 { return .warning }
        return .normal
    }
    /// Short, for the line under the name: «до 17.11 · 12,4/50 ГБ».
    public static func summary(_ s: Subscription?, now: Date, zone: TimeZone = .current) -> String? {
        guard let s = s, s.accountStatus != nil else { return nil }
        if let reason = reason(s, zone: zone) { return reason }
        var parts: [String] = []
        if let end = end(s) {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            let sameYear = calendar.component(.year, from: end) == calendar.component(.year, from: now)
            parts.append(end.timeIntervalSince(now) <= 86400 ? "до " + local(end, "HH:mm", zone: zone) : "до " + local(end, sameYear ? "dd.MM" : "dd.MM.yyyy", zone: zone))
        }
        if s.quotaBytes > 0 { parts.append(usage(s, "/")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    /// Full, for «Серверы»: «Доступ до 17.11.2026 03:00 · Трафик за ноябрь: 12,4 из 50 ГБ (25%)».
    public static func details(_ s: Subscription?, zone: TimeZone = .current) -> String? {
        guard let s = s, s.accountStatus != nil else { return nil }
        var parts: [String] = []
        let why = reason(s, zone: zone)
        if let why = why { parts.append(why.prefix(1).uppercased() + why.dropFirst()) }
        if let end = end(s), s.accountStatus != "expired" { parts.append("Доступ до " + local(end, "dd.MM.yyyy HH:mm", zone: zone)) }
        if end(s) == nil && why == nil { parts.append("Доступ без срока") }
        if s.quotaBytes > 0 {
            var month = ""
            if let value = s.quotaMonth, let first = parseDate(value + "-01") { month = " за " + local(first, "LLLL", zone: TimeZone(identifier: "UTC")!).lowercased() }
            let percent = min(100, Int((100 * Double(s.quotaUsedBytes) / Double(s.quotaBytes)).rounded()))
            parts.append("Трафик" + month + ": " + usage(s, "из") + " (\(percent)%)")
        }
        return parts.joined(separator: " · ")
    }
    /// The once-a-day notice text when the access is about to end, or nil.
    public static func warning(_ s: Subscription, now: Date, zone: TimeZone = .current) -> String? {
        guard level(s, now: now) == .warning else { return nil }
        if let end = end(s), end.timeIntervalSince(now) <= 3 * 86400 { return "Доступ по подписке «" + s.displayName + "» заканчивается " + local(end, "dd.MM в HH:mm", zone: zone) + "." }
        return "Трафик по подписке «" + s.displayName + "» почти исчерпан: " + usage(s, "из") + "."
    }
}
