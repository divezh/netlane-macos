import Foundation

/// An update offer: the version, the archive and its SHA-256. `mirror` stays for older call sites; the latest
/// release has one download address.
public struct UpdateManifest: Equatable, Sendable {
    public var version: String, url: String, sha256: String
    public var notes: String?, mirror: String?
    public func isNewer(than current: String) -> Bool {
        guard let offered = AppVersion(version), let mine = AppVersion(current) else { return false }
        return offered > mine
    }
}

public enum UpdateFeed {
    /// Updates come from one place: the latest published release of the public repository (drafts and
    /// pre-releases are never «latest»). The archive is its asset, checked by the SHA-256 digest GitHub computes.
    public static let repository = "divezh/netlane-macos"
    public static let releaseUrl = "https://api.github.com/repos/" + repository + "/releases/latest"
    public static let releasesPage = "https://github.com/" + repository + "/releases"
    public static let assetName = "Netlane-macos.zip"

    public static func parseRelease(_ json: String) throws -> UpdateManifest {
        guard let root = Loose.object(json, limit: 1 << 21) else { throw FormatError("GitHub вернул неожиданный ответ о релизе.") }
        if Loose.bool(root["draft"]) == true || Loose.bool(root["prerelease"]) == true { throw FormatError("Последний релиз — предварительный.") }
        var tag = Loose.string(root, "tag_name")
        if let value = tag, value.lowercased().hasPrefix("v") { tag = String(value.dropFirst()) }
        guard let asset = (root["assets"] as? [[String: Any]])?.first(where: { Loose.string($0, "name") == assetName }) else { throw FormatError("В последнем релизе нет " + assetName + ".") }
        var sha: String?
        if let digest = Loose.string(asset, "digest"), digest.lowercased().hasPrefix("sha256:") { sha = String(digest.dropFirst(7)) }
        return try validate(tag, Loose.string(asset, "browser_download_url"), sha, releaseNotes(Loose.string(root, "body")), nil)
    }

    /// The dialog shows one short line: the points of the release notes (the CHANGELOG section), joined.
    public static func releaseNotes(_ body: String?) -> String? {
        guard let body = body else { return nil }
        let points = body.replacingOccurrences(of: "\r", with: "").split(separator: "\n").compactMap { raw -> String? in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- ") || line.hasPrefix("* ") else { return nil }
            return line.dropFirst(2).replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        }
        var notes = points.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if notes.count > 240 { notes = String(notes.prefix(240)).trimmingCharacters(in: .whitespaces) + "…" }
        return notes.isEmpty ? nil : notes
    }

    static func isHttps(_ url: String?) -> Bool {
        guard let url = url, url.count <= 2048, let parts = URLComponents(string: url) else { return false }
        return parts.scheme == "https" && !(parts.host ?? "").isEmpty
    }

    static func validate(_ version: String?, _ url: String?, _ sha: String?, _ notes: String?, _ mirror: String?) throws -> UpdateManifest {
        guard let version = version, AppVersion(version) != nil else { throw FormatError("В последнем релизе нет версии.") }
        guard let url = url, isHttps(url) else { throw FormatError("В последнем релизе нет ссылки на архив.") }
        guard let sha = sha, Text.matches(sha, "^[0-9a-fA-F]{64}$") else { throw FormatError("У архива в последнем релизе нет SHA-256.") }
        var cleanNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = cleanNotes, value.isEmpty || value.count > 500 || Text.hasControl(value) { cleanNotes = nil }
        return UpdateManifest(version: version, url: url, sha256: sha.lowercased(), notes: cleanNotes, mirror: isHttps(mirror) && mirror != url ? mirror : nil)
    }
}
