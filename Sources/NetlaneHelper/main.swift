// Netlane helper: a small root daemon that starts and stops the VPN engine for the app.
//
// macOS lets only root create a tunnel interface and change routes. Instead of asking for the
// administrator password at every connection, the app installs this helper once (launchd starts it
// as root) and then talks to it over a Unix socket.
//
// What keeps it narrow:
//   * only the user it was installed for (and root) may connect — the peer's uid is checked;
//   * it accepts a profile, never a command line or a config: the profile passes the same checks as
//     in the app and the engine config is written here;
//   * it runs one fixed program: the engine copied into a root-owned folder at installation.
import Foundation
import NetlaneCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: Options (from the launchd plist, which only root can edit)

struct Options {
    var socketPath = HelperProtocol.socketPath
    var enginePath = HelperProtocol.supportDirectory + "/engine/" + EngineSpec.executableName
    var runDirectory = HelperProtocol.supportDirectory + "/run"
    var allowedUid: uid_t?
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())
    while arguments.count >= 2 {
        let key = arguments.removeFirst(), value = arguments.removeFirst()
        switch key {
        case "--uid": options.allowedUid = uid_t(value)
        case "--socket": options.socketPath = value
        case "--engine": options.enginePath = value
        case "--run-dir": options.runDirectory = value
        default: break
        }
    }
    return options
}

func note(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

// MARK: Socket plumbing

/// One client connection: line-based reads and locked writes.
final class Peer {
    let fd: Int32
    private let writeLock = NSLock()
    private var buffer = [UInt8]()
    init(fd: Int32) { self.fd = fd }

    func send(_ message: HelperProtocol.Message) {
        let bytes = Array((HelperProtocol.encode(message) + "\n").utf8)
        writeLock.lock(); defer { writeLock.unlock() }
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written <= 0 { if written < 0 && errno == EINTR { continue }; return }
            offset += written
        }
    }

    /// The next line, or nil when the client closed the socket or sent an oversized line.
    func readLine() -> String? {
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let line = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer.removeSubrange(...newline)
                return line
            }
            if buffer.count > HelperProtocol.maxLine { return nil }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = read(fd, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { return nil }
            buffer += chunk[..<count]
        }
    }

    var uid: uid_t? {
        #if canImport(Darwin)
        var user: uid_t = 0, group: gid_t = 0
        return getpeereid(fd, &user, &group) == 0 ? user : nil
        #else
        return getuid()   // Linux is only used to test the protocol; the daemon itself is for macOS.
        #endif
    }
}

func listen(at path: String) -> Int32 {
    #if canImport(Darwin)
    let stream = SOCK_STREAM
    #else
    let stream = Int32(SOCK_STREAM.rawValue)
    #endif
    let fd = socket(AF_UNIX, stream, 0)
    guard fd >= 0 else { note("socket: \(String(cString: strerror(errno)))"); exit(1) }
    unlink(path)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < capacity else { note("socket path is too long"); exit(1) }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        for (i, byte) in path.utf8.enumerated() { raw[i] = byte }
    }
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard bound == 0 else { note("bind \(path): \(String(cString: strerror(errno)))"); exit(1) }
    // Anyone may reach the socket; who is served is decided by the peer's uid.
    chmod(path, 0o666)
    guard listen(fd, 4) == 0 else { note("listen: \(String(cString: strerror(errno)))"); exit(1) }
    return fd
}

/// Names of the tunnel interfaces that exist right now.
func tunnelInterfaces() -> Set<String> {
    var names = Set<String>()
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0 else { return names }
    defer { freeifaddrs(list) }
    var item = list
    while let current = item {
        let name = String(cString: current.pointee.ifa_name)
        if name.hasPrefix("utun") || name.hasPrefix("tun") { names.insert(name) }
        item = current.pointee.ifa_next
    }
    return names
}

// MARK: The engine session

final class Session {
    static let gate = NSLock()
    static var current: Session?

    let options: Options
    let peer: Peer
    let process = Process()
    private let state = NSLock()
    private var stopping = false
    private var finished = false
    private var sawError = false
    private var tunnelSent = false
    private var before = Set<String>()
    private var configPath: String { options.runDirectory + "/session.toml" }

    init(options: Options, peer: Peer) { self.options = options; self.peer = peer }

    /// Refuses an engine that anyone but root could have replaced.
    func checkEngine() throws {
        var info = stat()
        guard stat(options.enginePath, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw FormatError("Движок не найден. Переустановите помощник в «Настройках».") }
        if getuid() == 0 && (info.st_uid != 0 || (info.st_mode & 0o022) != 0) { throw FormatError("Файл движка доступен для записи не только администратору. Переустановите помощник в «Настройках».") }
    }

    func run(_ profile: Profile) {
        do {
            try checkEngine()
            let config = try profile.engineConfig()
            try FileManager.default.createDirectory(atPath: options.runDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            unlink(configPath)
            guard FileManager.default.createFile(atPath: configPath, contents: Data(config.utf8), attributes: [.posixPermissions: 0o600]) else { throw FormatError("Не удалось записать настройки сессии.") }
            peer.send(.log("session.toml (пароль скрыт):\n" + Profile.mask(config)))
            before = tunnelInterfaces()
            process.executableURL = URL(fileURLWithPath: options.enginePath)
            process.arguments = ["--config", configPath]
            process.currentDirectoryURL = URL(fileURLWithPath: options.runDirectory)
            let output = Pipe()
            process.standardOutput = output; process.standardError = output; process.standardInput = FileHandle.nullDevice
            try process.run()
            peer.send(.event(.started, detail: nil))
            Thread.detachNewThread { [self] in self.watchClient() }
            pump(output.fileHandleForReading)
            process.waitUntilExit()
            state.lock(); finished = true; let asked = stopping; state.unlock()
            peer.send(.log("движок завершился с кодом \(process.terminationStatus)"))
            peer.send(.event(asked || process.terminationStatus == 0 ? .stopped : .connectionError, detail: nil))
            if !asked && process.terminationStatus != 0 { peer.send(.event(.stopped, detail: nil)) }
        } catch {
            peer.send(.event(.helperError, detail: (error as? FormatError)?.message ?? error.localizedDescription))
            state.lock(); finished = true; state.unlock()
        }
        unlink(configPath)
    }

    /// Engine output, line by line: every line goes to the app's log, some of them are events.
    private func pump(_ handle: FileHandle) {
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self).trimmingCharacters(in: .newlines)
                buffer.removeSubrange(buffer.startIndex...newline)
                report(line: line)
            }
            if buffer.count > 16384 { report(line: String(decoding: buffer, as: UTF8.self)); buffer.removeAll() }
        }
        if !buffer.isEmpty { report(line: String(decoding: buffer, as: UTF8.self)) }
    }

    private func report(line: String) {
        if line.isEmpty { return }
        peer.send(.log(line))
        switch EngineEvent.classify(line) {
        case .connected:
            peer.send(.event(.connected, detail: nil))
            if let name = tunnelInterfaces().subtracting(before).sorted().first { peer.send(.tunnel(name)) }
        case .reconnecting(let seconds): peer.send(.event(.reconnecting, detail: String(seconds)))
        case .killSwitchActive: peer.send(.event(.killSwitch, detail: nil))
        case .failure: peer.send(.event(.connectionError, detail: nil))
        case nil: break
        }
    }

    /// «stop» or a closed socket (the app quit or crashed) ends the session.
    private func watchClient() {
        while let line = peer.readLine() {
            if HelperProtocol.decode(line) == .stop { break }
        }
        stop()
    }

    /// SIGINT lets the engine remove its routes and DNS; harder signals follow only if it does not exit.
    func stop() {
        state.lock()
        if stopping || finished { state.unlock(); return }
        stopping = true
        state.unlock()
        peer.send(.event(.stopping, detail: nil))
        process.interrupt()
        for second in 1...30 {
            Thread.sleep(forTimeInterval: 1)
            state.lock(); let done = finished || !process.isRunning; state.unlock()
            if done { return }
            if second == 12 { peer.send(.event(.stopFailed, detail: nil)); process.terminate() }
            if second == 20 { kill(process.processIdentifier, SIGKILL) }
        }
    }
}

// MARK: Serving

func serve(_ peer: Peer, _ options: Options) {
    defer { shutdown(peer.fd, Int32(SHUT_RDWR)); close(peer.fd) }
    guard let uid = peer.uid, uid == 0 || uid == options.allowedUid || (options.allowedUid == nil && uid == getuid()) else {
        peer.send(.event(.helperError, detail: "Помощник установлен для другого пользователя. Переустановите его в «Настройках»."))
        return
    }
    while let line = peer.readLine() {
        switch HelperProtocol.decode(line) {
        case .hello:
            peer.send(.hello(version: AppInfo.version, engine: EngineSpec.version))
        case .start(let profile):
            Session.gate.lock()
            if Session.current != nil { Session.gate.unlock(); peer.send(.event(.busy, detail: nil)); return }
            let session = Session(options: options, peer: peer)
            Session.current = session
            Session.gate.unlock()
            session.run(profile)
            Session.gate.lock(); Session.current = nil; Session.gate.unlock()
            return
        default:
            peer.send(.event(.helperError, detail: "Неизвестный запрос."))
            return
        }
    }
}

let options = parseOptions()
signal(SIGPIPE, SIG_IGN)
// launchd stops the helper with SIGTERM (reinstall, removal, shutdown): the engine must not outlive it.
signal(SIGTERM, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: DispatchQueue.global())
termination.setEventHandler {
    Session.gate.lock(); let session = Session.current; Session.gate.unlock()
    if let session = session {
        session.stop()
        // stop() returns at once when the app already asked for it: wait for the engine itself.
        for _ in 0..<250 where session.process.isRunning { Thread.sleep(forTimeInterval: 0.1) }
    }
    unlink(options.socketPath)
    exit(0)
}
termination.resume()

let listener = listen(at: options.socketPath)
note("Netlane helper \(AppInfo.version), engine \(EngineSpec.version), socket \(options.socketPath)")
while true {
    let fd = accept(listener, nil, nil)
    if fd < 0 { if errno == EINTR { continue }; note("accept: \(String(cString: strerror(errno)))"); exit(1) }
    #if canImport(Darwin)
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    #endif
    let peer = Peer(fd: fd)
    Thread.detachNewThread { serve(peer, options) }
}
