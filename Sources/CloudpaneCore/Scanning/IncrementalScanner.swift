import Darwin
import Foundation

/// What an incremental scan found for a set of changed paths.
public struct IncrementalResult: Sendable {
    /// Rows for everything below the rescanned paths.
    public let records: [FileRecord]
    /// The parts of the tree that were looked at again. Current versions inside them that
    /// were not seen again are closed; everything outside carries forward.
    public let scope: [Inventory.ScopeEntry]
    public let issues: [ScanIssue]
    /// Set when the changes cannot be applied piecemeal and a full scan is needed instead.
    public let fullRescanReason: String?
    public let materializationDisabled: Bool
}

/// Rescans only what changed. Each changed path is mapped to its scan root and to the item
/// a full walk would record for it: the path itself, or the package that contains it, since
/// packages are leaves. That item is walked again with the same rules as a full scan, and
/// its subtree becomes the merge scope. Runs on its own thread with dataless
/// materialization off except around folder listings, like Scanner.
public final class IncrementalScanner: Sendable {
    public let roots: [ScanRoot]
    public let changedPaths: Set<String>
    /// Folders whose direct children are scan roots, such as ~/Library/CloudStorage. A
    /// change directly inside one means a root may have appeared or gone: full rescan.
    public let rootParents: [String]
    public let placeholderRule: PlaceholderRule
    let hooks: ScannerHooks

    /// excluding holds account root paths the user excluded: changes at or inside one are
    /// ignored, and such a root is never rescanned.
    public convenience init(roots: [ScanRoot], changedPaths: Set<String>, rootParents: [String] = [],
                            placeholderRule: PlaceholderRule = .default, excluding: Set<String> = []) {
        self.init(roots: roots, changedPaths: changedPaths, rootParents: rootParents,
                  placeholderRule: placeholderRule, hooks: ScannerHooks(), excluding: excluding)
    }

    init(roots: [ScanRoot], changedPaths: Set<String>, rootParents: [String],
         placeholderRule: PlaceholderRule, hooks: ScannerHooks, excluding: Set<String> = []) {
        let choices = ScanChoices(excludedRoots: excluding)
        self.hooks = hooks
        self.roots = roots.filter { !choices.isExcluded($0.path) }
        self.changedPaths = changedPaths.filter { !choices.isExcluded($0) }
        self.rootParents = rootParents.map(canonicalPath)
        self.placeholderRule = placeholderRule
    }

    public func run(snapshotID: Int64) async -> IncrementalResult {
        await withCheckedContinuation { continuation in
            let roots = self.roots, paths = self.changedPaths, parents = self.rootParents, rule = self.placeholderRule
            let hooks = self.hooks
            let thread = Thread {
                autoreleasepool {
                    let disabled: Bool
                    switch MaterializationPolicy.disableForCurrentThread() {
                    case .success: disabled = MaterializationPolicy.isDisabledForCurrentThread
                    case .failure: disabled = false
                    }
                    continuation.resume(returning: IncrementalScanner.scan(
                        roots: roots, paths: paths, parents: parents, rule: rule, hooks: hooks,
                        snapshotID: snapshotID, materializationDisabled: disabled))
                }
            }
            thread.name = "CloudpaneCore.IncrementalScanner"
            thread.qualityOfService = .utility
            thread.start()
        }
    }

    // MARK: - Planning

    struct Target: Hashable {
        let root: ScanRoot
        let path: String
    }

    /// Maps changed paths to the items to rescan, or to a reason a full rescan is needed.
    static func plan(paths: Set<String>, roots: [ScanRoot], parents: [String]) -> (targets: [Target], fullRescan: String?) {
        let byLength = roots.sorted { $0.path.count > $1.path.count }
        var targets: Set<Target> = []
        for raw in paths {
            let path = (raw.hasSuffix("/") && raw.count > 1) ? String(raw.dropLast()) : raw
            if parents.contains(where: { path == $0 || (path as NSString).deletingLastPathComponent == $0 })
                && !roots.contains(where: { path == $0.path || path.hasPrefix($0.path + "/") }) {
                return ([], "A cloud storage folder was added or removed.")
            }
            guard let root = byLength.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }) else { continue }
            if roots.contains(where: { $0.path == path && $0.id != root.id }) { continue }
            guard let target = target(for: path, in: root) else { continue }
            targets.insert(target)
        }
        // A subtree already being rescanned covers anything below it.
        let sorted = targets.sorted { $0.path.count < $1.path.count }
        var kept: [Target] = []
        for candidate in sorted where !kept.contains(where: { candidate.path == $0.path || candidate.path.hasPrefix($0.path + "/") }) {
            kept.append(candidate)
        }
        return (kept, nil)
    }

    /// The item a full walk would record for a changed path, or nil when a full walk would
    /// never reach it (inside a hidden folder or below a symbolic link).
    static func target(for path: String, in root: ScanRoot) -> Target? {
        if path == root.path { return Target(root: root, path: root.path) }
        let relative = path.dropFirst(root.path.count + 1).split(separator: "/").map(String.init)
        var current = root.path
        for (index, component) in relative.enumerated() {
            current += "/" + component
            let isLast = index == relative.count - 1
            if component.hasPrefix(".") { return nil }
            guard let info = lstatInfo(current) else {
                // Gone: rescanning it closes whatever was recorded at or below it.
                return Target(root: root, path: current)
            }
            if info.st_flags & UInt32(UF_HIDDEN) != 0 { return nil }
            switch fileType(info) {
            case S_IFLNK:
                return isLast ? Target(root: root, path: current) : nil
            case S_IFDIR where !isLast:
                // A change inside a package changes the package, which is one leaf.
                let values = try? URL(fileURLWithPath: current, isDirectory: true).resourceValues(forKeys: [.isPackageKey])
                if values?.isPackage == true { return Target(root: root, path: current) }
            default:
                break
            }
        }
        return Target(root: root, path: path)
    }

    // MARK: - Scanning

    static func scan(roots: [ScanRoot], paths: Set<String>, parents: [String], rule: PlaceholderRule,
                     hooks: ScannerHooks = ScannerHooks(), snapshotID: Int64,
                     materializationDisabled: Bool) -> IncrementalResult {
        let (targets, reason) = plan(paths: paths, roots: roots, parents: parents)
        if let reason {
            return IncrementalResult(records: [], scope: [], issues: [], fullRescanReason: reason,
                                     materializationDisabled: materializationDisabled)
        }
        var records: [FileRecord] = []
        var issues: [ScanIssue] = []
        let walker = Walker(roots: roots, snapshotID: snapshotID, rule: rule, hooks: hooks,
                            isCanceled: { false }, emit: { event in
                                switch event {
                                case .file(let record): records.append(record)
                                case .issue(let issue): issues.append(issue)
                                default: break
                                }
                            })
        // A target whose subtree had a folder that could not be listed is left out of the
        // merge: closing rows the walk could not see would drop files that are still there.
        var scope: [Inventory.ScopeEntry] = []
        for target in targets {
            let url = URL(fileURLWithPath: target.path)
            let recordsBefore = records.count
            var unlisted = 0
            if let info = lstatInfo(target.path) {
                switch fileType(info) {
                case S_IFDIR:
                    let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
                    if isPackage && target.path != target.root.path {
                        _ = walker.visitOne(url, root: target.root)
                    } else {
                        unlisted = walker.walk(target.root, from: URL(fileURLWithPath: target.path, isDirectory: true))
                            .unlistedFolders
                    }
                case S_IFREG:
                    _ = walker.visitOne(url, root: target.root)
                default:
                    break
                }
            }
            if walker.policyBroken {
                // Nothing more was read; apply nothing.
                return IncrementalResult(records: [], scope: [], issues: issues, fullRescanReason: nil,
                                         materializationDisabled: materializationDisabled)
            }
            if unlisted > 0 {
                records.removeSubrange(recordsBefore...)
                continue
            }
            scope.append(Inventory.ScopeEntry(path: target.path, subtree: true))
        }
        return IncrementalResult(records: records, scope: scope, issues: issues, fullRescanReason: nil,
                                 materializationDisabled: materializationDisabled)
    }
}
