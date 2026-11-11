import Darwin
import Foundation

/// What the regular files inside a package add up to.
struct PackageContents: Sendable, Hashable {
    var logical: Int64 = 0
    var allocated: Int64 = 0
    var files = 0
    var datalessFiles = 0
    var anyCompressed = false
    var allDataless: Bool { files > 0 && datalessFiles == files }
}

/// Sums the regular files inside a package, hidden ones included, since they are part of
/// what the package occupies. Reads metadata only (lstat and URL resource values); no file
/// is opened. Folders inside are listed under the folder-listing rule (FolderLister), the
/// same as the scan, and every item's metadata is read with materialization off. Symbolic
/// links and other file types inside are ignored, and a hard link the caller has already
/// counted adds nothing. Shared by the scan, which measures packages as leaves, and the
/// Photos library estimate.
enum PackageMeasure {
    static let keys: [URLResourceKey] = [.fileSizeKey, .totalFileAllocatedSizeKey]

    /// Errors are reported through issue as they happen, and the walk goes on; each folder
    /// whose contents could not be seen is also reported through unlisted. Throws only
    /// FolderLister.Failure.couldNotRestore, after which the caller must stop reading.
    static func measure(_ url: URL, lister: FolderLister = .live, isCanceled: () -> Bool,
                        isDuplicateHardLink: (stat) -> Bool,
                        beforeItemRead: (String) -> Void = { _ in },
                        unlisted: (UnlistedCause) -> Void = { _ in },
                        issue: (_ path: String, _ message: String) -> Void) throws -> PackageContents {
        var contents = PackageContents()
        var pending: [URL] = [url]
        while let folder = pending.popLast() {
            if isCanceled() { break }
            var broken: Error?
            autoreleasepool {
                let children: [URL]
                let wasDataless = lister.isDataless(folder.path)
                do {
                    children = try lister.contents(of: folder, includeHidden: true)
                } catch let failure as FolderLister.Failure {
                    if case .couldNotRestore = failure { broken = failure; return }
                    unlisted(UnlistedCause(listingError: failure))
                    issue(folder.path, "list \(failure)")
                    return
                } catch {
                    unlisted(UnlistedCause(listingError: error))
                    issue(folder.path, "list \(describe(error: error))")
                    return
                }
                if wasDataless && lister.isDataless(folder.path) {
                    unlisted(.notProvided)
                    issue(folder.path, "The provider did not provide this folder's list, so files in it are missing from this package's size.")
                }
                for item in children {
                    if isCanceled() { return }
                    autoreleasepool {
                        beforeItemRead(item.path)
                        guard let info = lstatInfo(item.path) else {
                            issue(item.path, "lstat \(describeErrno(POSIXErrorCode()))")
                            return
                        }
                        switch fileType(info) {
                        case S_IFDIR:
                            pending.append(item)
                        case S_IFREG where !isDuplicateHardLink(info):
                            do {
                                let values = try item.resourceValues(forKeys: Set(keys))
                                contents.logical += Int64(values.fileSize ?? 0)
                                contents.allocated += Int64(values.totalFileAllocatedSize ?? 0)
                                contents.files += 1
                                if info.isDataless { contents.datalessFiles += 1 }
                                if info.isCompressed { contents.anyCompressed = true }
                            } catch {
                                issue(item.path, "resource values \(describe(error: error))")
                            }
                        default:
                            break
                        }
                    }
                }
            }
            if let broken { throw broken }
        }
        return contents
    }
}
