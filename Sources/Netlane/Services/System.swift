import Foundation
import Network
import Security
import CryptoKit
import NetlaneCore

/// state.json in ~/Library/Application Support/Netlane, readable by this user only (0600 in a 0700 folder).
enum StateStore {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("Netlane", isDirectory: true)
    }()
    static var file: URL { directory.appendingPathComponent("state.json") }

    /// The stored state, or an empty one with a notice when the file cannot be read (it is kept aside).
    static func load() -> (state: ClientState, notice: String?) {
        guard let data = try? Data(contentsOf: file) else { return (ClientState(), nil) }
        do {
            let state = try ClientState.decoded(data)
            let notice = state.droppedDns.isEmpty ? nil : "DNS-серверы отключены, они не прошли проверку: " + state.droppedDns.joined(separator: ", ") + ". Проверьте «Настройки»."
            return (state, notice)
        } catch {
            let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
            let aside = "state.json.bad-" + formatter.string(from: Date())
            try? FileManager.default.moveItem(at: file, to: directory.appendingPathComponent(aside))
            return (ClientState(), "Не удалось прочитать настройки. Добавьте сервер заново; прежний файл сохранён как " + aside + ".")
        }
    }

    static func save(_ state: ClientState) throws {
        let data = try state.encoded()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent("state.json." + UUID().uuidString + ".tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw FormatError("Не удалось сохранить настройки.") }
        if FileManager.default.fileExists(atPath: file.path) { _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: file) }
    }
}

/// The engine log the app keeps for the user: ~/Library/Logs/Netlane/engine.log.
enum EngineLog {
    static let file = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Netlane/engine.log")
    private static let queue = DispatchQueue(label: "netlane.log")
    private static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()

    static func start(_ header: String) {
        queue.async {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int, size > 262_144 { try? FileManager.default.removeItem(at: file) }
            let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd HH:mm:ss"
            append("=== " + day.string(from: Date()) + " " + header + "\n")
        }
    }
    static func write(_ line: String) {
        queue.async { append(stamp.string(from: Date()) + " " + line + "\n") }
    }
    private static func append(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: file) { handle.seekToEndOfFile(); handle.write(data); try? handle.close() }
        else { try? data.write(to: file) }
    }
}

/// Byte counters of a network interface (64-bit, from the routing sysctl).
enum Traffic {
    static func counters(of name: String) -> (received: Int64, sent: Int64)? {
        let index = if_nametoindex(name)
        guard index != 0 else { return nil }
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, Int32(index)]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return nil }
        return buffer.withUnsafeBytes { raw -> (Int64, Int64)? in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if UInt32(info.ifm_index) == index { return (Int64(clamping: info.ifm_data.ifi_ibytes), Int64(clamping: info.ifm_data.ifi_obytes)) }
                }
                if header.ifm_msglen == 0 { break }
                offset += Int(header.ifm_msglen)
            }
            return nil
        }
    }
}

/// Ping of a server: ICMP through /sbin/ping, and the time of a TLS handshake when ICMP gets no answer.
enum Latency {
    struct Result: Equatable { var milliseconds: Int?; var method: String; var detail: String }

    static func measure(_ profile: Profile) async -> Result {
        let endpoint = profile.endpoint
        if let ms = await icmp(endpoint.host) {
            return Result(milliseconds: ms, method: "Ping", detail: "ICMP: среднее из трёх запросов. Замер с этого Mac по текущему маршруту сети.")
        }
        if let ms = await tls(host: endpoint.host, port: endpoint.port, name: profile.hostname) {
            return Result(milliseconds: ms, method: "TLS", detail: "ICMP недоступен. Показано время TCP + TLS с проверкой сертификата, а не обычный ping.")
        }
        return Result(milliseconds: nil, method: "", detail: "ICMP и TCP/TLS не ответили. Это не доказывает, что VPN недоступен: проверьте сеть и транспорт.")
    }

    static func icmp(_ host: String) async -> Int? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/sbin/ping")
                process.arguments = ["-n", "-q", "-c", "3", "-i", "0.3", "-W", "1000", "-t", "4", host]
                let output = Pipe()
                process.standardOutput = output; process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { continuation.resume(returning: nil); return }
                let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                continuation.resume(returning: parsePing(text))
            }
        }
    }
    /// «round-trip min/avg/max/stddev = 41.2/43.9/47.0/2.1 ms» → 44.
    static func parsePing(_ text: String) -> Int? {
        guard let line = text.split(separator: "\n").first(where: { $0.contains("min/avg/max") }), let equals = line.firstIndex(of: "=") else { return nil }
        let numbers = line[line.index(after: equals)...].split(separator: "/")
        guard numbers.count >= 2, let average = Double(numbers[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        return max(1, Int(average.rounded()))
    }

    static func tls(host: String, port: Int, name: String) async -> Int? {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return nil }
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, name)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: NWParameters(tls: options))
        let started = Date()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
            let once = Once()
            func finish(_ value: Int?) {
                guard once.first() else { return }
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(max(1, Int(Date().timeIntervalSince(started) * 1000)))
                case .failed, .cancelled: finish(nil)
                case .waiting: finish(nil)
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { finish(nil) }
        }
    }
}

/// «Only the first caller wins», for callbacks that may fire more than once.
final class Once {
    private let lock = NSLock()
    private var used = false
    func first() -> Bool { lock.lock(); defer { lock.unlock() }; if used { return false }; used = true; return true }
}

/// HTTPS requests of the app: subscriptions, the public IP and the update channel.
enum Net {
    /// No cookies, no cache, no redirects for subscriptions (a redirect could send the token elsewhere).
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    private static func makeSession(redirects: Bool, timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout; configuration.timeoutIntervalForResource = timeout * 2
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": AppInfo.userAgent]
        return URLSession(configuration: configuration, delegate: redirects ? nil : NoRedirect(), delegateQueue: nil)
    }

    static func subscription(_ address: String) async throws -> String {
        guard let url = URL(string: address) else { throw FormatError("Неверный адрес подписки.") }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let session = makeSession(redirects: false, timeout: 15)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { throw FormatError("Подписка не найдена: ссылку перевыпустили в панели или она неверна.") }
            if code != 200 { throw FormatError("Сервер подписки ответил \(code).") }
            if data.count > 256 * 1024 { throw FormatError("Ответ подписки слишком большой.") }
            return String(decoding: data, as: UTF8.self)
        } catch let error as FormatError { throw error }
        catch let error as URLError where error.code == .timedOut { throw FormatError("Сервер подписки не ответил за 15 секунд.") }
        catch { throw FormatError("Сервер подписки недоступен: " + error.localizedDescription) }
    }

    static func text(_ address: String, accept: String? = nil, timeout: TimeInterval = 15) async throws -> String {
        guard let url = URL(string: address) else { throw FormatError("Неверный адрес.") }
        var request = URLRequest(url: url)
        if let accept = accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        let session = makeSession(redirects: true, timeout: timeout)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 { throw FormatError("Сервер ответил \(code).") }
        if data.count > 2 << 20 { throw FormatError("Ответ слишком большой.") }
        return String(decoding: data, as: UTF8.self)
    }

    static func publicIp() async throws -> PublicIp {
        try PublicIp.parse(try await text(PublicIp.traceUrl, timeout: 8))
    }

    /// Downloads a file to a temporary place and returns it with its SHA-256.
    static func download(_ address: String) async throws -> (file: URL, sha256: String) {
        guard let url = URL(string: address) else { throw FormatError("Неверный адрес архива.") }
        let session = makeSession(redirects: true, timeout: 60)
        defer { session.finishTasksAndInvalidate() }
        let (temporary, response) = try await session.download(from: url)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 { throw FormatError("Сервер ответил \(code).") }
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("Netlane-update-" + UUID().uuidString + ".zip")
        try FileManager.default.moveItem(at: temporary, to: kept)
        let handle = try FileHandle(forReadingFrom: kept)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hash.update(data: chunk)
        }
        return (kept, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

/// «Открывать при входе»: a LaunchAgent of this user that opens the app hidden in the menu bar.
enum LoginItem {
    static let plist = URL(fileURLWithPath: NSHomeDirectory() + "/Library/LaunchAgents/" + AppInfo.bundleId + ".plist")
    static var enabled: Bool { FileManager.default.fileExists(atPath: plist.path) }

    static func set(_ on: Bool) throws {
        if !on { try? FileManager.default.removeItem(at: plist); return }
        guard let executable = Bundle.main.executablePath else { return }
        let content: [String: Any] = ["Label": AppInfo.bundleId, "ProgramArguments": [executable, "--hidden"], "RunAtLoad": true, "ProcessType": "Interactive"]
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: content, format: .xml, options: 0).write(to: plist)
    }
}
