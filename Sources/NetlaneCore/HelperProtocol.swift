import Foundation

/// The conversation between the app and the root helper: one JSON object per line over a Unix socket.
///
///     app    → {"type":"hello"}
///     helper → {"type":"hello","version":"0.7.0","engine":"1.1.11"}
///     app    → {"type":"start","profile":{…}}
///     helper → {"type":"event","value":"STARTED"} … {"type":"log","line":"…"} … {"type":"event","value":"STOPPED"}
///     app    → {"type":"stop"}          (closing the socket stops the engine as well)
///
/// The helper never takes a command line or a config from the app: it gets a profile, checks it with
/// the same rules as the app and writes the engine config itself.
public enum HelperProtocol {
    public static let label = "io.github.divezh.netlane.helper"
    public static let socketPath = "/var/run/io.github.divezh.netlane.sock"
    public static let installedHelper = "/Library/PrivilegedHelperTools/" + label
    public static let supportDirectory = "/Library/Application Support/Netlane"
    public static let daemonPlist = "/Library/LaunchDaemons/" + label + ".plist"
    public static let maxLine = 65536

    public enum Event: String, Sendable {
        case started = "STARTED", connected = "CONNECTED", reconnecting = "RECONNECTING", killSwitch = "KILL_SWITCH_ACTIVE"
        case connectionError = "CONNECTION_ERROR", stopping = "STOPPING", stopped = "STOPPED", stopFailed = "STOP_FAILED"
        case busy = "BUSY", helperError = "HELPER_ERROR"
    }

    public enum Message: Equatable, Sendable {
        case hello(version: String?, engine: String?)
        case start(Profile)
        case stop
        /// `detail` carries the seconds of RECONNECTING, the interface of a tunnel or an error text.
        case event(Event, detail: String?)
        case log(String)
        case tunnel(String)
    }

    public static func encode(_ message: Message) -> String {
        var object: [String: Any]
        switch message {
        case .hello(let version, let engine):
            object = ["type": "hello"]
            if let version = version { object["version"] = version }
            if let engine = engine { object["engine"] = engine }
        case .start(let profile):
            let data = (try? JSONEncoder().encode(profile)) ?? Data("{}".utf8)
            object = ["type": "start", "profile": (try? JSONSerialization.jsonObject(with: data)) ?? [:]]
        case .stop: object = ["type": "stop"]
        case .event(let event, let detail):
            object = ["type": "event", "value": event.rawValue]
            if let detail = detail { object["detail"] = detail }
        case .log(let line): object = ["type": "log", "line": String(line.prefix(4000))]
        case .tunnel(let name): object = ["type": "tunnel", "name": name]
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        // JSONSerialization never emits raw newlines, so one message is always one line.
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ line: String) -> Message? {
        guard line.utf8.count <= maxLine, let object = Loose.object(line, limit: maxLine), let type = Loose.string(object, "type") else { return nil }
        switch type {
        case "hello": return .hello(version: Loose.string(object, "version"), engine: Loose.string(object, "engine"))
        case "start":
            guard let raw = object["profile"] as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: raw),
                  var profile = try? JSONDecoder().decode(Profile.self, from: data), (try? profile.validate()) != nil else { return nil }
            return .start(profile)
        case "stop": return .stop
        case "event":
            guard let event = Loose.string(object, "value").flatMap(Event.init(rawValue:)) else { return nil }
            return .event(event, detail: Loose.string(object, "detail"))
        case "log": return Loose.string(object, "line").map(Message.log)
        case "tunnel":
            guard let name = Loose.string(object, "name"), Text.matches(name, "^[a-z]+[0-9]{1,4}$") else { return nil }
            return .tunnel(name)
        default: return nil
        }
    }
}
