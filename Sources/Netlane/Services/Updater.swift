import AppKit
import NetlaneCore

/// Updates from the public channel (UpdateFeed): download, SHA-256 check, replace the app, start it again.
enum Updater {
    static func fetchManifest() async throws -> UpdateManifest {
        var channelError: String
        do { return try UpdateFeed.parse(try await Net.text(UpdateFeed.manifestUrl, accept: "application/json")) }
        catch { channelError = (error as? FormatError)?.message ?? error.localizedDescription }
        do { return try UpdateFeed.parseRelease(try await Net.text(UpdateFeed.releaseUrl, accept: "application/vnd.github+json")) }
        catch { throw FormatError("Канал обновлений недоступен: " + channelError + " / " + ((error as? FormatError)?.message ?? error.localizedDescription)) }
    }

    /// A quarantined app opened straight from «Загрузки» runs from a read-only copy and cannot replace itself.
    static var installedPath: String { Bundle.main.bundlePath }
    static var canReplaceItself: Bool {
        let path = installedPath
        return path.hasSuffix(".app") && !path.contains("/AppTranslocation/") && FileManager.default.isWritableFile(atPath: (path as NSString).deletingLastPathComponent)
    }

    static let logFile = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Netlane/update.log")

    /// One line of ~/Library/Logs/Netlane/update.log, shared by the old and the new copy.
    static func log(_ text: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = Data((stamp + " " + text + "\n").utf8)
        try? FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: logFile) { handle.seekToEndOfFile(); handle.write(line); try? handle.close() }
        else { try? line.write(to: logFile) }
    }

    /// Downloads, checks and unpacks the new version off the main thread, reporting each stage, then hands
    /// over to it (see `apply`) and quits this copy.
    @MainActor
    static func install(_ manifest: UpdateManifest, progress: @escaping @MainActor (String) -> Void) async throws {
        guard canReplaceItself else { throw FormatError("Перенесите Netlane в папку «Программы» и запустите оттуда: из текущего места приложение не может обновить себя.") }
        log("update \(AppInfo.version) → \(manifest.version): start")
        var archive: URL?
        var failure = "Не удалось скачать обновление."
        for address in [manifest.url, manifest.mirror].compactMap({ $0 }) {
            progress("Скачиваю версию " + manifest.version + "…")
            do {
                let downloaded = try await Net.download(address)
                log("downloaded \(address) sha256=\(downloaded.sha256)")
                if downloaded.sha256 != manifest.sha256 { try? FileManager.default.removeItem(at: downloaded.file); failure = "Контрольная сумма архива не совпала. Обновление не установлено."; continue }
                archive = downloaded.file
                break
            } catch {
                failure = "Не удалось скачать обновление: " + ((error as? FormatError)?.message ?? error.localizedDescription)
                log("download failed \(address): \(error.localizedDescription)")
            }
        }
        guard let zip = archive else { throw FormatError(failure) }
        progress("Распаковываю…")
        let executable: URL = try await Task.detached(priority: .userInitiated) {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Netlane-update-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path]) == 0 else { throw FormatError("Не удалось распаковать обновление.") }
            try? FileManager.default.removeItem(at: zip)
            let executable = folder.appendingPathComponent("Netlane.app/Contents/MacOS/Netlane")
            guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw FormatError("В архиве обновления нет Netlane.app.") }
            return executable
        }.value
        log("unpacked to \(executable.path)")
        progress("Перезапускаю Netlane…")
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--apply-update", installedPath, String(ProcessInfo.processInfo.processIdentifier)]
        do { try process.run() }
        catch { log("cannot start the new copy: \(error.localizedDescription)"); throw FormatError("Не удалось запустить новую версию: " + error.localizedDescription) }
        log("handed over to pid \(process.processIdentifier), quitting")
        // The new copy waits for this one to exit. terminate can be held back (an open sheet, a menu):
        // if the app is still alive two seconds later, it exits anyway; the helper stops the VPN on its own.
        for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { log("terminate did not finish, exiting"); exit(0) }
        NSApp.terminate(nil)
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Runs inside the freshly downloaded copy: waits for the old version to quit, puts itself in its
    /// place and opens it. Journal: ~/Library/Logs/Netlane/update.log.
    static func apply(target: String, pid: Int32) -> Never {
        func note(_ text: String) { log(text) }
        let source = Bundle.main.bundlePath
        note("update \(AppInfo.version): \(source) → \(target)")
        guard target.hasSuffix("/Netlane.app") || target.hasSuffix(".app"), source.hasSuffix(".app"), source != target else { note("unexpected paths"); exit(2) }
        for _ in 0..<600 where kill(pid, 0) == 0 { usleep(100_000) }
        if kill(pid, 0) == 0 { note("the old version did not quit"); exit(3) }
        // A hidden, unique name next to the app: a copy installed by an older installer belongs to root and
        // may not be deletable by this user, so a leftover must never block the next update.
        let parent = (target as NSString).deletingLastPathComponent
        let backup = parent + "/.Netlane.app.previous-" + String(Int(Date().timeIntervalSince1970))
        do {
            try FileManager.default.moveItem(atPath: target, toPath: backup)
            if run("/usr/bin/ditto", [source, target]) != 0 {
                try? FileManager.default.removeItem(atPath: target)
                try FileManager.default.moveItem(atPath: backup, toPath: target)
                note("copy failed, the previous version is back")
            } else {
                do { try FileManager.default.removeItem(atPath: backup) } catch { note("previous copy left at \(backup): \(error.localizedDescription)") }
                note("installed")
            }
        } catch { note("failed: \(error.localizedDescription)") }
        run("/usr/bin/open", ["-n", target])
        try? FileManager.default.removeItem(atPath: (source as NSString).deletingLastPathComponent)
        exit(0)
    }
}
