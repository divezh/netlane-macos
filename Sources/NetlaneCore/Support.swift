import Foundation

/// A message for the user: every check in the core throws it with ready Russian text.
public struct FormatError: Error, LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum AppInfo {
    public static let version = "0.7.6"
    public static let bundleId = "io.github.divezh.netlane"
    public static let userAgent = "Netlane/" + version + " (macOS)"
}

/// Dotted version of two to four numbers, compared number by number («0.10.0» is newer than «0.9.9»).
public struct AppVersion: Comparable, Equatable, CustomStringConvertible {
    public let parts: [Int]
    public init?(_ text: String?) {
        guard let text = text, text.count <= 32 else { return nil }
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count >= 2, pieces.count <= 4 else { return nil }
        var numbers: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.count <= 9, piece.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(piece) else { return nil }
            numbers.append(n)
        }
        parts = numbers
    }
    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }
    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
    public var description: String { parts.map(String.init).joined(separator: ".") }
}

enum Text {
    static func matches(_ value: String, _ pattern: String, caseInsensitive: Bool = false) -> Bool {
        value.range(of: pattern, options: caseInsensitive ? [.regularExpression, .caseInsensitive] : .regularExpression) != nil
    }
    static func hasControl(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }
    static func hasWhitespace(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.properties.isWhitespace }
    }
    static func isBlank(_ value: String?) -> Bool {
        guard let value = value else { return true }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    static func newId() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    /// A TOML basic string. JSON escaping is not used: it writes «\/», which TOML rejects.
    static func tomlQuote(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F { out += String(format: "\\u%04X", scalar.value) }
                else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
}

/// Reading loosely typed JSON (subscription feeds, update manifests) without trusting its shape.
enum Loose {
    static func object(_ json: String, limit: Int) -> [String: Any]? {
        guard json.utf8.count <= limit, let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    static func string(_ map: [String: Any], _ key: String) -> String? { map[key] as? String }
    /// JSON true/false: an NSNumber made from a Bool reports the "c" type on macOS and on Linux.
    static func isBool(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return String(cString: number.objCType) == "c"
    }
    static func bool(_ value: Any?) -> Bool? { isBool(value) ? (value as? NSNumber)?.boolValue : nil }
    /// A whole number; booleans and fractions are not numbers here.
    static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, !isBool(value) else { return nil }
        let double = number.doubleValue
        guard double == double.rounded(), abs(double) < 9e15 else { return nil }
        return number.int64Value
    }
    /// A value looked up without regard to the key's case («Mode» and «mode» are the same field).
    static func any(_ map: [String: Any], caseless key: String) -> Any? {
        if let exact = map[key] { return exact }
        let lower = key.lowercased()
        return map.first { $0.key.lowercased() == lower }?.value
    }
}
