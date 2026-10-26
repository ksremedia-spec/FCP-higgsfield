#if os(macOS)
import Foundation
import HiggsfieldKit
import Security

/// Locations shared by the container app and the workflow extension.
///
/// Info.plist keys (set by App/project.yml):
/// - `HiggsfieldAppGroup`: App Group identifier for the shared container.
/// - `HiggsfieldKeychainGroup`: Keychain access group for shared credentials.
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
        } else {
            root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("HiggsfieldFCP", isDirectory: true)
        }
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
    public var settingsFile: URL { root.appendingPathComponent("settings.json") }
    /// Tool drafts, restored when Final Cut Pro reopens the extension.
    public var draftsFile: URL { root.appendingPathComponent("drafts.json") }

    public func tokenStore() -> KeychainTokenStore {
        KeychainTokenStore(service: "HiggsfieldFCP.credentials", accessGroup: keychainGroup)
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

/// Stores credentials as a generic password in the (optionally shared) Keychain.
public struct KeychainTokenStore: TokenStore {
    public let service: String
    public let accessGroup: String?
    private let account = "higgsfield-account"

    public init(service: String, accessGroup: String?) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func query(shared: Bool) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if shared, let accessGroup {
            q[kSecAttrAccessGroup as String] = accessGroup
            q[kSecUseDataProtectionKeychain as String] = true
        }
        return q
    }

    /// Runs `body` against the shared access group, falling back to the
    /// app-private keychain when the build lacks the entitlement (unsigned builds).
    private func withGroupFallback(_ body: (_ shared: Bool) -> OSStatus) -> OSStatus {
        let status = body(accessGroup != nil)
        if status == errSecMissingEntitlement && accessGroup != nil { return body(false) }
        return status
    }

    public func load() throws -> TokenSet? {
        var result: CFTypeRef?
        let status = withGroupFallback { shared in
            var q = query(shared: shared)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            return SecItemCopyMatching(q as CFDictionary, &result)
        }
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw HiggsfieldError.invalidInput("Keychain read failed (\(status)).")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TokenSet.self, from: data)
    }

    public func save(_ tokens: TokenSet) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(tokens)
        let status = withGroupFallback { shared in
            let attributes: [String: Any] = [kSecValueData as String: data]
            var status = SecItemUpdate(query(shared: shared) as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var add = query(shared: shared)
                add[kSecValueData as String] = data
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                status = SecItemAdd(add as CFDictionary, nil)
            }
            return status
        }
        guard status == errSecSuccess else { throw HiggsfieldError.invalidInput("Keychain write failed (\(status)).") }
    }

    public func clear() throws {
        let status = withGroupFallback { shared in SecItemDelete(query(shared: shared) as CFDictionary) }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw HiggsfieldError.invalidInput("Keychain delete failed (\(status)).")
        }
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
