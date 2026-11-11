import Foundation

/// What a user-added backup location is. The user says; Cloudpane cannot tell a NAS from a
/// local disk, or where either physically sits.
public enum BackupKind: String, Sendable, Hashable, Codable, CaseIterable {
    case timeMachine
    case externalDrive
    case nasShare
    case other

    public var displayName: String {
        switch self {
        case .timeMachine: return "Time Machine"
        case .externalDrive: return "External drive"
        case .nasShare: return "NAS share"
        case .other: return "Other"
        }
    }
}

/// A folder the scanner walks: a provider account root, a user-added backup root, or an
/// unrecognized folder under Library/CloudStorage.
public struct ScanRoot: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case provider
        case backup
        case unrecognized
    }

    /// Stable within a snapshot: "onedrive/OneDrive-Personal", "backup/<path>",
    /// "unrecognized/<folder name>".
    public let id: String
    public let kind: Kind
    /// The provider rule id, or "backup" or "unrecognized".
    public let provider: String
    public let providerName: String
    /// The root folder's name, or the label the user gave a backup root.
    public let name: String
    public let account: String?
    /// Absolute path, canonicalized with realpath(3).
    public let path: String
    /// See ProviderRule.topLevelDepth.
    public let topLevelDepth: Int
    /// For a backup root: what the user said it is.
    public let backupKind: BackupKind?
    /// For a backup root: the user says it is kept away from the home.
    public let isOffsite: Bool

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    public init(id: String, kind: Kind, provider: String, providerName: String, name: String,
                account: String?, path: String, topLevelDepth: Int = 1,
                backupKind: BackupKind? = nil, isOffsite: Bool = false) {
        self.id = id
        self.kind = kind
        self.provider = provider
        self.providerName = providerName
        self.name = name
        self.account = account
        self.path = path
        self.topLevelDepth = max(1, topLevelDepth)
        self.backupKind = backupKind
        self.isOffsite = isOffsite
    }

    public static let backupProvider = "backup"
    public static let unrecognizedProvider = "unrecognized"
    /// What the app calls folders that match no provider.
    public static let unrecognizedProviderName = "Other cloud folders"

    static func provider(_ rule: ProviderRule, root: DetectedRoot) -> ScanRoot {
        ScanRoot(id: "\(rule.id)/\(root.folderName)", kind: .provider, provider: rule.id,
                 providerName: rule.displayName, name: root.folderName, account: root.account,
                 path: root.path, topLevelDepth: rule.topLevelDepth)
    }

    static func unrecognized(path: String) -> ScanRoot {
        let name = (path as NSString).lastPathComponent
        return ScanRoot(id: "\(unrecognizedProvider)/\(name)", kind: .unrecognized,
                        provider: unrecognizedProvider, providerName: "Unrecognized", name: name,
                        account: nil, path: path)
    }

    /// A user-added backup destination: a Time Machine folder, an external drive, a NAS share.
    public static func backup(_ url: URL, label: String? = nil, kind: BackupKind = .other,
                              offsite: Bool = false) -> ScanRoot {
        let path = canonicalPath(url.path)
        return ScanRoot(id: "\(backupProvider)/\(path)", kind: .backup, provider: backupProvider,
                        providerName: "Backup", name: label ?? (path as NSString).lastPathComponent,
                        account: nil, path: path, backupKind: kind, isOffsite: offsite)
    }
}
