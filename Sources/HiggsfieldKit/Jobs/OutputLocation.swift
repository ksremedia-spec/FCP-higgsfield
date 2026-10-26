import Foundation

/// Where finished media is saved. Defaults to `~/Movies/Higgsfield`: Final
/// Cut Pro must be able to read the files it imports, and app containers are
/// off-limits to it, so results live in a user-visible media folder (the
/// extension has the Movies-folder sandbox entitlement).
public struct OutputLocation: Sendable, Equatable {
    public var root: URL

    public init(root: URL) {
        self.root = root
    }

    public static func defaultRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Movies", isDirectory: true).appendingPathComponent("Higgsfield", isDirectory: true)
    }

    /// `<root>/<yyyy-MM-dd>/<clip name>.<ext>`, unique within the folder.
    public func fileURL(for record: JobRecord, resultURL: URL, contentType: String?, fileManager: FileManager = .default) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let folder = root.appendingPathComponent(formatter.string(from: record.createdAt), isDirectory: true)
        let ext = Self.fileExtension(resultURL: resultURL, contentType: contentType, output: record.output)
        let base = Self.sanitize(record.clipName)
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    static func fileExtension(resultURL: URL, contentType: String?, output: MediaKind) -> String {
        let ext = resultURL.pathExtension.lowercased()
        if !ext.isEmpty, ext.count <= 5, MediaKind(fileExtension: ext) != nil { return ext }
        switch contentType?.lowercased().split(separator: ";").first.map(String.init) {
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "video/webm": return "webm"
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        case "image/webp": return "webp"
        default: return output == .image ? "png" : "mp4"
        }
    }

    /// Removes characters that are awkward in file names and FCP clip names.
    static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        let cleaned = name.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        let trimmed = String(cleaned.prefix(120))
        return trimmed.isEmpty ? "Higgsfield" : trimmed
    }
}
