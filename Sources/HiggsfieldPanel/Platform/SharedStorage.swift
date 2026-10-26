#if os(macOS)
import Foundation
import HiggsfieldKit
import Security

/// Locations shared by the container app and the workflow extension.
///
/// By default (personal build, no App Group) both processes use
/// `~/Library/Application Support/HiggsfieldFCP`; the sandboxed extension has
/// a read-write exception for exactly that folder. Optional Info.plist keys
/// (set by App/Config/Local.xcconfig for a paid developer team) switch to
/// stronger sharing:
/// - `HiggsfieldAppGroup`: App Group identifier for the shared container.
/// - `HiggsfieldKeychainGroup`: Keychain access group for credentials.
public struct SharedStorage: Sendable {
    public let appGroup: String?
    public let keychainGroup: String?
    public let root: URL

    public init(bundle: Bundle = .main) {
        let info = bundle.infoDictionary ?? [:]
        func setting(_ key: String) -> String? {
            guard let v = info[key] as? String, !v.isEmpty, !v.contains("$(") else { return nil }
            return v
        }
        appGroup = setting("HiggsfieldAppGroup")
        keychainGroup = setting("HiggsfieldKeychainGroup")
        if let appGroup, let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            root = url
            Self.adoptPersonalFiles(from: Self.personalRoot, to: url)
        } else {
            root = Self.personalRoot
        }
    }

    /// The folder used without an App Group.
    public static var personalRoot: URL {
        realHomeDirectory.appendingPathComponent("Library/Application Support/HiggsfieldFCP", isDirectory: true)
    }

    /// The user's real home folder. Inside the sandbox `NSHomeDirectory()` and
    /// `homeDirectoryForCurrentUser` point at the extension's container.
    public static var realHomeDirectory: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Brings job history, settings, drafts and the sign-in over the first time
    /// an App Group container is used, so switching from the personal setup
    /// to a paid team loses nothing. Runs once (a marker file records it). The
    /// sign-in file is moved rather than copied; with a Keychain group it is
    /// then taken into the Keychain on first read.
    static func adoptPersonalFiles(from old: URL, to new: URL) {
        let fm = FileManager.default
        let marker = new.appendingPathComponent(".adopted-personal-files")
        guard old.standardizedFileURL != new.standardizedFileURL, !fm.fileExists(atPath: marker.path) else { return }
        try? fm.createDirectory(at: new, withIntermediateDirectories: true)
        let copied = ["app", "extension"].flatMap { ["jobs-\($0).json", "settings-\($0).json", "drafts-\($0).json"] }
        for name in copied + ["credentials.json"] {
            let source = old.appendingPathComponent(name), destination = new.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path), !fm.fileExists(atPath: destination.path) else { continue }
            if name == "credentials.json" {
                try? fm.moveItem(at: source, to: destination)
            } else {
                try? fm.copyItem(at: source, to: destination)
            }
        }
        fm.createFile(atPath: marker.path, contents: Data())
    }

    /// Explicit locations (tests, previews).
    public init(root: URL, appGroup: String? = nil, keychainGroup: String? = nil) {
        self.root = root
        self.appGroup = appGroup
        self.keychainGroup = keychainGroup
    }

    /// Separate job lists for the app window and the extension, so two
    /// processes never poll and rewrite the same records.
    public func jobsFile(extension isExtension: Bool) -> URL {
        root.appendingPathComponent(isExtension ? "jobs-extension.json" : "jobs-app.json")
    }
    /// Files received from Final Cut Pro's File ▸ Share (“Open with” the container app).
    public var inbox: URL { root.appendingPathComponent("Inbox", isDirectory: true) }
    public var workDirectory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("HiggsfieldFCP", isDirectory: true) }
    /// Per-context so the app and the extension never overwrite each other's choices.
    public func settingsFile(extension isExtension: Bool) -> URL {
        root.appendingPathComponent(isExtension ? "settings-extension.json" : "settings-app.json")
    }
    /// Tool drafts, restored when Final Cut Pro reopens the extension.
    public func draftsFile(extension isExtension: Bool) -> URL {
        root.appendingPathComponent(isExtension ? "drafts-extension.json" : "drafts-app.json")
    }
    /// Outcome of the last CLI token request served by the container app.
    public var cliStatusFile: URL { root.appendingPathComponent("cli-status.json") }

    /// Credentials shared by the app and the extension: the Keychain when a
    /// shared Keychain group is provisioned, otherwise a private (0600) file in
    /// the shared folder — the same way the official CLI keeps its login.
    public func tokenStore() -> TokenStore {
        let file = FileTokenStore(url: root.appendingPathComponent("credentials.json"))
        guard let keychainGroup else { return file }
        return KeychainTokenStore(service: "HiggsfieldFCP.credentials", accessGroup: keychainGroup, fallback: file)
    }

    /// Lists media in the Share inbox, newest first.
    public func inboxItems() -> [URL] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        return urls.filter { MediaKind(fileExtension: $0.pathExtension) != nil }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
    }
}

/// Stores credentials as a generic password in a shared Keychain group. If
/// the build lacks that entitlement, `fallback` is used so both processes
/// still see the same credentials. A sign-in found only in `fallback` (from
/// the personal setup) is moved into the Keychain on first read.
public struct KeychainTokenStore: TokenStore {
    public let service: String
    public let accessGroup: String
    public let fallback: TokenStore
    private let account = "higgsfield-account"

    public init(service: String, accessGroup: String, fallback: TokenStore) {
        self.service = service
        self.accessGroup = accessGroup
        self.fallback = fallback
    }

    private func query() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public func load() throws -> TokenSet? {
        var q = query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecMissingEntitlement { return try fallback.load() }
        if status == errSecItemNotFound {
            guard let tokens = try fallback.load() else { return nil }
            if (try? writeToKeychain(tokens)) == errSecSuccess { try? fallback.clear() }
            return tokens
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw HiggsfieldError.invalidInput("Keychain read failed (\(status)).")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TokenSet.self, from: data)
    }

    public func save(_ tokens: TokenSet) throws {
        let status = try writeToKeychain(tokens)
        if status == errSecMissingEntitlement { return try fallback.save(tokens) }
        guard status == errSecSuccess else { throw HiggsfieldError.invalidInput("Keychain write failed (\(status)).") }
    }

    private func writeToKeychain(_ tokens: TokenSet) throws -> OSStatus {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(tokens)
        var status = SecItemUpdate(query() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query()
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status
    }

    public func clear() throws {
        let status = SecItemDelete(query() as CFDictionary)
        if status == errSecMissingEntitlement { return try fallback.clear() }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw HiggsfieldError.invalidInput("Keychain delete failed (\(status)).")
        }
        // Signing out must not leave a file sign-in to be adopted back.
        try? fallback.clear()
    }
}

/// Outcome of a CLI token request, shared from the app to the extension.
struct CLIStatus: Codable {
    var ok: Bool
    var message: String?
    var date = Date()

    func write(to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    static func read(from url: URL) -> CLIStatus? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CLIStatus.self, from: data)
    }
}

/// Persisted panel preferences (selected workspace, last tool, output folder).
public struct PanelSettings: Codable, Equatable, Sendable {
    public var workspaceID: String?
    public var lastOperation: OperationKind = .generateVideo
    public var outputFolder: URL?
    public var eventName: String = "Higgsfield AI"
    public var lastJobTypes: [String: String] = [:]
    /// Import finished results into the open library automatically (nil = default for the context).
    public var autoImport: Bool?
    /// Security-scoped bookmarks for folders the user allowed the extension to read.
    public var securityBookmarks: [Data] = []

    enum CodingKeys: String, CodingKey {
        case workspaceID, lastOperation, outputFolder, eventName, lastJobTypes, autoImport, securityBookmarks
    }

    /// Tolerates missing keys so older settings files keep loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workspaceID = try c.decodeIfPresent(String.self, forKey: .workspaceID)
        lastOperation = try c.decodeIfPresent(OperationKind.self, forKey: .lastOperation) ?? .generateVideo
        outputFolder = try c.decodeIfPresent(URL.self, forKey: .outputFolder)
        eventName = try c.decodeIfPresent(String.self, forKey: .eventName) ?? "Higgsfield AI"
        lastJobTypes = try c.decodeIfPresent([String: String].self, forKey: .lastJobTypes) ?? [:]
        autoImport = try c.decodeIfPresent(Bool.self, forKey: .autoImport)
        securityBookmarks = try c.decodeIfPresent([Data].self, forKey: .securityBookmarks) ?? []
    }

    public init() {}

    public static func load(from url: URL) -> PanelSettings {
        guard let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(PanelSettings.self, from: data) else { return PanelSettings() }
        return s
    }

    public func save(to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
#endif
