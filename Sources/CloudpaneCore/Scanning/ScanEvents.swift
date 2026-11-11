import Foundation

/// Running totals, sent at each root boundary and at most every 100 ms in between.
public struct ScanProgress: Sendable, Hashable {
    /// Records emitted so far, across all roots.
    public let filesSeen: Int
    /// Logical bytes of the records emitted so far.
    public let bytesSeen: Int64
    /// The root being walked, or nil once the scan is done.
    public let currentRoot: ScanRoot?
    public let rootsCompleted: Int
    public let rootCount: Int
    /// True while the walk waits for the provider to fetch a folder's list (a folder that
    /// was dataless when reached). A first scan of a large account spends most of its time
    /// here.
    public var gettingFolderList = false
}

/// Why a folder's contents are missing from a scan.
public enum UnlistedCause: String, Sendable, Hashable, Codable {
    /// The folder was still dataless after its listing call.
    case notProvided
    /// The listing failed with EACCES or EPERM.
    case permission
    /// The listing failed because the path is too long.
    case pathTooLong
    /// The listing failed for another reason.
    case other

    /// The cause of a failed listing.
    init(listingError error: Error) {
        let underlying = (error as? FolderLister.Failure).flatMap { failure -> Error? in
            if case .listing(let inner) = failure { return inner }
            return nil
        } ?? error
        switch posixCode(of: underlying) {
        case EACCES, EPERM: self = .permission
        case ENAMETOOLONG: self = .pathTooLong
        default:
            let ns = underlying as NSError
            self = ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadInvalidFileNameError ? .pathTooLong : .other
        }
    }
}

/// Something the scan could not read. The walk continues past it.
public struct ScanIssue: Sendable, Hashable, Codable {
    public let rootID: String
    public let path: String
    /// Includes the errno when there is one, such as "errno 13 Permission denied".
    public let message: String
}

/// Per-root totals. Counts follow the M0 spike: only regular files and packages become
/// records; directories, extra hard links, symbolic links and other file types are counted
/// and skipped.
public struct RootSummary: Sendable, Hashable, Codable {
    public let root: ScanRoot
    public var files = 0
    public var packages = 0
    public var directories = 0
    public var datalessDirectories = 0
    public var logicalBytes: Int64 = 0
    public var allocatedBytes: Int64 = 0
    public var placeholders = 0
    public var placeholderBytes: Int64 = 0
    public var dataless = 0
    public var compressed = 0
    /// Folders whose contents the scan could not see: the listing failed, or the folder was
    /// still dataless after its listing call. Files in them are missing from the scan. The
    /// three counts below split it by cause; the rest could not be listed for another reason.
    public var unlistedFolders = 0
    /// Still dataless after the listing call: the provider did not provide the list.
    public var unlistedNotProvided = 0
    /// The listing failed with EACCES or EPERM.
    public var unlistedPermission = 0
    /// The listing failed because the path is longer than the system allows (PATH_MAX).
    public var unlistedPathTooLong = 0
    public var unlistedOther: Int {
        max(unlistedFolders - unlistedNotProvided - unlistedPermission - unlistedPathTooLong, 0)
    }

    mutating func countUnlisted(_ cause: UnlistedCause) {
        unlistedFolders += 1
        switch cause {
        case .notProvided: unlistedNotProvided += 1
        case .permission: unlistedPermission += 1
        case .pathTooLong: unlistedPathTooLong += 1
        case .other: break
        }
    }
    /// Regular files that report a logical size of 0.
    public var zeroByte = 0
    public var hardLinksSkipped = 0
    public var symlinksSkipped = 0
    public var otherTypesSkipped = 0
    /// Folders skipped because they are another scan root, walked on their own.
    public var nestedRootsSkipped = 0
    public var errors = 0
    /// The part of logicalBytes that comes from the contents of packages.
    public var packageLogicalBytes: Int64 = 0
    /// The part of allocatedBytes that comes from the contents of packages.
    public var packageAllocatedBytes: Int64 = 0
    public var elapsedMilliseconds: Double = 0
    /// True when the scan was canceled before this root was fully walked.
    public var wasInterrupted = false

    public init(root: ScanRoot) { self.root = root }

    mutating func add(_ record: FileRecord) {
        files += 1
        if record.isPackage { packages += 1 }
        let logical = record.logicalSize ?? 0
        logicalBytes += logical
        allocatedBytes += record.allocatedSize ?? 0
        if record.isPlaceholder {
            placeholders += 1
            placeholderBytes += logical
        }
        if record.isDataless { dataless += 1 }
        if record.isCompressed { compressed += 1 }
        if !record.isPackage && record.logicalSize == 0 { zeroByte += 1 }
    }
}

public struct ScanSummary: Sendable, Hashable {
    public let snapshotID: Int64
    public let roots: [RootSummary]
    public let wasCanceled: Bool
    /// Whether dataless materialization was turned off on the walk thread.
    public let materializationDisabled: Bool
    public let startedAt: Date
    public let finishedAt: Date

    public var files: Int { roots.reduce(0) { $0 + $1.files } }
    public var logicalBytes: Int64 { roots.reduce(0) { $0 + $1.logicalBytes } }
}

public enum ScanEvent: Sendable {
    case rootStarted(ScanRoot)
    case file(FileRecord)
    case issue(ScanIssue)
    case progress(ScanProgress)
    case rootFinished(RootSummary)
    /// Always the last event when the consumer is still listening.
    case finished(ScanSummary)
}
