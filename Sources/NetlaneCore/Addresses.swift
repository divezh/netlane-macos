import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// An IPv4 or IPv6 literal with its canonical text.
struct IpLiteral: Equatable {
    let bytes: [UInt8]
    var isV4: Bool { bytes.count == 4 }
    let text: String

    /// Strict dotted IPv4 (four numbers, no leading zeros) or IPv6 without a zone or brackets.
    init?(_ value: String) {
        if value.contains("%") || value.contains("[") || value.contains("]") { return nil }
        if value.contains(":") {
            var address = in6_addr()
            guard inet_pton(AF_INET6, value, &address) == 1 else { return nil }
            var raw = [UInt8](repeating: 0, count: 16)
            withUnsafeBytes(of: &address) { source in for i in 0..<16 { raw[i] = source[i] } }
            var buffer = [CChar](repeating: 0, count: 64)
            guard inet_ntop(AF_INET6, &address, &buffer, 64) != nil else { return nil }
            bytes = raw
            text = String(cString: buffer)
            return
        }
        guard Text.matches(value, #"^(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}$"#) else { return nil }
        let numbers = value.split(separator: ".").compactMap { Int($0) }
        guard numbers.count == 4, numbers.allSatisfy({ $0 <= 255 }) else { return nil }
        bytes = numbers.map { UInt8($0) }
        text = numbers.map(String.init).joined(separator: ".")
    }

    /// IPv4 carried inside ::ffff:a.b.c.d.
    var mappedV4: [UInt8]? {
        guard bytes.count == 16, bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF else { return nil }
        return Array(bytes[12..<16])
    }
    var isUnspecified: Bool { bytes.allSatisfy { $0 == 0 } }
    var isBroadcast: Bool { isV4 && bytes.allSatisfy { $0 == 255 } }
    /// Loopback, private, link-local and carrier-grade NAT ranges: unreachable from the VPN server.
    var isLocal: Bool {
        let b = mappedV4 ?? bytes
        if b.count == 4 {
            return b[0] == 127 || b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 192 && b[1] == 168)
                || (b[0] == 169 && b[1] == 254) || (b[0] == 100 && b[1] >= 64 && b[1] <= 127)
        }
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }
        return (b[0] == 0xFE && (b[1] & 0xC0) == 0x80) || (b[0] == 0xFE && (b[1] & 0xC0) == 0xC0) || (b[0] & 0xFE) == 0xFC
    }
}

public enum DnsSettings {
    public static let maximumServers = 8
    static func invalid() -> FormatError {
        FormatError("Укажите IP DNS-сервера (например, 1.1.1.1), IP:порт, tls://имя или https://имя/dns-query.")
    }

    /// One server per line, as typed in the settings.
    public static func parse(_ text: String) throws -> [String] {
        try normalize(text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    public static func normalize(_ entries: [String]?) throws -> [String] {
        var result: [String] = []
        for entry in entries ?? [] {
            if result.count >= maximumServers { throw FormatError("Не больше восьми DNS-серверов.") }
            let value = try normalizeServer(entry)
            if result.contains(value) { throw FormatError("DNS-сервер указан повторно: " + value) }
            result.append(value)
        }
        return result
    }

    /// For stored settings: keeps what passes today's checks and lists the rest, so one bad entry
    /// never makes the whole state unreadable.
    public static func sanitize(_ entries: [String]?, dropped: inout [String]) -> [String] {
        var result: [String] = []
        for entry in entries ?? [] {
            guard let value = try? normalizeServer(entry), !result.contains(value), result.count < maximumServers else { dropped.append(entry); continue }
            result.append(value)
        }
        return result
    }

    static func checkAddress(_ ip: IpLiteral) throws {
        if ip.isUnspecified || ip.isBroadcast { throw invalid() }
        // Queries go through the VPN server, which does not reach private networks.
        if ip.isLocal {
            throw FormatError("DNS-сервер из локальной сети (" + ip.text + ") недоступен через VPN: запросы DNS идут через сервер. Укажите публичный DNS, например 1.1.1.1.")
        }
    }

    public static func normalizeServer(_ input: String) throws -> String {
        if input.count > 512 || Text.hasControl(input) { throw invalid() }
        let value = input.trimmingCharacters(in: .whitespaces)
        if value.isEmpty || Text.hasWhitespace(value) || value.contains("\\") || value.hasSuffix(":") || !value.allSatisfy({ $0.isASCII }) { throw invalid() }
        if let ip = IpLiteral(value) { try checkAddress(ip); return ip.text }
        let plain = !value.contains("://")
        var scheme = "tcp", rest = value
        if !plain {
            let split = value.range(of: "://")!
            scheme = value[..<split.lowerBound].lowercased()
            rest = String(value[split.upperBound...])
        }
        guard ["https", "tls", "tcp", "quic"].contains(scheme) else { throw invalid() }
        if rest.contains("#") || rest.contains("@") { throw invalid() }
        let cut = rest.firstIndex { $0 == "/" || $0 == "?" } ?? rest.endIndex
        let authority = String(rest[..<cut]), tail = String(rest[cut...])
        var host: String, portText: String
        if authority.hasPrefix("[") {
            guard let end = authority.firstIndex(of: "]"), authority.distance(from: authority.startIndex, to: end) >= 2 else { throw invalid() }
            host = String(authority[authority.index(after: authority.startIndex)..<end])
            portText = String(authority[authority.index(after: end)...])
            guard let literal = IpLiteral(host), !literal.isV4 else { throw invalid() }
        } else if let colon = authority.lastIndex(of: ":") {
            host = String(authority[..<colon]); portText = String(authority[colon...])
        } else { host = authority; portText = "" }
        var port = 0
        if !portText.isEmpty {
            let digits = portText.dropFirst()
            guard portText.hasPrefix(":"), !digits.isEmpty, digits.count <= 5, digits.allSatisfy({ $0.isNumber }), let parsed = Int(digits), parsed >= 1, parsed <= 65535 else { throw invalid() }
            port = parsed
        }
        if plain && port == 0 { throw invalid() }
        if host.isEmpty { throw invalid() }
        let literal = IpLiteral(host)
        if let literal = literal { try checkAddress(literal) }
        else {
            // A bare host name needs a scheme: «dns.example:53» alone says nothing about the protocol.
            let name = host.lowercased()
            if plain || name.count > 253 || name.contains("%") || name.allSatisfy({ $0.isNumber || $0 == "." })
                || !Text.matches(name, #"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*$"#) { throw invalid() }
            host = name
        }
        let shown = literal.map { $0.isV4 ? $0.text : "[" + $0.text + "]" } ?? host
        if scheme == "https" {
            let address = "https://" + shown + (port > 0 && port != 443 ? ":\(port)" : "") + (tail.isEmpty ? "/" : tail)
            if address.count > 512 || tail.hasPrefix("?") { throw invalid() }
            return address
        }
        if !(tail.isEmpty || tail == "/") { throw invalid() }
        return (plain ? "" : scheme + "://") + shown + (port > 0 ? ":\(port)" : "")
    }
}
