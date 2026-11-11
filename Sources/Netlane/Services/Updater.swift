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

    /// Downloads and unpacks the new version, then hands over to it (see `apply`) and quits this one.
    @MainActor
    static func install(_ manifest: UpdateManifest) async throws {
        guard canReplaceItself else { throw FormatError("Перенесите Netlane в папку «Программы» и запустите оттуда: из текущего места приложение не может обновить себя.") }
        var archive: URL?
        var failure = "Не удалось скачать обновление."
        for address in [manifest.url, manifest.mirror].compactMap({ $0 }) {
            do {
                let downloaded = try await Net.download(address)
                if downloaded.sha256 != manifest.sha256 { try? FileManager.default.removeItem(at: downloaded.file); failure = "Контрольная сумма архива не совпала. Обновление не установлено."; continue }
                archive = downloaded.file
                break
            } catch { failure = "Не удалось скачать обновление: " + ((error as? FormatError)?.message ?? error.localizedDescription) }
        }
        guard let zip = archive else { throw FormatError(failure) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Netlane-update-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path]) == 0 else { throw FormatError("Не удалось распаковать обновление.") }
        try? FileManager.default.removeItem(at: zip)
        let fresh = folder.appendingPathComponent("Netlane.app")
        let executable = fresh.appendingPathComponent("Contents/MacOS/Netlane")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw FormatError("В архиве обновления нет Netlane.app.") }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--apply-update", installedPath, String(ProcessInfo.processInfo.processIdentifier)]
        try process.run()
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
        let log = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Netlane/update.log")
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        var journal = ""
        func note(_ text: String) { journal += text + "\n"; try? journal.write(to: log, atomically: true, encoding: .utf8) }
        let source = Bundle.main.bundlePath
        note("update \(AppInfo.version): \(source) → \(target)")
        guard target.hasSuffix("/Netlane.app") || target.hasSuffix(".app"), source.hasSuffix(".app"), source != target else { note("unexpected paths"); exit(2) }
        for _ in 0..<300 where kill(pid, 0) == 0 { usleep(100_000) }
        if kill(pid, 0) == 0 { note("the old version did not quit"); exit(3) }
        let backup = target + ".previous"
        try? FileManager.default.removeItem(atPath: backup)
        do {
            try FileManager.default.moveItem(atPath: target, toPath: backup)
            if run("/usr/bin/ditto", [source, target]) != 0 {
                try? FileManager.default.removeItem(atPath: target)
                try FileManager.default.moveItem(atPath: backup, toPath: target)
                note("copy failed, the previous version is back")
            } else {
                try? FileManager.default.removeItem(atPath: backup)
                note("installed")
            }
        } catch { note("failed: \(error.localizedDescription)") }
        run("/usr/bin/open", ["-n", target])
        try? FileManager.default.removeItem(atPath: (source as NSString).deletingLastPathComponent)
        exit(0)
    }
}
