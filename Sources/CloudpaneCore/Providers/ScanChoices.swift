import Foundation

/// A provider the user added in Providers: either a plan with no folder on this Mac (a
/// cost-only plan), or a name for a folder under Library/CloudStorage that matches no
/// built-in provider. Cloudpane only records it; nothing is installed or signed in to.
public struct CustomProvider: Sendable, Hashable, Identifiable, Codable {
    /// Nil until saved.
    public var id: Int64?
    /// The name shown everywhere the provider appears.
    public var name: String
    /// The folder's name under Library/CloudStorage, such as "SyncSpace-Home". Nil for a
    /// cost-only plan.
    public var folderName: String?

    public init(id: Int64? = nil, name: String, folderName: String? = nil) {
        self.id = id
        self.name = name
        self.folderName = folderName
    }

    public static let idPrefix = "custom-"

    /// The provider id its plan, scan roots and records carry: "custom-<id>".
    public var providerID: String { CustomProvider.idPrefix + String(id ?? 0) }

    /// True for a plan with no folder: no space used, no room left, no backup grade.
    public var isCostOnly: Bool { folderName == nil }

    /// True when a provider id belongs to a custom provider.
    public static func isCustom(_ providerID: String) -> Bool { providerID.hasPrefix(idPrefix) }

    /// Problems that stop the provider from being saved, as sentences for the user.
    public func validationProblems() -> [String] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var problems: [String] = []
        if trimmed.isEmpty { problems.append("Enter a name.") }
        if trimmed.count > 60 { problems.append("Enter a name of 60 characters or fewer.") }
        if let folderName, folderName.isEmpty || folderName.contains("/") {
            problems.append("Choose a folder under Library/CloudStorage.")
        }
        return problems
    }
}

/// What the user chose about scanning: accounts to leave out, names for folders that
/// match no provider, and missing accounts to stop showing.
public struct ScanChoices: Sendable, Hashable {
    /// Account root paths, canonical, that scans, the watcher and hashing skip.
    public var excludedRoots: Set<String>
    public var customProviders: [CustomProvider]
    /// Account root paths, canonical, hidden while not found on this Mac.
    public var forgottenRoots: Set<String>

    public init(excludedRoots: Set<String> = [], customProviders: [CustomProvider] = [],
                forgottenRoots: Set<String> = []) {
        self.excludedRoots = Set(excludedRoots.map(canonicalPath))
        self.customProviders = customProviders
        self.forgottenRoots = Set(forgottenRoots.map(canonicalPath))
    }

    /// True when path is an excluded root or lies inside one.
    public func isExcluded(_ path: String) -> Bool {
        excludedRoots.contains { isSameOrInside(path, $0) }
    }

    /// The custom provider that names a folder, if any. Folder names compare exactly.
    public func customProvider(forFolder name: String) -> CustomProvider? {
        customProviders.first { $0.folderName == name }
    }

    /// Provider ids of cost-only plans.
    public var costOnlyProviders: Set<String> {
        Set(customProviders.filter(\.isCostOnly).map(\.providerID))
    }
}

extension ScanRoot {
    /// A folder under Library/CloudStorage that the user named: its own provider.
    public static func custom(path: String, provider: CustomProvider) -> ScanRoot {
        let path = canonicalPath(path)
        let name = (path as NSString).lastPathComponent
        return ScanRoot(id: "\(provider.providerID)/\(name)", kind: .provider, provider: provider.providerID,
                        providerName: provider.name, name: name, account: nil, path: path)
    }
}

extension CatalogReport {
    /// The roots to scan under the user's choices: unrecognized folders the user named
    /// become their custom provider's root, and excluded roots are left out.
    public func scanRoots(includeUnrecognized: Bool = true, backups: [ScanRoot] = [],
                          choices: ScanChoices) -> [ScanRoot] {
        scanRoots(includeUnrecognized: includeUnrecognized, backups: backups).compactMap { root in
            if choices.isExcluded(root.path) { return nil }
            if root.kind == .unrecognized, let custom = choices.customProvider(forFolder: root.name) {
                return .custom(path: root.path, provider: custom)
            }
            return root
        }
    }
}
