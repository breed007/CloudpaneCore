import CryptoKit
import Darwin
import Foundation

/// A file to hash, as the inventory recorded it. The hash is kept only if the file still
/// matches these facts after it was read.
public struct HashItem: Sendable, Hashable {
    public let path: String
    public let size: Int64
    public let modified: Date?
    public let inode: UInt64?
    /// The inode change time recorded with the file. A hash is kept only if it still matches.
    public let statusChanged: Date?
    public let isPlaceholder: Bool
    /// True only for a cloud-only file in a set the user confirmed downloading. Any other
    /// file found dataless when it is about to be read is skipped, never downloaded.
    public let allowDownload: Bool

    public init(path: String, size: Int64, modified: Date?, inode: UInt64?, statusChanged: Date? = nil,
                isPlaceholder: Bool, allowDownload: Bool = false) {
        self.path = path
        self.size = size
        self.modified = modified
        self.inode = inode
        self.statusChanged = statusChanged
        self.isPlaceholder = isPlaceholder
        self.allowDownload = allowDownload
    }

    /// The same file, not allowed to download.
    public var localOnly: HashItem {
        HashItem(path: path, size: size, modified: modified, inode: inode, statusChanged: statusChanged,
                 isPlaceholder: isPlaceholder, allowDownload: false)
    }
}

public struct HashResult: Sendable, Hashable {
    public let item: HashItem
    /// Lowercase hex SHA-256.
    public let sha256: String
}

public struct HashProgress: Sendable, Hashable {
    public let filesDone: Int
    public let bytesDone: Int64
    public let filesTotal: Int
    public let bytesTotal: Int64
    public let currentPath: String?
}

public struct HashSummary: Sendable, Hashable {
    public let hashed: Int
    /// Found only in the cloud (evicted since the plan was made, or never confirmed) and
    /// skipped: hashing them needs the user's confirmation of the download.
    public let needsConfirmation: Int
    /// Changed while being read, gone, or no longer a regular file. Nothing was stored.
    public let skipped: Int
    public let failed: Int
    public let wasCanceled: Bool
    /// Whether materialization was on for the worker thread, which it must be to read a
    /// file that is only in the cloud.
    public let materializationEnabledOnWorker: Bool
}

public enum HashEvent: Sendable {
    case progress(HashProgress)
    case hashed(HashResult)
    case issue(ScanIssue)
    case finished(HashSummary)
}

/// Reads files and computes SHA-256 with CryptoKit, for folders the user opted in to.
///
/// This is the only place Cloudpane reads file contents. It runs on its own thread at
/// utility quality of service. With downloads allowed it is the only thread where dataless
/// materialization is turned on, and even then a file is read only if it is on the Mac or is
/// one the user confirmed downloading: lstat(2) runs right before open, and a dataless file
/// outside the confirmed set is skipped. With downloads not allowed (the automatic pass over
/// files already on the Mac), materialization stays off, so a mistake fails instead of
/// downloading.
/// Files are opened read-only with O_NOFOLLOW, never written, moved or coordinated, read in
/// 1 MB chunks inside an autorelease pool, and checked again after reading: a file whose
/// size or modification date changed meanwhile is skipped rather than hashed wrongly.
/// Canceling stops before the next chunk; hashes already reported stay recorded.
public final class FileHasher: Sendable {
    public let items: [HashItem]
    /// Whether this run may download confirmed cloud-only files.
    public let allowsDownloads: Bool
    static let chunkSize = 1 << 20

    public init(items: [HashItem], allowsDownloads: Bool = true) {
        self.items = allowsDownloads ? items : items.map(\.localOnly)
        self.allowsDownloads = allowsDownloads
    }

    public func run() -> AsyncStream<HashEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: HashEvent.self, bufferingPolicy: .unbounded)
        let flag = CancellationFlag()
        continuation.onTermination = { _ in flag.cancel() }
        let items = self.items
        let downloads = allowsDownloads && items.contains(where: \.allowDownload)
        let thread = Thread {
            autoreleasepool {
                let enabled: Bool
                if downloads {
                    switch MaterializationPolicy.enableForCurrentThread() {
                    case .success: enabled = MaterializationPolicy.isEnabledForCurrentThread
                    case .failure: enabled = false
                    }
                } else {
                    MaterializationPolicy.disableForCurrentThread()
                    enabled = MaterializationPolicy.isEnabledForCurrentThread
                }
                let summary = FileHasher.hashAll(items, enabled: enabled, isCanceled: { flag.isCanceled },
                                                 emit: { continuation.yield($0) })
                continuation.yield(.finished(summary))
                continuation.finish()
            }
        }
        thread.name = "CloudpaneCore.FileHasher"
        thread.qualityOfService = .utility
        thread.start()
        return stream
    }

    static func hashAll(_ items: [HashItem], enabled: Bool, isCanceled: () -> Bool,
                        isDataless: (stat) -> Bool = { $0.isDataless },
                        emit: (HashEvent) -> Void) -> HashSummary {
        let totalBytes = items.reduce(Int64(0)) { $0 + $1.size }
        var filesDone = 0, bytesDone: Int64 = 0, hashed = 0, skipped = 0, failed = 0, unconfirmed = 0
        var canceled = false
        var lastProgress = Date.distantPast
        for item in items {
            if isCanceled() {
                canceled = true
                break
            }
            if Date().timeIntervalSince(lastProgress) > 0.1 {
                lastProgress = Date()
                emit(.progress(HashProgress(filesDone: filesDone, bytesDone: bytesDone, filesTotal: items.count,
                                            bytesTotal: totalBytes, currentPath: item.path)))
            }
            switch hash(item, isCanceled: isCanceled, isDataless: isDataless) {
            case .success(let digest):
                hashed += 1
                emit(.hashed(HashResult(item: item, sha256: digest)))
            case .failure(.canceled):
                canceled = true
            case .failure(.changed):
                skipped += 1
            case .failure(.needsConfirmation):
                unconfirmed += 1
            case .failure(.error(let message)):
                failed += 1
                emit(.issue(ScanIssue(rootID: "", path: item.path, message: message)))
            }
            if canceled { break }
            filesDone += 1
            bytesDone += item.size
        }
        emit(.progress(HashProgress(filesDone: filesDone, bytesDone: bytesDone, filesTotal: items.count,
                                    bytesTotal: totalBytes, currentPath: nil)))
        return HashSummary(hashed: hashed, needsConfirmation: unconfirmed, skipped: skipped, failed: failed,
                           wasCanceled: canceled,
                           materializationEnabledOnWorker: enabled)
    }

    enum HashFailure: Error {
        case canceled
        case changed
        /// Dataless and not in a confirmed download: left for the user to confirm.
        case needsConfirmation
        case error(String)
    }

    static func matches(_ info: stat, _ item: HashItem) -> Bool {
        guard fileType(info) == S_IFREG, Int64(info.st_size) == item.size else { return false }
        if let inode = item.inode, UInt64(info.st_ino) != inode { return false }
        if let modified = item.modified {
            let seconds = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
            if abs(seconds - modified.timeIntervalSince1970) > 0.001 { return false }
        }
        if let changed = item.statusChanged {
            let seconds = Double(info.st_ctimespec.tv_sec) + Double(info.st_ctimespec.tv_nsec) / 1e9
            if abs(seconds - changed.timeIntervalSince1970) > 0.001 { return false }
        }
        return true
    }

    static func hash(_ item: HashItem, isCanceled: () -> Bool,
                     isDataless: (stat) -> Bool = { $0.isDataless }) -> Result<String, HashFailure> {
        // Checked immediately before open: a file evicted since the plan was made keeps its
        // size, dates and inode, so only SF_DATALESS tells it would download.
        guard let before = lstatInfo(item.path) else { return .failure(.changed) }
        if isDataless(before) && !item.allowDownload { return .failure(.needsConfirmation) }
        guard matches(before, item) else { return .failure(.changed) }
        let fd = open(item.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return .failure(.error("open \(POSIXErrorCode())")) }
        defer { close(fd) }
        // The file could have been evicted between lstat and open. Check the open descriptor
        // before the first read, which is what would download it.
        var opened = stat()
        guard fstat(fd, &opened) == 0 else { return .failure(.error("fstat \(POSIXErrorCode())")) }
        if isDataless(opened) && !item.allowDownload { return .failure(.needsConfirmation) }
        // Large reads should not push everything else out of the page cache.
        _ = fcntl(fd, F_NOCACHE, 1)
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            if isCanceled() { return .failure(.canceled) }
            let count: Int = autoreleasepool {
                buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, chunkSize) }
            }
            if count < 0 { return .failure(.error("read \(POSIXErrorCode())")) }
            if count == 0 { break }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, matches(after, item) else { return .failure(.changed) }
        return .success(hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
