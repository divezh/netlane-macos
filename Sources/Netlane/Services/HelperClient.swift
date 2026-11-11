import Foundation
import NetlaneCore

/// The app's side of the helper socket (see HelperProtocol) and the helper's installation.
enum Helper {
    enum Status: Equatable { case missing, outdated(String), ready }

    static var resources: String { Bundle.main.resourcePath ?? "" }

    /// Connects to the helper's socket; nil when the helper is not running.
    static func open() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = HelperProtocol.socketPath
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (i, byte) in path.utf8.enumerated() where i < raw.count - 1 { raw[i] = byte }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result != 0 { close(fd); return nil }
        return fd
    }

    static func send(_ fd: Int32, _ message: HelperProtocol.Message) {
        let bytes = Array((HelperProtocol.encode(message) + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written <= 0 { if written < 0 && errno == EINTR { continue }; return }
            offset += written
        }
    }

    /// Reads lines until the socket closes. Blocking: call it off the main thread.
    static func readLines(_ fd: Int32, _ handle: (String) -> Void) {
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { return }
            buffer += chunk[..<count]
            while let newline = buffer.firstIndex(of: 10) {
                handle(String(decoding: buffer[..<newline], as: UTF8.self))
                buffer.removeSubrange(...newline)
            }
            if buffer.count > 4 * HelperProtocol.maxLine { return }
        }
    }

    /// Asks the running helper for its version. Blocking, at most two seconds.
    static func status() -> Status {
        guard let fd = open() else { return .missing }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        send(fd, .hello(version: nil, engine: nil))
        var answer: HelperProtocol.Message?
        var buffer = [UInt8](), chunk = [UInt8](repeating: 0, count: 1024)
        while answer == nil {
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 { break }
            buffer += chunk[..<count]
            if let newline = buffer.firstIndex(of: 10) { answer = HelperProtocol.decode(String(decoding: buffer[..<newline], as: UTF8.self)) }
        }
        guard case .hello(let version, let engine)? = answer, let found = version else { return .outdated("?") }
        return found == AppInfo.version && engine == EngineSpec.version ? .ready : .outdated(found)
    }

    enum InstallError: Error { case cancelled, failed(String) }

    /// Runs a script from the app's resources as root; macOS shows its administrator prompt.
    private static func runAsRoot(script: String, arguments: [String], prompt: String) throws {
        let path = resources + "/" + script
        guard FileManager.default.fileExists(atPath: path) else { throw InstallError.failed("В приложении нет файла " + script + ". Скачайте Netlane заново.") }
        // Paths are passed as arguments and quoted by AppleScript itself, never pasted into the command text.
        let items = (1...(arguments.count + 1)).map { "quoted form of (item \($0) of argv)" }.joined(separator: " & \" \" & ")
        let lines = ["on run argv", "do shell script \"/bin/sh \" & " + items + " with prompt \"" + prompt + "\" with administrator privileges", "end run"]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = lines.flatMap { ["-e", $0] } + [path] + arguments
        let errors = Pipe()
        process.standardError = errors; process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch { throw InstallError.failed(error.localizedDescription) }
        let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        if process.terminationStatus == 0 { return }
        // -128: the user pressed «Отмена» in the password prompt.
        if text.contains("-128") { throw InstallError.cancelled }
        throw InstallError.failed(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Installs or replaces the helper, then waits until it answers. Blocking.
    static func install() throws {
        try runAsRoot(script: "install-helper.sh", arguments: [resources, String(getuid())],
                      prompt: "Netlane установит помощник, который включает VPN без запроса пароля при каждом подключении.")
        for _ in 0..<50 {
            if status() == .ready { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw InstallError.failed("Помощник установлен, но не отвечает. Журнал: /Library/Logs/Netlane-helper.log")
    }

    static func uninstall() throws {
        try runAsRoot(script: "uninstall-helper.sh", arguments: [], prompt: "Netlane удалит помощник VPN с этого Mac.")
    }
}

/// One engine session as the app sees it: start it, get events, stop it.
final class HelperSession {
    private let fd: Int32
    private var closed = false
    private let lock = NSLock()

    /// `onMessage` and `onEnd` are called on the main queue; `onEnd` once, when the helper closes the socket.
    init?(profile: Profile, onMessage: @escaping (HelperProtocol.Message) -> Void, onEnd: @escaping () -> Void) {
        guard let fd = Helper.open() else { return nil }
        self.fd = fd
        Helper.send(fd, .start(profile))
        Thread.detachNewThread { [self] in
            Helper.readLines(fd) { line in
                guard let message = HelperProtocol.decode(line) else { return }
                DispatchQueue.main.async { onMessage(message) }
            }
            self.close()
            DispatchQueue.main.async { onEnd() }
        }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        if !closed { Helper.send(fd, .stop) }
    }

    private func close() {
        lock.lock(); defer { lock.unlock() }
        if !closed { closed = true; Darwin.close(fd) }
    }
}
