import Foundation

/// How a provider's root folder name is recognized.
public enum NameMatch: Sendable, Hashable, Codable {
    case exact(String)
    case prefix(String)

    /// The part of the name after the match ("" for an exact match), or nil when the name
    /// does not match.
    public func suffix(of name: String) -> String? {
        switch self {
        case .exact(let value):
            return name == value ? "" : nil
        case .prefix(let value):
            return name.hasPrefix(value) ? String(name.dropFirst(value.count)) : nil
        }
    }

    /// The pattern as a person would write it, for messages: "OneDrive-*".
    public var pattern: String {
        switch self {
        case .exact(let value): return value
        case .prefix(let value): return value + "*"
        }
    }
}

/// One row of the provider table. Provider layout lives here and nowhere else, so a layout
/// change is a data fix.
public struct ProviderRule: Sendable, Hashable, Codable, Identifiable {
    /// Stable identifier stored in the inventory, such as "onedrive".
    public let id: String
    /// Name shown in the UI. Vendor names appear only as data like this.
    public let displayName: String
    /// Directory holding the provider's root folders, relative to the home directory.
    public let parent: String
    public let match: NameMatch
    /// Whether the text after the match names an account ("Personal", an email address).
    public let suffixIsAccount: Bool
    /// How many path components below the root make a top-level folder. Google Drive puts
    /// everything under "My Drive" and "Shared drives", so its top-level folders sit one
    /// level deeper.
    public let topLevelDepth: Int
    /// The provider's own setting that can hide folders from the Mac, named in a
    /// partial-view message. Nil when the provider has none.
    public let partialViewSetting: String?

    public init(id: String, displayName: String, parent: String, match: NameMatch,
                suffixIsAccount: Bool, topLevelDepth: Int = 1, partialViewSetting: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.parent = parent
        self.match = match
        self.suffixIsAccount = suffixIsAccount
        self.topLevelDepth = max(1, topLevelDepth)
        self.partialViewSetting = partialViewSetting
    }

    /// The account named by a root folder, such as "Personal" for "OneDrive-Personal".
    /// Nil when the rule's suffix is not an account or the folder has no suffix.
    public func account(forFolderName name: String) -> String? {
        guard suffixIsAccount, let suffix = match.suffix(of: name) else { return nil }
        let trimmed = suffix.trimmingCharacters(in: CharacterSet(charactersIn: "- ").union(.whitespaces))
        return trimmed.isEmpty ? nil : trimmed
    }
}

public extension ProviderRule {
    static let iCloudDrive = ProviderRule(
        id: "icloud-drive", displayName: "iCloud Drive", parent: "Library/Mobile Documents",
        match: .exact("com~apple~CloudDocs"), suffixIsAccount: false)

    static let dropbox = ProviderRule(
        id: "dropbox", displayName: "Dropbox", parent: "Library/CloudStorage",
        match: .prefix("Dropbox"), suffixIsAccount: true, partialViewSetting: "Selective Sync")

    static let googleDrive = ProviderRule(
        id: "google-drive", displayName: "Google Drive", parent: "Library/CloudStorage",
        match: .prefix("GoogleDrive-"), suffixIsAccount: true, topLevelDepth: 2)

    static let oneDrive = ProviderRule(
        id: "onedrive", displayName: "OneDrive", parent: "Library/CloudStorage",
        match: .prefix("OneDrive-"), suffixIsAccount: true, partialViewSetting: "Choose folders")

    static let box = ProviderRule(
        id: "box", displayName: "Box", parent: "Library/CloudStorage",
        match: .exact("Box-Box"), suffixIsAccount: false)

    /// The default table, in display order.
    static let defaultTable: [ProviderRule] = [iCloudDrive, dropbox, googleDrive, oneDrive, box]
}
