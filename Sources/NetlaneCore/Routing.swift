import Foundation

/// A per-application rule. macOS cannot apply these (the engine has them only on Windows); they are
/// kept so that rule files and subscription sets stay interchangeable with the Windows client.
public struct AppRule: Codable, Equatable, Sendable {
    public var executable: String?
    public var name: String?
    public var action: String
    public init(executable: String? = nil, name: String? = nil, action: String) { self.executable = executable; self.name = name; self.action = action }
}

public struct Routing: Codable, Equatable, Sendable {
    /// "general": everything through the VPN except the destinations; "selective": only the destinations.
    public var mode: String = "general"
    public var destinations: [String] = []
    public var applications: [AppRule] = []
    public init() {}
    public init(mode: String, destinations: [String], applications: [AppRule] = []) { self.mode = mode; self.destinations = destinations; self.applications = applications }

    public mutating func validate() throws {
        if mode != "general" && mode != "selective" { throw FormatError("Неизвестный режим маршрутизации.") }
        if destinations.count > 256 || applications.count > 100 { throw FormatError("Слишком много правил: максимум 256 адресов и 100 приложений.") }
        var seen = Set<String>()
        for i in destinations.indices {
            let value = try Routing.normalizeDestination(destinations[i])
            if !seen.insert(value).inserted { throw FormatError("Правило адреса уже существует.") }
            destinations[i] = value
        }
        var paths = Set<String>(), names = Set<String>()
        for app in applications {
            if app.action != "vpn" && app.action != "direct" { throw FormatError("Нужен маршрут VPN/напрямую для правила приложения.") }
            if (app.name != nil) == (app.executable != nil) { throw FormatError("У правила укажите либо полный путь .exe, либо имя процесса .exe — не оба.") }
            if let path = app.executable {
                if path.count > 1024 || !Text.matches(path, #"^[A-Za-z]:\\[^\r\n"<>|?*]+\.exe$"#, caseInsensitive: true) || path.contains("\\..\\") { throw FormatError("Нужен полный локальный путь к .exe.") }
                if !paths.insert(path.lowercased()).inserted { throw FormatError("Для приложения уже есть правило.") }
            } else if let name = app.name {
                let forbidden: Set<Character> = ["\\", "/", ":", "*", "?", "\"", "<", ">", "|", "\r", "\n"]
                if name.count < 5 || name.count > 255 || name.contains(where: { forbidden.contains($0) }) || !name.lowercased().hasSuffix(".exe") { throw FormatError("Укажите имя файла .exe, например `UIS Operator Workplace.exe`, без пути.") }
                if !names.insert(name.lowercased()).inserted { throw FormatError("Для имени процесса уже есть правило.") }
            }
        }
    }

    /// A domain, «*.domain», an IPv4 address or an IPv4 subnet, lower-cased.
    public static func normalizeDestination(_ input: String) throws -> String {
        if Text.isBlank(input) || input.count > 260 || Text.hasWhitespace(input) { throw FormatError("Укажите домен, IP или подсеть CIDR без пробелов и URL.") }
        let value = input.lowercased()
        let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.count > 2 { throw FormatError("Неверная подсеть CIDR.") }
        if parts[0].contains(":") {
            if IpLiteral(parts[0]) != nil { throw FormatError("В этом профиле IPv6 пока выключен. Используйте IPv4 или домен.") }
            throw FormatError("Укажите домен, IP или подсеть CIDR без пробелов и URL.")
        }
        if Text.matches(parts[0], #"^[0-9.]+$"#) {
            let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false)
            guard numbers.count == 4, numbers.allSatisfy({ !$0.isEmpty && $0.count <= 3 }) else {
                throw FormatError(parts[0].contains(".") ? "IPv4 должен содержать четыре числа через точку." : "Неверный IPv4-адрес.")
            }
            if numbers.contains(where: { $0.count > 1 && $0.first == "0" }) { throw FormatError("В IPv4 не должно быть ведущих нулей.") }
            guard let ip = IpLiteral(parts[0]) else { throw FormatError("Неверный IPv4-адрес.") }
            if parts.count == 1 { return ip.text }
            guard parts[1].allSatisfy({ $0.isASCII && $0.isNumber }), let prefix = Int(parts[1]), prefix >= 0, prefix <= 32 else { throw FormatError("Неверная длина префикса CIDR.") }
            return ip.text + "/\(prefix)"
        }
        if parts.count != 1 { throw FormatError("CIDR применяется только к IP-адресам.") }
        let domain = value.hasPrefix("*.") ? String(value.dropFirst(2)) : value
        if domain.count > 253 || !Text.matches(domain, #"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$"#) {
            throw FormatError("Неверный домен. Используйте example.com или *.example.com; для IDN — punycode.")
        }
        if domain.split(separator: ".").contains(where: { $0.count > 63 }) { throw FormatError("Слишком длинная метка домена.") }
        return value
    }

    public var summary: String {
        var parts: [String] = []
        if !destinations.isEmpty { parts.append(Plural.addresses(destinations.count)) }
        let programs = macApplications.count
        if programs > 0 { parts.append(Plural.form(programs, "программа", "программы", "программ")) }
        if parts.isEmpty { return mode == "general" ? "Весь трафик через VPN" : "Весь трафик напрямую" }
        return (mode == "general" ? "Напрямую: " : "Через VPN: ") + parts.joined(separator: ", ")
    }

    /// Process names this set routes on macOS. Rules keep the Windows form shared with the panel
    /// («Jivo.exe»); on a Mac the same rule means the process «Jivo» and its helpers. Rules with a full
    /// Windows path have no Mac counterpart and are left out.
    public var macApplications: [(name: String, action: String)] {
        applications.compactMap { app in
            guard let name = app.name, name.lowercased().hasSuffix(".exe") else { return nil }
            return (String(name.dropLast(4)), app.action)
        }
    }
    /// Rules with a full Windows path (C:\…\app.exe): kept for the Windows client, not applied on a Mac.
    public var windowsOnlyApplications: Int { applications.filter { $0.executable != nil }.count }

    /// Top-level routing keys of the engine config, and the application rules after them.
    public func engineConfig() throws -> (keys: String, applicationRules: String) {
        var copy = self
        try copy.validate()
        let keys = "vpn_mode = " + Text.tomlQuote(copy.mode) + "\nexclusions = [" + copy.destinations.map(Text.tomlQuote).joined(separator: ", ") + "]\n"
        let rules = copy.macApplications.map { "[[application_rules]]\nprocess_name = " + Text.tomlQuote($0.name) + "\naction = " + Text.tomlQuote($0.action) + "\n" }.joined()
        return (keys, rules)
    }

    /// One line of the Mac editor («Jivo» or «Jivo.exe») → the shared rule name «Jivo.exe».
    public static func applicationName(_ line: String) throws -> String {
        let value = line.trimmingCharacters(in: .whitespaces)
        let forbidden: Set<Character> = ["\\", "/", ":", "*", "?", "\"", "<", ">", "|"]
        if value.isEmpty || value.count > 251 || value.contains(where: { forbidden.contains($0) }) || Text.hasControl(value) {
            throw FormatError("Имя программы — как в «Мониторинге системы», например Jivo, без пути и символов \\ / : * ? \" < > |.")
        }
        return value.lowercased().hasSuffix(".exe") ? value : value + ".exe"
    }

    /// Reads {"Mode", "Destinations", "Applications"} whatever the case of the keys (panel and Windows files differ).
    static func fromLoose(_ value: Any?) -> Routing? {
        guard let map = value as? [String: Any] else { return nil }
        var routing = Routing()
        if let mode = Loose.any(map, caseless: "mode") {
            guard let text = mode as? String else { return nil }
            routing.mode = text
        }
        if let raw = Loose.any(map, caseless: "destinations"), !(raw is NSNull) {
            guard let list = raw as? [String] else { return nil }
            routing.destinations = list
        }
        if let raw = Loose.any(map, caseless: "applications"), !(raw is NSNull) {
            guard let list = raw as? [[String: Any]] else { return nil }
            for item in list {
                guard let action = Loose.any(item, caseless: "action") as? String else { return nil }
                routing.applications.append(AppRule(executable: Loose.any(item, caseless: "executable") as? String, name: Loose.any(item, caseless: "name") as? String, action: action))
            }
        }
        return routing
    }

    var looseObject: [String: Any] {
        ["Mode": mode, "Destinations": destinations, "Applications": applications.map { app -> [String: Any] in
            ["Executable": app.executable as Any? ?? NSNull(), "Name": app.name as Any? ?? NSNull(), "Action": app.action]
        }]
    }
}

public enum Plural {
    /// «1 адрес», «3 адреса», «12 адресов».
    public static func form(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let tens = n % 100, ones = n % 10
        if tens >= 11 && tens <= 14 { return "\(n) \(many)" }
        if ones == 1 { return "\(n) \(one)" }
        if ones >= 2 && ones <= 4 { return "\(n) \(few)" }
        return "\(n) \(many)"
    }
    public static func addresses(_ n: Int) -> String { form(n, "адрес", "адреса", "адресов") }
}

/// Portable rules file, the same format as the Windows client (*.netlanerules): no credentials inside.
public enum RulesFile {
    public static let format = "netlane-rules", legacyFormat = "wintrusttunnel-rules", version = 1

    public static func export(_ routing: Routing) throws -> String {
        var copy = routing
        try copy.validate()
        let envelope: [String: Any] = ["Format": format, "Version": version, "Routing": copy.looseObject]
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    public static func `import`(_ text: String) throws -> Routing {
        if Text.isBlank(text) || text.count > 65536 { throw FormatError("Пустой или слишком большой файл правил.") }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{FEFF}", with: "")
        guard let root = Loose.object(cleaned, limit: 1 << 18), let kind = Loose.any(root, caseless: "format") as? String, kind == format || kind == legacyFormat else {
            throw FormatError("Файл не является файлом правил Netlane.")
        }
        let fileVersion = Loose.integer(Loose.any(root, caseless: "version")) ?? 0
        if fileVersion != Int64(version) { throw FormatError("Версия файла правил не поддерживается: \(fileVersion).") }
        guard var routing = Routing.fromLoose(Loose.any(root, caseless: "routing")) else { throw FormatError("В файле нет правил маршрутизации.") }
        try routing.validate()
        return routing
    }
}
