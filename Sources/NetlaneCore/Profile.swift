import Foundation

/// What one engine session runs with: the server's access data plus routing, DNS and protection options.
public struct Profile: Codable, Equatable, Sendable {
    public var hostname: String = ""
    public var address: String = ""
    public var username: String = ""
    public var password: String = ""
    /// "http2" or "http3".
    public var transport: String = "http2"
    public var antiDpi = false
    public var dnsServers: [String] = []
    public var killSwitch = true
    public var routing = Routing()
    /// Display name from the tt:// link (tag 12); the engine does not use it.
    public var name: String?
    public init() {}

    public mutating func validate() throws {
        if hostname.isEmpty || hostname.count > 253 || !Text.matches(hostname, #"^[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?$"#) || hostname.contains("..") { throw FormatError("Неверное имя сервера.") }
        if !Profile.validAddress(address) { throw FormatError("Неверный адрес VPN-сервера.") }
        if !Text.matches(username, #"^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$"#) { throw FormatError("Неверное имя пользователя.") }
        if password.utf8.count < 12 || password.utf8.count > 1024 { throw FormatError("Неверная длина пароля в профиле.") }
        if transport != "http2" && transport != "http3" { throw FormatError("Поддерживаются только HTTP/2 и HTTP/3.") }
        try routing.validate()
        dnsServers = try DnsSettings.normalize(dnsServers)
    }

    /// host, host:port, IPv4:port or [IPv6]:port — nothing else (no scheme, path, user or spaces).
    static func validAddress(_ address: String) -> Bool {
        if address.isEmpty || address.count > 300 || !address.allSatisfy({ $0.isASCII }) || Text.hasWhitespace(address) || Text.hasControl(address) { return false }
        if address.contains(where: { "\\/@?#\"'".contains($0) }) { return false }
        var host = address, portText: String? = nil
        if address.hasPrefix("[") {
            guard let end = address.firstIndex(of: "]") else { return false }
            host = String(address[address.index(after: address.startIndex)..<end])
            let rest = address[address.index(after: end)...]
            if !rest.isEmpty { guard rest.hasPrefix(":") else { return false }; portText = String(rest.dropFirst()) }
            guard let literal = IpLiteral(host), !literal.isV4 else { return false }
        } else {
            if let colon = address.lastIndex(of: ":") { host = String(address[..<colon]); portText = String(address[address.index(after: colon)...]) }
            if host.contains(":") { return false }
            if IpLiteral(host) == nil && !Text.matches(host, #"^[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?$"#) { return false }
        }
        if let portText = portText {
            guard !portText.isEmpty, portText.count <= 5, portText.allSatisfy({ $0.isNumber }), let port = Int(portText), port >= 1, port <= 65535 else { return false }
        }
        return true
    }

    /// Host and port of the address (443 when the address names no port).
    public var endpoint: (host: String, port: Int) {
        if address.hasPrefix("["), let end = address.firstIndex(of: "]") {
            let rest = address[address.index(after: end)...].dropFirst()
            return (String(address[address.index(after: address.startIndex)..<end]), Int(rest) ?? 443)
        }
        if let colon = address.lastIndex(of: ":") { return (String(address[..<colon]), Int(address[address.index(after: colon)...]) ?? 443) }
        return (address, 443)
    }

    // MARK: Import

    /// A tt:// link or a TOML profile exported by the panel.
    public static func `import`(_ raw: String) throws -> Profile {
        if raw.count > 32768 { throw FormatError("Профиль слишком большой.") }
        let input = raw.replacingOccurrences(of: "\u{FEFF}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        var profile = input.hasPrefix("tt://?") ? try fromLink(input) : try fromToml(input)
        try profile.validate()
        return profile
    }

    static func fromLink(_ input: String) throws -> Profile {
        let payload = String(input.dropFirst(6))
        guard Text.matches(payload, #"^[A-Za-z0-9_-]+$"#), payload.count % 4 != 1,
              let data = Data(base64Encoded: payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - payload.count % 4) % 4))
        else { throw FormatError("Повреждённая ссылка tt://.") }
        let bytes = [UInt8](data)
        var fields: [UInt64: [UInt8]] = [:]
        var offset = 0
        while offset < bytes.count {
            let tag = try integer(bytes, &offset), length = try integer(bytes, &offset)
            if length > UInt64(bytes.count - offset) || fields[tag] != nil { throw FormatError("Повреждённые или повторяющиеся поля профиля.") }
            if ![0, 1, 2, 3, 4, 5, 6, 9, 10, 12].contains(tag) { throw FormatError("Это расширенный профиль. Экспортируйте профиль из нашей панели.") }
            fields[tag] = Array(bytes[offset..<offset + Int(length)])
            offset += Int(length)
        }
        guard fields[0] == [1] else { throw FormatError("Нужна ссылка tt:// версии 1 из панели.") }
        if try flag(fields, 4) { throw FormatError("Профили с отключённой проверкой TLS запрещены.") }
        _ = try flag(fields, 3)
        var profile = Profile()
        profile.hostname = try text(fields, 1); profile.address = try text(fields, 2)
        profile.username = try text(fields, 5); profile.password = try text(fields, 6)
        profile.antiDpi = try flag(fields, 10)
        if let transport = fields[9] {
            guard transport == [1] || transport == [2] else { throw FormatError("Неизвестный транспорт.") }
            profile.transport = transport == [1] ? "http2" : "http3"
        }
        if let name = fields[12] {
            guard let decoded = String(validatingUTF8Bytes: name) else { throw FormatError("Повреждённое имя профиля.") }
            profile.name = decoded
        }
        return profile
    }

    /// QUIC-style variable-length integer: the top two bits of the first byte give the length.
    static func integer(_ bytes: [UInt8], _ offset: inout Int) throws -> UInt64 {
        guard offset < bytes.count else { throw FormatError("Обрезанный профиль.") }
        let length = 1 << Int(bytes[offset] >> 6)
        guard bytes.count - offset >= length else { throw FormatError("Обрезанный профиль.") }
        var result = UInt64(bytes[offset] & 63)
        offset += 1
        for _ in 1..<length { result = (result << 8) | UInt64(bytes[offset]); offset += 1 }
        return result
    }
    static func text(_ fields: [UInt64: [UInt8]], _ tag: UInt64) throws -> String {
        guard let bytes = fields[tag] else { throw FormatError("В профиле не хватает обязательных полей.") }
        guard let value = String(validatingUTF8Bytes: bytes) else { throw FormatError("Неверная кодировка профиля.") }
        return value
    }
    static func flag(_ fields: [UInt64: [UInt8]], _ tag: UInt64) throws -> Bool {
        guard let bytes = fields[tag] else { return false }
        guard bytes.count == 1, bytes[0] <= 1 else { throw FormatError("Повреждённый флаг профиля.") }
        return bytes[0] == 1
    }

    static func fromToml(_ input: String) throws -> Profile {
        var values: [String: String] = [:]
        let allowed = ["hostname", "addresses", "has_ipv6", "username", "password", "skip_verification", "upstream_protocol", "anti_dpi"]
        for original in input.replacingOccurrences(of: "\r", with: "").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = original.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let split = line.firstIndex(of: "="), split != line.startIndex else { throw FormatError("Нужен TOML-профиль, экспортированный панелью.") }
            let key = line[..<split].trimmingCharacters(in: .whitespaces), value = line[line.index(after: split)...].trimmingCharacters(in: .whitespaces)
            if !allowed.contains(key) || values[key] != nil { throw FormatError("Неизвестное или повторное поле TOML. Экспортируйте профиль из панели.") }
            values[key] = value
        }
        func required(_ name: String) throws -> String {
            guard let value = values[name] else { throw FormatError("Не хватает поля " + name + ".") }
            return value
        }
        func boolean(_ name: String) throws -> Bool {
            guard let value = values[name] else { return false }
            guard value == "true" || value == "false" else { throw FormatError("Неверный флаг " + name + ".") }
            return value == "true"
        }
        func string(_ value: String) throws -> String {
            guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { throw FormatError("Ожидается строка TOML из панели.") }
            guard let data = value.data(using: .utf8), let decoded = (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) as? String else { throw FormatError("Повреждённая строка TOML.") }
            return decoded
        }
        if try boolean("skip_verification") { throw FormatError("Профили с отключённой проверкой TLS запрещены.") }
        _ = try boolean("has_ipv6")
        let addresses = try required("addresses")
        guard addresses.hasPrefix("["), addresses.hasSuffix("]") else { throw FormatError("Неверный адрес в профиле.") }
        var profile = Profile()
        profile.hostname = try string(try required("hostname"))
        profile.address = try string(addresses.dropFirst().dropLast().trimmingCharacters(in: .whitespaces))
        profile.username = try string(try required("username"))
        profile.password = try string(try required("password"))
        if let transport = values["upstream_protocol"] { profile.transport = try string(transport) }
        profile.antiDpi = try boolean("anti_dpi")
        return profile
    }

    // MARK: Engine

    public static let excludedRoutes = ["0.0.0.0/8", "10.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16", "224.0.0.0/3"]

    /// The engine's TOML. `socksPort` 0 means the system tunnel (utun); a port starts a local SOCKS
    /// listener instead, which needs no administrator rights and is used by the tests.
    public func engineConfig(socksPort: Int = 0) throws -> String {
        var copy = self
        try copy.validate()
        if socksPort != 0 && (socksPort < 1024 || socksPort > 65535) { throw FormatError("Неверный тестовый порт.") }
        var endpoint = "[endpoint]\nhostname = " + Text.tomlQuote(copy.hostname) + "\naddresses = [" + Text.tomlQuote(copy.address) + "]\nhas_ipv6 = false\nusername = " + Text.tomlQuote(copy.username)
            + "\npassword = " + Text.tomlQuote(copy.password) + "\nskip_verification = false\nupstream_protocol = " + Text.tomlQuote(copy.transport) + "\nanti_dpi = " + (copy.antiDpi ? "true" : "false") + "\n"
        if !copy.dnsServers.isEmpty { endpoint += "dns_upstreams = [" + copy.dnsServers.map(Text.tomlQuote).joined(separator: ", ") + "]\n" }
        // IPv6 is routed into the tunnel too (the engine's own default): the endpoint has no IPv6, so the
        // engine refuses it there and programs fall back to IPv4 instead of leaving past the VPN.
        let listener = socksPort == 0
            ? "[listener.tun]\nchange_system_dns = true\nincluded_routes = [\"0.0.0.0/0\", \"2000::/3\"]\nexcluded_routes = [" + Profile.excludedRoutes.map(Text.tomlQuote).joined(separator: ", ") + "]\n"
            : "[listener.socks]\naddress = \"127.0.0.1:\(socksPort)\"\n"
        // Application rules need the tunnel: through a SOCKS listener the engine cannot see the owner.
        let routing = try copy.routing.engineConfig()
        return "loglevel = \"info\"\nkillswitch_enabled = " + (socksPort == 0 && copy.killSwitch ? "true" : "false") + "\n" + routing.keys
            + (socksPort == 0 ? routing.applicationRules : "") + endpoint + listener
    }

    /// The config as written to the log: the password is never shown.
    public static func mask(_ config: String) -> String {
        config.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            if let equals = line.firstIndex(of: "="), line[..<equals].trimmingCharacters(in: .whitespaces) == "password" { return "password = \"***\"" }
            return String(line)
        }.joined(separator: "\n")
    }
}

extension String {
    /// Strict UTF-8 decoding: invalid bytes give nil instead of replacement characters.
    init?(validatingUTF8Bytes bytes: [UInt8]) {
        guard let value = String(bytes: bytes, encoding: .utf8) else { return nil }
        guard Array(value.utf8) == bytes else { return nil }
        self = value
    }
}
