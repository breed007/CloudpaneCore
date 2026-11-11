import Darwin
import Foundation

/// The size of a Photos library package on this Mac, as an estimate of what iCloud Photos
/// stores. It is read from file metadata only: Cloudpane never opens a photo, never reads
/// the library's database, and does not use PhotoKit.
///
/// It is an estimate in both directions. With Optimize Mac Storage on, Photos keeps smaller
/// versions here and leaves the originals in iCloud, so the library is smaller than what
/// iCloud stores. The package also holds thumbnails, caches and edits that iCloud does not
/// count, and a library that does not use iCloud Photos at all is not in iCloud. Files that
/// are APFS clones of each other share their blocks on disk but each count in full here, so
/// the estimate can be well above the size Finder shows for the library.
public struct PhotosLibraryEstimate: Sendable, Hashable, Codable {
    /// Logical bytes of every regular file in the package: the figure shown as the estimate.
    public let logicalBytes: Int64
    /// The sum of each file's allocated size. Not shown: APFS clones share blocks, so this
    /// overstates what the library occupies on disk (it can exceed logicalBytes).
    public let allocatedBytes: Int64
    public let fileCount: Int
    /// Files inside the package whose data is not on this Mac.
    public let datalessCount: Int
    /// Items Cloudpane could not read the size of. The estimate leaves them out.
    public let unreadableCount: Int
    public let measuredAt: Date

    public init(logicalBytes: Int64, allocatedBytes: Int64, fileCount: Int, datalessCount: Int,
                unreadableCount: Int, measuredAt: Date) {
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.fileCount = fileCount
        self.datalessCount = datalessCount
        self.unreadableCount = unreadableCount
        self.measuredAt = measuredAt
    }
}

public enum PhotosLibraryError: Error, Sendable, Equatable, CustomStringConvertible {
    case notFound
    case notAPhotosLibrary
    /// macOS refused to list the package. Cloudpane does not ask for Full Disk Access, so
    /// this is reported, never worked around.
    case accessDenied
    case canceled
    case unreadable(String)

    public var description: String {
        switch self {
        case .notFound:
            return "The Photos library is no longer at the place you chose."
        case .notAPhotosLibrary:
            return "Choose a Photos library. Its name ends in .photoslibrary."
        case .accessDenied:
            return "macOS did not let Cloudpane read the size of this library, so there is no Photos estimate. Enter your total iCloud usage instead."
        case .canceled:
            return "Measuring the Photos library was canceled."
        case .unreadable(let detail):
            return "Cloudpane could not read the Photos library. \(detail)"
        }
    }
}

public enum PhotosLibrary {
    public static let pathExtension = "photoslibrary"

    /// Measures the package at url. The caller holds whatever access the user granted;
    /// this only lists the package and reads metadata. Runs synchronously: call it off the
    /// main thread.
    public static func estimate(at url: URL, now: Date = Date(),
                                isCanceled: () -> Bool = { false }) throws -> PhotosLibraryEstimate {
        guard url.pathExtension.lowercased() == pathExtension else { throw PhotosLibraryError.notAPhotosLibrary }
        let path = url.path
        guard let info = lstatInfo(path) else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { throw PhotosLibraryError.notFound }
            if code == EPERM || code == EACCES { throw PhotosLibraryError.accessDenied }
            throw PhotosLibraryError.unreadable(String(cString: strerror(code)))
        }
        guard fileType(info) == S_IFDIR else { throw PhotosLibraryError.notAPhotosLibrary }

        // Ask for the listing first, so a refusal is a clear answer rather than an empty
        // estimate.
        guard let directory = opendir(path) else {
            let code = errno
            if code == EPERM || code == EACCES { throw PhotosLibraryError.accessDenied }
            throw PhotosLibraryError.unreadable(String(cString: strerror(code)))
        }
        closedir(directory)

        var seen: Set<[UInt64]> = []
        var unreadable = 0
        let contents: PackageContents
        do {
            // The library is a local folder, never dataless, and this runs on whatever thread
            // the caller uses (the app uses a detached task), so the thread's
            // materialization policy is never touched here.
            contents = try PackageMeasure.measure(
                url, lister: .withoutMaterialization, isCanceled: isCanceled,
                isDuplicateHardLink: { info in
                    guard info.st_nlink > 1 else { return false }
                    return !seen.insert([UInt64(bitPattern: Int64(info.st_dev)), info.st_ino]).inserted
                },
                issue: { _, _ in unreadable += 1 })
        } catch {
            throw PhotosLibraryError.unreadable("Measuring stopped: \(error).")
        }
        if isCanceled() { throw PhotosLibraryError.canceled }
        return PhotosLibraryEstimate(logicalBytes: contents.logical, allocatedBytes: contents.allocated,
                                     fileCount: contents.files, datalessCount: contents.datalessFiles,
                                     unreadableCount: unreadable, measuredAt: now)
    }
}

/// A total the user read from System Settings and typed in, because the account-wide
/// figure is not readable locally without an Apple ID.
public struct ReportedUsage: Sendable, Hashable, Codable {
    public let provider: String
    public let bytes: Int64
    public let enteredAt: Date

    public init(provider: String, bytes: Int64, enteredAt: Date = Date()) {
        self.provider = provider
        self.bytes = bytes
        self.enteredAt = enteredAt
    }

    /// Problems that stop the total from being saved, as sentences for the user.
    public static func validationProblems(bytes: Int64) -> [String] {
        if bytes < 0 { return ["The total cannot be negative."] }
        if bytes > Subscription.maximumPlanBytes { return ["Enter a total of 10,000 TB or less."] }
        return []
    }
}

/// The parts of iCloud storage Cloudpane can see, kept apart by how sure each figure is.
public struct ICloudUsage: Sendable, Hashable {
    /// iCloud Drive from the latest complete scan: exact for what the scan saw.
    public let driveBytes: Int64?
    /// The Photos library estimate, when the user chose a library and it was measured.
    public let photos: PhotosLibraryEstimate?
    /// The account total the user entered.
    public let reportedTotal: ReportedUsage?

    public init(driveBytes: Int64?, photos: PhotosLibraryEstimate?, reportedTotal: ReportedUsage?) {
        self.driveBytes = driveBytes
        self.photos = photos
        self.reportedTotal = reportedTotal
    }

    /// The figure the plan math uses: the entered total when there is one, because only it
    /// covers the whole account; otherwise the scanned iCloud Drive. The Photos estimate is
    /// never added in, so an estimate never mixes into a measured figure.
    public var planBytes: Int64? { reportedTotal?.bytes ?? driveBytes }

    /// What the entered total holds beyond iCloud Drive and the Photos estimate: device
    /// backups, Messages, Mail and other apps' data. Nil without a total; never below zero.
    public var otherBytes: Int64? {
        guard let total = reportedTotal?.bytes else { return nil }
        return max(total - (driveBytes ?? 0) - (photos?.logicalBytes ?? 0), 0)
    }
}
