import Darwin
import Foundation
import UniformTypeIdentifiers

/// The synchronous walk behind Scanner. Runs on one thread; not shared.
final class Walker {
    private static let keys: [URLResourceKey] = [
        .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey,
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .isPackageKey,
        .contentTypeKey,
    ]
    private static let progressInterval: Duration = .milliseconds(100)

    private struct FileIdentity: Hashable {
        let device: Int32
        let inode: UInt64
    }

    private let roots: [ScanRoot]
    private let rootPaths: Set<String>
    private let snapshotID: Int64
    private let rule: PlaceholderRule
    private let hooks: ScannerHooks
    private let isCanceled: () -> Bool
    private let emit: (ScanEvent) -> Void

    private let lister: FolderLister
    /// Set when materialization could not be turned back off after a listing. The walk then
    /// stops at once and reads nothing more on this thread.
    private(set) var policyBroken = false

    private let clock = ContinuousClock()
    private var lastProgress: ContinuousClock.Instant
    /// Hard links are counted once per scan, by device and inode. The first path seen wins.
    private var seenInodes: Set<FileIdentity> = []
    private var filesSeen = 0
    private var bytesSeen: Int64 = 0
    private var rootsCompleted = 0

    init(roots: [ScanRoot], snapshotID: Int64, rule: PlaceholderRule, hooks: ScannerHooks,
         isCanceled: @escaping () -> Bool, emit: @escaping (ScanEvent) -> Void) {
        self.roots = roots
        self.rootPaths = Set(roots.map(\.path))
        self.snapshotID = snapshotID
        self.rule = rule
        self.hooks = hooks
        self.lister = hooks.lister
        self.isCanceled = isCanceled
        self.emit = emit
        self.lastProgress = clock.now
    }

    func run(materializationDisabled: Bool) -> ScanSummary {
        let startedAt = Date()
        var summaries: [RootSummary] = []
        var canceled = false
        for root in roots {
            if isCanceled() {
                canceled = true
                break
            }
            emit(.rootStarted(root))
            sendProgress(current: root)
            let summary = walk(root)
            summaries.append(summary)
            rootsCompleted += 1
            emit(.rootFinished(summary))
            if summary.wasInterrupted || policyBroken {
                canceled = true
                break
            }
        }
        sendProgress(current: nil)
        return ScanSummary(snapshotID: snapshotID, roots: summaries, wasCanceled: canceled,
                           materializationDisabled: materializationDisabled,
                           startedAt: startedAt, finishedAt: Date())
    }

    private func sendProgress(current: ScanRoot?, gettingFolderList: Bool = false) {
        lastProgress = clock.now
        emit(.progress(ScanProgress(filesSeen: filesSeen, bytesSeen: bytesSeen, currentRoot: current,
                                    rootsCompleted: rootsCompleted, rootCount: roots.count,
                                    gettingFolderList: gettingFolderList)))
    }

    private func issue(_ summary: inout RootSummary, _ path: String, _ message: String) {
        summary.errors += 1
        emit(.issue(ScanIssue(rootID: summary.root.id, path: path, message: message)))
    }

    private func isDuplicateHardLink(_ info: stat) -> Bool {
        guard info.st_nlink > 1 else { return false }
        return !seenInodes.insert(FileIdentity(device: info.st_dev, inode: info.st_ino)).inserted
    }

    /// Walks a root, or with start set, only the subtree below start (incremental scans).
    ///
    /// Depth first, listing each folder itself rather than through a directory enumerator, so
    /// materialization can be on for the listing call and off for everything else (see
    /// FolderLister). Hidden items are skipped, symbolic links are never followed, packages
    /// are leaves, and a folder that is another scan root is left to that root.
    func walk(_ root: ScanRoot, from subtree: URL? = nil) -> RootSummary {
        let start = clock.now
        var summary = RootSummary(root: root)
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        // Only folders still to list are held, not their contents, so memory stays flat.
        var pending: [URL] = [subtree ?? root.url]
        while let folder = pending.popLast() {
            if isCanceled() {
                summary.wasInterrupted = true
                break
            }
            // One autorelease pool per folder and one per item. Foundation autoreleases URLs
            // and resource values on every step, and a secondary thread only drains its outer
            // pool when it exits, so without these the walk holds every item until the end.
            let keepGoing: Bool = autoreleasepool {
                guard let children = list(folder, root: root, summary: &summary) else { return !policyBroken }
                var subfolders: [URL] = []
                for child in children {
                    if isCanceled() {
                        summary.wasInterrupted = true
                        return false
                    }
                    let descend: URL? = autoreleasepool {
                        visit(child, root: root, rootPrefix: rootPrefix, summary: &summary)
                    }
                    if policyBroken { return false }
                    if let descend { subfolders.append(descend) }
                }
                pending.append(contentsOf: subfolders.reversed())
                return true
            }
            if !keepGoing { break }
        }
        if policyBroken { summary.wasInterrupted = true }
        summary.elapsedMilliseconds = milliseconds(clock.now - start)
        return summary
    }

    /// Lists one folder under the folder-listing rule. Returns nil when it could not be
    /// listed; the failure is counted and reported. A folder that was dataless and still is
    /// after its listing call is reported too: the provider did not provide its list.
    private func list(_ folder: URL, root: ScanRoot, summary: inout RootSummary) -> [URL]? {
        let path = folder.path
        let wasDataless = lister.isDataless(path)
        // Fetching a folder's list can take a while on a first scan; say so.
        if wasDataless { sendProgress(current: root, gettingFolderList: true) }
        defer { if wasDataless { sendProgress(current: root) } }
        do {
            let children = try lister.contents(of: folder, includeHidden: false)
            if wasDataless && lister.isDataless(path) {
                summary.countUnlisted(.notProvided)
                issue(&summary, path, "\(root.providerName) did not provide this folder's list, so files in it are missing from this scan.")
            }
            return children.sorted { $0.path < $1.path }
        } catch FolderLister.Failure.couldNotRestore(let code) {
            policyBroken = true
            issue(&summary, path, "The scan stopped: dataless materialization could not be turned back off after listing this folder (\(code)). Nothing more was read.")
            return nil
        } catch {
            summary.countUnlisted(UnlistedCause(listingError: error))
            let detail = (error as? FolderLister.Failure)?.description ?? describe(error: error)
            issue(&summary, path, "Could not list this \(Walker.folderNoun(root)): \(detail). Files in it are missing from this scan.")
            return nil
        }
    }

    static func folderNoun(_ root: ScanRoot) -> String {
        switch root.kind {
        case .provider: return "\(root.providerName) folder"
        case .backup: return "backup folder"
        case .unrecognized: return "folder"
        }
    }

    /// Records one item, a regular file or a package, outside a walk.
    func visitOne(_ url: URL, root: ScanRoot) -> RootSummary {
        var summary = RootSummary(root: root)
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        _ = autoreleasepool {
            visit(url, root: root, rootPrefix: rootPrefix, summary: &summary)
        }
        return summary
    }

    /// Handles one listed item: counts or skips it, or emits its record. Returns the URL
    /// when it is a folder to walk into. Runs with materialization off.
    private func visit(_ url: URL, root: ScanRoot, rootPrefix: String, summary: inout RootSummary) -> URL? {
        let path = url.path
        hooks.beforeItemRead?(path)
        guard let info = lstatInfo(path) else {
            let code = POSIXErrorCode()
            // Nothing at or below a path that is too long can be read.
            if code.code == ENAMETOOLONG { summary.countUnlisted(.pathTooLong) }
            issue(&summary, path, "lstat \(describeErrno(code))")
            return nil
        }
        // Hidden by flag (UF_HIDDEN); dot-named items never reach here (FolderLister).
        if info.st_flags & UInt32(UF_HIDDEN) != 0 { return nil }
        let type = fileType(info)
        switch type {
        case S_IFLNK:
            summary.symlinksSkipped += 1
            return nil
        case S_IFDIR, S_IFREG:
            break
        default:
            summary.otherTypesSkipped += 1
            return nil
        }
        if type == S_IFDIR && rootPaths.contains(path) {
            summary.nestedRootsSkipped += 1
            return nil
        }

        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: Set(Walker.keys))
        } catch {
            issue(&summary, path, "resource values \(describe(error: error))")
            return nil
        }
        let isPackage = type == S_IFDIR && values.isPackage == true
        if type == S_IFDIR && !isPackage {
            summary.directories += 1
            if info.isDataless { summary.datalessDirectories += 1 }
            return url
        }
        if type == S_IFREG && isDuplicateHardLink(info) {
            summary.hardLinksSkipped += 1
            return nil
        }

        var facts = FileFacts(
            logicalSize: values.fileSize.map(Int64.init),
            allocatedSize: values.totalFileAllocatedSize.map(Int64.init),
            isUbiquitous: values.isUbiquitousItem == true,
            downloadStatus: DownloadStatus(values.ubiquitousItemDownloadingStatus),
            isDataless: info.isDataless,
            isCompressed: info.isCompressed)
        if isPackage {
            let contents = measurePackage(url, summary: &summary)
            if policyBroken { return nil }
            facts.logicalSize = contents.logical
            facts.allocatedSize = contents.allocated
            facts.isDataless = info.isDataless || contents.allDataless
            facts.isCompressed = contents.anyCompressed
            summary.packageLogicalBytes += contents.logical
            summary.packageAllocatedBytes += contents.allocated
        }

        let relative = path.hasPrefix(rootPrefix) ? String(path.dropFirst(rootPrefix.count)) : path
        let contentType = FileCategory.effectiveType(values.contentType)
        let record = FileRecord(
            snapshotID: snapshotID, path: path, rootID: root.id, provider: root.provider,
            relativePath: relative, name: url.lastPathComponent,
            topLevelFolder: FileRecord.topLevelFolder(relativePath: relative, depth: root.topLevelDepth),
            facts: facts, modified: values.contentModificationDate, isPackage: isPackage,
            isPlaceholder: rule.isPlaceholder(facts), contentType: contentType?.identifier,
            category: FileCategory(contentType: contentType), inode: UInt64(info.st_ino),
            statusChanged: Date(timeIntervalSince1970: Double(info.st_ctimespec.tv_sec)
                                + Double(info.st_ctimespec.tv_nsec) / 1e9))
        summary.add(record)
        filesSeen += 1
        bytesSeen += record.logicalSize ?? 0
        emit(.file(record))
        hooks.afterFile?(filesSeen)
        if clock.now - lastProgress >= Walker.progressInterval {
            sendProgress(current: root)
        }
        return nil
    }

    /// Measures a package as one leaf. See PackageMeasure. Internal skips do not appear in
    /// the root's skip counts; errors do.
    private func measurePackage(_ url: URL, summary: inout RootSummary) -> PackageContents {
        var reported: [(String, String)] = []
        var unlisted: [UnlistedCause] = []
        var contents = PackageContents()
        do {
            contents = try PackageMeasure.measure(
                url, lister: lister, isCanceled: isCanceled, isDuplicateHardLink: { isDuplicateHardLink($0) },
                beforeItemRead: { hooks.beforeItemRead?($0) }, unlisted: { unlisted.append($0) },
                issue: { reported.append(($0, $1)) })
        } catch {
            policyBroken = true
            reported.append((url.path, "The scan stopped: dataless materialization could not be turned back off after listing inside this package (\(error)). Nothing more was read."))
        }
        for cause in unlisted { summary.countUnlisted(cause) }
        for (path, message) in reported { issue(&summary, path, message) }
        return contents
    }
}

func milliseconds(_ duration: Duration) -> Double {
    let (seconds, attoseconds) = duration.components
    return Double(seconds) * 1000 + Double(attoseconds) / 1e15
}
