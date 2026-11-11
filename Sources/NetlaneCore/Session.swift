import Foundation

public enum SessionStats {
    public static func duration(_ seconds: Int64) -> String {
        let s = max(0, seconds)
        return String(format: "%02lld:%02lld:%02lld", s / 3600, (s / 60) % 60, s % 60)
    }
    /// Binary units with one decimal and a Russian decimal comma.
    public static func bytes(_ value: Int64) -> String {
        let bytes = max(0, value)
        if bytes < 1024 { return "\(bytes) Б" }
        let units = ["КБ", "МБ", "ГБ", "ТБ"]
        var number = Double(bytes) / 1024, unit = 0
        // Compare the value as it will be printed, so 1023,96 КБ becomes 1,0 МБ rather than 1024,0 КБ.
        while (number * 10).rounded() / 10 >= 1024 && unit < units.count - 1 { number /= 1024; unit += 1 }
        return String(format: "%.1f", number).replacingOccurrences(of: ".", with: ",") + " " + units[unit]
    }
    public static func rate(_ bytesPerSecond: Double) -> String { bytes(Int64(bytesPerSecond.rounded())) + "/с" }
    /// «В сети 00:42:17 · ↓ 1,8 ГБ · ↑ 210,0 МБ»; traffic only when the tunnel counters could be read.
    public static func line(seconds: Int64, traffic: (down: Int64, up: Int64)?) -> String {
        guard let traffic = traffic else { return duration(seconds) }
        return duration(seconds) + " · ↓ " + bytes(traffic.down) + " · ↑ " + bytes(traffic.up)
    }
    /// «2 мин назад», for «Пинг проверен …».
    public static func ago(_ seconds: Double) -> String {
        if seconds < 60 { return "только что" }
        if seconds < 3600 { return "\(Int(seconds / 60)) мин назад" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) ч назад" }
        return "\(Int(seconds / 86400)) дн назад"
    }
    /// «меньше минуты», «42 мин», «3 ч 05 мин» — the length of the last session.
    public static func span(_ seconds: Int64) -> String {
        if seconds < 60 { return "меньше минуты" }
        if seconds < 3600 { return "\(seconds / 60) мин" }
        return "\(seconds / 3600) ч " + String(format: "%02lld", (seconds / 60) % 60) + " мин"
    }
}

/// Session totals from interface counters. A counter that goes down means the tunnel interface was
/// recreated (reconnect): the total so far is kept and the new interface is counted from zero.
public struct TrafficMeter {
    var baseDown: Int64 = 0, baseUp: Int64 = 0, lastDown: Int64 = 0, lastUp: Int64 = 0, doneDown: Int64 = 0, doneUp: Int64 = 0
    var rateAt: Double?, rateDown: Int64 = 0, rateUp: Int64 = 0
    public private(set) var downRate = 0.0, upRate = 0.0
    public private(set) var down: Int64 = 0, up: Int64 = 0
    public init() {}

    public mutating func start(received: Int64, sent: Int64) {
        self = TrafficMeter()
        baseDown = received; lastDown = received; baseUp = sent; lastUp = sent
    }
    /// A new reading of the counters at `time` (seconds, any monotonic origin).
    public mutating func update(received: Int64, sent: Int64, time: Double) {
        down = TrafficMeter.advance(received, &baseDown, &lastDown, &doneDown)
        up = TrafficMeter.advance(sent, &baseUp, &lastUp, &doneUp)
        if let before = rateAt {
            let seconds = time - before
            // Readings under half a second apart keep the previous rate, so a fast timer shows no noise.
            if seconds < 0.5 { return }
            downRate = max(0, Double(down - rateDown) / seconds)
            upRate = max(0, Double(up - rateUp) / seconds)
        }
        rateAt = time; rateDown = down; rateUp = up
    }
    static func advance(_ value: Int64, _ origin: inout Int64, _ last: inout Int64, _ done: inout Int64) -> Int64 {
        if value < last { done += last - origin; origin = 0 }
        last = value
        return done + (value - origin)
    }
}

/// How sites see this computer: the «ip=» and «loc=» lines of https://www.cloudflare.com/cdn-cgi/trace.
public struct PublicIp: Equatable, Sendable {
    public static let traceUrl = "https://www.cloudflare.com/cdn-cgi/trace"
    public var address: String
    public var country: String?
    public init(address: String, country: String?) { self.address = address; self.country = country }

    public static func parse(_ trace: String) throws -> PublicIp {
        var address: String?, country: String?
        for raw in trace.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let eq = line.firstIndex(of: "="), eq != line.startIndex else { continue }
            let key = line[..<eq], value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if key == "ip", let ip = IpLiteral(value) { address = ip.text }
            else if key == "loc", value.count == 2, value.allSatisfy({ $0.isASCII && $0.isLetter }) { country = value.uppercased() }
        }
        guard let found = address else { throw FormatError("Ответ проверки IP не распознан.") }
        return PublicIp(address: found, country: country)
    }
    /// «185.12.3.4 · Нидерланды»; the country is left out when unknown.
    public var text: String {
        guard let name = PublicIp.countryName(country) else { return address }
        return address + " · " + name
    }
    public static func countryName(_ code: String?) -> String? {
        guard let code = code, code != "XX", code != "T1" else { return nil }
        return CountryNames.all[code] ?? code
    }
}

/// What a line of the engine's output means for the connection.
public enum EngineEvent: Equatable {
    case connected, reconnecting(seconds: Int), killSwitchActive, failure

    /// Only ERROR lines can mean a failed connection: INFO and WARN lines also say «Failed to» for
    /// routine events. Lines without a level (CLI messages) keep the plain checks.
    public static func isFailure(_ line: String) -> Bool {
        if let level = line.range(of: #"^\d{2}\.\d{2}\.\d{4} \d{2}:\d{2}:\d{2}\.\d+ (TRACE|DEBUG|INFO|WARN|ERROR)\s"#, options: .regularExpression),
           !line[level].contains("ERROR") { return false }
        return line.contains("Error:") || line.contains("Failed to") || line.contains("Cannot create route")
    }
    /// The engine reports «Waiting recovery: to next=<ms> error=…» and reconnects on its own.
    public static func recoverySeconds(_ line: String) -> Int {
        guard let range = line.range(of: #"to next=(\d+)ms"#, options: .regularExpression),
              let ms = Int(line[range].dropFirst(8).dropLast(2)), ms > 0 else { return 5 }
        return max(1, ms / 1000)
    }
    public static func classify(_ line: String) -> EngineEvent? {
        if line.contains("Successfully connected to endpoint") { return .connected }
        if line.contains("Waiting recovery:") { return .reconnecting(seconds: recoverySeconds(line)) }
        if line.contains("Kill switch active; awaiting explicit stop") { return .killSwitchActive }
        if isFailure(line) { return .failure }
        return nil
    }
}

/// The engine: TrustTunnel Client 1.1.11 built from source with our patches (engine/upstream): routing by
/// application (on macOS — by process name, helpers and bundles included) and the kill-switch retention
/// shared with the Windows client. Built by engine/build-engine.sh.
public enum EngineSpec {
    public static let version = "1.1.11-netlane.1"
    public static let executableName = "trusttunnel_client"
}
