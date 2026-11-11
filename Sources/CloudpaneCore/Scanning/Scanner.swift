import Foundation

/// Walks scan roots and streams what it finds. Read-only: it reads metadata through
/// lstat(2) and URL resource values, never opens a file, and never follows a symbolic link.
/// Dataless materialization is off on its walk thread except around each folder listing
/// call (see FolderLister), so a provider may fetch a folder's list while Cloudpane never
/// reads or downloads a file's contents.
///
/// Each call to scan(snapshotID:) runs one walk on a dedicated thread. The walk is long,
/// blocking file-system work, which does not belong on the Swift concurrency pool, and the
/// thread-scoped I/O policy only holds if the walk stays on one thread.
public final class Scanner: Sendable {
    /// The roots that will be walked, in order: synced roots first, backup roots last.
    public let roots: [ScanRoot]
    /// Backup roots refused because they sit at or inside a synced root. See
    /// CatalogReport.backupRejectionReason(for:), which explains the refusal to the user.
    public let rejectedBackups: [ScanRoot]
    public let placeholderRule: PlaceholderRule
    let hooks: ScannerHooks

    /// Roots left out because the user excluded them from scans.
    public let excludedRoots: [ScanRoot]

    /// excluding holds account root paths the user excluded; a root at or inside one is
    /// not walked.
    public convenience init(roots: [ScanRoot], placeholderRule: PlaceholderRule = .default,
                            excluding: Set<String> = []) {
        self.init(roots: roots, placeholderRule: placeholderRule, hooks: ScannerHooks(), excluding: excluding)
    }

    init(roots: [ScanRoot], placeholderRule: PlaceholderRule, hooks: ScannerHooks, excluding: Set<String> = []) {
        let choices = ScanChoices(excludedRoots: excluding)
        self.excludedRoots = roots.filter { choices.isExcluded($0.path) }
        // The same folder listed twice would be walked twice.
        var seen: Set<String> = []
        let unique = roots.filter { !choices.isExcluded($0.path) && seen.insert($0.path).inserted }
        let synced = unique.filter { $0.kind != .backup }
        // Sync is not backup: a backup root at or inside a synced root would take that
        // root's files away from it. Backups also go last, so a hard link shared with a
        // synced root is always credited to the synced root.
        let backups = unique.filter { $0.kind == .backup }
        let (accepted, rejected) = backups.reduce(into: ([ScanRoot](), [ScanRoot]())) { result, backup in
            if synced.contains(where: { isSameOrInside(backup.path, $0.path) }) {
                result.1.append(backup)
            } else {
                result.0.append(backup)
            }
        }
        self.roots = synced + accepted
        self.rejectedBackups = rejected
        self.placeholderRule = placeholderRule
        self.hooks = hooks
    }

    /// Starts a walk. Stop iterating, or cancel the iterating task, to cancel it; the walk
    /// thread notices before the next item.
    ///
    /// The stream buffers without limit, so a consumer that falls far behind holds records in
    /// memory. The inventory writes faster than the walk reads, so this is not expected to
    /// matter in practice.
    public func scan(snapshotID: Int64) -> AsyncStream<ScanEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: ScanEvent.self,
                                                            bufferingPolicy: .unbounded)
        let flag = CancellationFlag()
        continuation.onTermination = { _ in flag.cancel() }
        let roots = self.roots
        let rule = self.placeholderRule
        let hooks = self.hooks
        let thread = Thread {
            autoreleasepool {
                Scanner.walk(roots: roots, snapshotID: snapshotID, rule: rule, hooks: hooks,
                             flag: flag, continuation: continuation)
            }
        }
        thread.name = "CloudpaneCore.Scanner"
        thread.qualityOfService = .utility
        thread.start()
        return stream
    }

    private static func walk(roots: [ScanRoot], snapshotID: Int64, rule: PlaceholderRule,
                             hooks: ScannerHooks, flag: CancellationFlag,
                             continuation: AsyncStream<ScanEvent>.Continuation) {
        let disabled: Bool
        switch MaterializationPolicy.disableForCurrentThread() {
        case .success: disabled = MaterializationPolicy.isDisabledForCurrentThread
        case .failure: disabled = false
        }
        let walker = Walker(roots: roots, snapshotID: snapshotID, rule: rule, hooks: hooks,
                            isCanceled: { flag.isCanceled },
                            emit: { continuation.yield($0) })
        let summary = walker.run(materializationDisabled: disabled)
        continuation.yield(.finished(summary))
        continuation.finish()
        hooks.walkFinished?(summary)
    }
}

/// True when path is base or lies below it. Compares case-insensitively after Unicode
/// normalization, since the default APFS volume is case-insensitive and normalization-
/// insensitive; a false match on a case-sensitive volume only refuses a backup root.
func isSameOrInside(_ path: String, _ base: String) -> Bool {
    let p = SearchKey.make(path)
    let b = SearchKey.make(base)
    return p == b || p.hasPrefix(b.hasSuffix("/") ? b : b + "/")
}

/// Test seams. Internal; production code passes none.
struct ScannerHooks: Sendable {
    /// Called on the walk thread after each file record is emitted, with the running count.
    var afterFile: (@Sendable (Int) -> Void)?
    /// Called on the walk thread when the walk ends, canceled or not.
    var walkFinished: (@Sendable (ScanSummary) -> Void)?
    /// How folders are listed. Tests replace it to stand in for a provider.
    var lister: FolderLister = .live
    /// Called on the walk thread just before an item's metadata is read (lstat, then
    /// resource values), so tests can check the thread's materialization policy there.
    var beforeItemRead: (@Sendable (String) -> Void)?
}

final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func cancel() { lock.withLock { value = true } }
    var isCanceled: Bool { lock.withLock { value } }
}
