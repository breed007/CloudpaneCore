import Darwin
import Foundation

/// What detection found for one provider or one root folder.
public enum RootState: String, Sendable, Hashable, Codable, Comparable {
    /// The root exists and can be walked.
    case installed
    /// The root exists, but the scan will see only part of it.
    case partial
    /// No matching root folder.
    case missing
    /// Something is there but cannot be read: a symbolic link (never followed), a file
    /// where a folder belongs, or a permission failure, which is what a sandboxed app sees
    /// before the user grants access.
    case unavailable

    private var severity: Int {
        switch self {
        case .missing: return 0
        case .installed: return 1
        case .partial: return 2
        case .unavailable: return 3
        }
    }

    public static func < (lhs: RootState, rhs: RootState) -> Bool { lhs.severity < rhs.severity }
}

/// One folder found under a provider parent directory.
public struct DetectedRoot: Sendable, Hashable {
    /// Nil for a folder under Library/CloudStorage that matches no rule.
    public let rule: ProviderRule?
    public let path: String
    public let folderName: String
    public let account: String?
    public let state: RootState
    public let reason: String

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    public var isWalkable: Bool { state == .installed || state == .partial }
}

/// Detection result for one provider rule.
public struct ProviderStatus: Sendable, Hashable {
    public let rule: ProviderRule
    public let state: RootState
    public let reason: String
    /// Every matching root folder; two OneDrive accounts give two roots.
    public let roots: [DetectedRoot]
}

public struct CatalogReport: Sendable, Hashable {
    public let homePath: String
    public let providers: [ProviderStatus]
    /// Entries under Library/CloudStorage that match no rule, walkable or not.
    public let unrecognized: [DetectedRoot]

    /// Why a backup root is refused, or nil when it is acceptable. Sync is not backup: a
    /// folder at or inside a provider root, or anywhere under the folders where providers
    /// keep their synced roots, is never scanned as a backup.
    public func backupRejectionReason(for backup: ScanRoot) -> String? {
        let synced = providers.flatMap(\.roots) + unrecognized
        if let root = synced.first(where: { isSameOrInside(backup.path, $0.path) }) {
            let owner = root.rule.map { "\($0.displayName) folder \(root.folderName)" }
                ?? "folder \(root.folderName) in Library/CloudStorage"
            let relation = isSameOrInside(root.path, backup.path) ? "is the" : "is inside the"
            return "\(backup.name) \(relation) \(owner), which syncs to the cloud. "
                + "Sync is not backup, so it is not scanned as a backup."
        }
        let parents = Set(providers.map(\.rule.parent)).sorted()
        if let parent = parents.first(where: { isSameOrInside(backup.path, homePath + "/" + $0) }) {
            return "\(backup.name) is inside \(parent), where cloud providers keep synced folders. "
                + "Sync is not backup, so it is not scanned as a backup."
        }
        return nil
    }

    /// Roots to scan: every walkable provider root, walkable unrecognized folders when asked,
    /// then the user's backup roots. Backup roots refused by backupRejectionReason(for:) are
    /// left out; ask it for the reason to show the user.
    public func scanRoots(includeUnrecognized: Bool = true, backups: [ScanRoot] = []) -> [ScanRoot] {
        var roots: [ScanRoot] = []
        for status in providers {
            for root in status.roots where root.isWalkable {
                if let rule = root.rule { roots.append(.provider(rule, root: root)) }
            }
        }
        if includeUnrecognized {
            roots += unrecognized.filter(\.isWalkable).map { ScanRoot.unrecognized(path: $0.path) }
        }
        let taken = Set(roots.map(\.path))
        var seen = taken
        for backup in backups where backupRejectionReason(for: backup) == nil
            && seen.insert(backup.path).inserted {
            roots.append(backup)
        }
        return roots
    }
}

/// Decides whether an existing provider root is a partial view.
///
/// Provider-specific checks (Dropbox Selective Sync, OneDrive "Choose folders") would go
/// here once real provider data shows what those settings leave on disk. Return a reason to
/// mark the root partial, or nil.
public protocol PartialViewDetector: Sendable {
    func partialViewReason(rule: ProviderRule, rootPath: String) -> String?
}

/// No partial-view signal: every existing root reads as installed. The default before any
/// scan has run.
public struct NoPartialViewDetector: PartialViewDetector {
    public init() {}
    public func partialViewReason(rule: ProviderRule, rootPath: String) -> String? { nil }
}

/// Partial view from what the last scan saw: a root with folders whose contents the scan
/// could not see. The reason names the cause, so a permission problem or a path that is too
/// long is not blamed on the provider. A root that is merely dataless before a scan is not
/// partial: the folder-listing rule lets the scan fetch its list.
public struct ScanPartialViewDetector: PartialViewDetector {
    private struct Counts {
        var total = 0, notProvided = 0, permission = 0, pathTooLong = 0
    }
    private let unlisted: [String: Counts]

    /// lastScan is the per-root totals of the scan to judge by, usually the latest.
    public init(lastScan: [RootSummary]) {
        var counts: [String: Counts] = [:]
        for summary in lastScan where summary.unlistedFolders > 0 {
            var entry = counts[canonicalPath(summary.root.path)] ?? Counts()
            entry.total += summary.unlistedFolders
            entry.notProvided += summary.unlistedNotProvided
            entry.permission += summary.unlistedPermission
            entry.pathTooLong += summary.unlistedPathTooLong
            counts[canonicalPath(summary.root.path)] = entry
        }
        unlisted = counts
    }

    public func partialViewReason(rule: ProviderRule, rootPath: String) -> String? {
        guard let counts = unlisted[canonicalPath(rootPath)], counts.total > 0 else { return nil }
        func folders(_ n: Int) -> String { n == 1 ? "1 folder" : "\(n) folders" }
        var parts: [String] = []
        if counts.notProvided > 0 {
            parts.append("\(rule.displayName) did not provide the list of \(folders(counts.notProvided)) on this Mac")
        }
        if counts.permission > 0 {
            parts.append("\(folders(counts.permission)) could not be read because permission was denied")
        }
        if counts.pathTooLong > 0 {
            parts.append(counts.pathTooLong == 1 ? "1 folder has a path too long to read"
                         : "\(counts.pathTooLong) folders have paths too long to read")
        }
        let other = counts.total - counts.notProvided - counts.permission - counts.pathTooLong
        if other > 0 {
            parts.append("\(folders(other)) could not be listed")
        }
        let them = counts.total == 1 ? "it" : "them"
        return parts.joined(separator: "; ") + ", so the last scan is missing the files in \(them)"
    }
}

/// Finds provider roots under a home directory. Read-only: it uses lstat(2) and directory
/// listings of the parent folders, never follows a symbolic link, and opens no files.
public struct ProviderCatalog: Sendable {
    public let homePath: String
    public let rules: [ProviderRule]
    public let partialViewDetector: any PartialViewDetector
    /// Parents whose unmatched children are reported as unrecognized. Mobile Documents is
    /// excluded because it always holds other apps' iCloud containers besides CloudDocs.
    public let parentsReportingUnrecognized: Set<String>

    public init(home: URL? = nil,
                rules: [ProviderRule] = ProviderRule.defaultTable,
                partialViewDetector: any PartialViewDetector = NoPartialViewDetector(),
                parentsReportingUnrecognized: Set<String> = ["Library/CloudStorage"]) {
        self.homePath = canonicalPath((home ?? ProviderCatalog.userHome).path)
        self.rules = rules
        self.partialViewDetector = partialViewDetector
        self.parentsReportingUnrecognized = parentsReportingUnrecognized
    }

    /// The user's real home directory from the password database. Inside the App Sandbox,
    /// FileManager's home directory is the app container, which holds no provider roots.
    public static var userHome: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private enum ParentState {
        case listed([String])
        case missing(String)
        case unavailable(String)
    }

    /// Finds every provider root.
    ///
    /// A rule with an exact folder name (iCloud Drive's com~apple~CloudDocs, Box-Box) is
    /// looked up directly, without listing its parent. Under the App Sandbox the app is
    /// granted the CloudDocs folder itself, never Library/Mobile Documents, so listing that
    /// parent would fail. lstat(2) needs no grant there (measured with a sandboxed probe on
    /// macOS 27: lstat succeeds and reports ENOENT, while listing and access(2) fail with
    /// EPERM). Prefix rules and unrecognized folders still need the parent listed.
    public func detect() -> CatalogReport {
        var chains: [String: ParentState] = [:]
        var listings: [String: ParentState] = [:]
        func chain(_ parent: String) -> ParentState {
            if let known = chains[parent] { return known }
            let state = checkParent(parent)
            chains[parent] = state
            return state
        }
        func listing(_ parent: String) -> ParentState {
            if let known = listings[parent] { return known }
            let state: ParentState
            if case .listed = chain(parent) { state = list(parent) } else { state = chain(parent) }
            listings[parent] = state
            return state
        }

        var claimed: Set<String> = []
        var statuses: [ProviderStatus] = []
        for rule in rules {
            switch chain(rule.parent) {
            case .missing(let why):
                statuses.append(ProviderStatus(rule: rule, state: .missing,
                                               reason: "Not installed: \(why)", roots: []))
                continue
            case .unavailable(let why):
                statuses.append(ProviderStatus(rule: rule, state: .unavailable, reason: why, roots: []))
                continue
            case .listed:
                break
            }
            let parentPath = homePath + "/" + rule.parent
            if case .exact(let name) = rule.match {
                let key = rule.parent + "/" + name
                let path = parentPath + "/" + name
                if claimed.contains(key) || (lstatInfo(path) == nil && errno == ENOENT) {
                    statuses.append(summarize(rule: rule, roots: []))
                } else {
                    claimed.insert(key)
                    statuses.append(summarize(rule: rule, roots: [inspect(rule: rule, path: path, name: name)]))
                }
                continue
            }
            switch listing(rule.parent) {
            case .listed(let names):
                let matches = names.filter { !$0.hasPrefix(".") && rule.match.suffix(of: $0) != nil
                    && !claimed.contains(rule.parent + "/" + $0) }
                let roots = matches.map { name -> DetectedRoot in
                    claimed.insert(rule.parent + "/" + name)
                    return inspect(rule: rule, path: parentPath + "/" + name, name: name)
                }
                statuses.append(summarize(rule: rule, roots: roots))
            case .missing(let why):
                statuses.append(ProviderStatus(rule: rule, state: .missing,
                                               reason: "Not installed: \(why)", roots: []))
            case .unavailable(let why):
                statuses.append(ProviderStatus(rule: rule, state: .unavailable, reason: why, roots: []))
            }
        }

        var unrecognized: [DetectedRoot] = []
        for parent in parentsReportingUnrecognized.sorted() {
            guard case .listed(let names) = listing(parent) else { continue }
            for name in names where !name.hasPrefix(".") && !claimed.contains(parent + "/" + name) {
                unrecognized.append(inspect(rule: nil, path: homePath + "/" + parent + "/" + name, name: name))
            }
        }
        return CatalogReport(homePath: homePath, providers: statuses, unrecognized: unrecognized)
    }

    /// Checks every component of the parent below home without following symbolic links.
    /// A symlinked Library or CloudStorage is reported, never followed. Returns
    /// .listed([]) when the chain is sound; the names come from list(_:).
    private func checkParent(_ parent: String) -> ParentState {
        var current = homePath
        var walked: [String] = []
        for component in parent.split(separator: "/").map(String.init) {
            current += "/" + component
            walked.append(component)
            let shown = walked.joined(separator: "/")
            guard let info = lstatInfo(current) else {
                let code = errno
                if code == ENOENT { return .missing("\(shown) does not exist") }
                return .unavailable("Could not read \(shown): \(POSIXErrorCode(code))")
            }
            switch fileType(info) {
            case S_IFDIR: continue
            case S_IFLNK: return .unavailable("\(shown) is a symbolic link, not followed")
            default: return .unavailable("\(shown) is not a folder")
            }
        }
        return .listed([])
    }

    private func list(_ parent: String) -> ParentState {
        do {
            return .listed(try FileManager.default.contentsOfDirectory(atPath: homePath + "/" + parent).sorted())
        } catch {
            return .unavailable("Could not read \(parent): \(describe(error: error))")
        }
    }

    private func inspect(rule: ProviderRule?, path: String, name: String) -> DetectedRoot {
        let account = rule?.account(forFolderName: name)
        func root(_ state: RootState, _ reason: String) -> DetectedRoot {
            DetectedRoot(rule: rule, path: path, folderName: name, account: account,
                         state: state, reason: reason)
        }
        guard let info = lstatInfo(path) else {
            return root(.unavailable, "Could not read \(name): \(POSIXErrorCode())")
        }
        switch fileType(info) {
        case S_IFDIR: break
        case S_IFLNK: return root(.unavailable, "\(name) is a symbolic link, not followed")
        default: return root(.unavailable, "\(name) is not a folder")
        }
        if access(path, R_OK | X_OK) != 0 {
            return root(.unavailable, "Could not read \(name): \(POSIXErrorCode())")
        }
        if let rule, let why = partialViewDetector.partialViewReason(rule: rule, rootPath: path) {
            return root(.partial, why)
        }
        return root(.installed, rule == nil ? "Unrecognized folder, scanned as found" : "Found \(name)")
    }

    /// Rolls account roots up to one provider state. Every root installed: installed. No
    /// root that can be walked: the worst root's state. Anything in between is partial, since
    /// the scan sees some of the provider's data; the working accounts are still scanned and
    /// the reason names the accounts that are not.
    private func summarize(rule: ProviderRule, roots: [DetectedRoot]) -> ProviderStatus {
        guard let worst = roots.map(\.state).max() else {
            return ProviderStatus(rule: rule, state: .missing,
                                  reason: "Not installed: no \(rule.match.pattern) in \(rule.parent)",
                                  roots: [])
        }
        if worst == .installed {
            let reason = roots.count == 1 ? roots[0].reason : "Found \(roots.count) accounts"
            return ProviderStatus(rule: rule, state: .installed, reason: reason, roots: roots)
        }
        let problems = roots.filter { $0.state != .installed }
            .map { "\($0.folderName): \($0.reason)" }.joined(separator: "; ")
        let walkable = roots.filter(\.isWalkable)
        if walkable.isEmpty {
            return ProviderStatus(rule: rule, state: worst, reason: problems, roots: roots)
        }
        let scanned = walkable.count == roots.count
            ? problems
            : "Scanning \(walkable.count) of \(roots.count) accounts. \(problems)"
        return ProviderStatus(rule: rule, state: .partial, reason: scanned, roots: roots)
    }
}
