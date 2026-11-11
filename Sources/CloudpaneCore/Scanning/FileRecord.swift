import Foundation
import UniformTypeIdentifiers

/// The ubiquity download status from URLResourceValues, or none for an item that is not
/// ubiquitous.
public enum DownloadStatus: String, Sendable, Hashable, Codable {
    case current
    case downloaded
    case notDownloaded
    case none

    init(_ status: URLUbiquitousItemDownloadingStatus?) {
        switch status {
        case .some(.current): self = .current
        case .some(.downloaded): self = .downloaded
        case .some(.notDownloaded): self = .notDownloaded
        default: self = .none
        }
    }
}

/// The raw facts the placeholder rule reads. Stored as found, so a different rule can be
/// applied later without rescanning.
public struct FileFacts: Sendable, Hashable {
    /// fileSizeKey. Nil when the system reports no size.
    public var logicalSize: Int64?
    /// totalFileAllocatedSizeKey. Nil when the system reports none.
    public var allocatedSize: Int64?
    public var isUbiquitous: Bool
    public var downloadStatus: DownloadStatus
    /// SF_DATALESS from lstat(2).
    public var isDataless: Bool
    /// UF_COMPRESSED from lstat(2).
    public var isCompressed: Bool

    public init(logicalSize: Int64?, allocatedSize: Int64?, isUbiquitous: Bool = false,
                downloadStatus: DownloadStatus = .none, isDataless: Bool = false,
                isCompressed: Bool = false) {
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.isUbiquitous = isUbiquitous
        self.downloadStatus = downloadStatus
        self.isDataless = isDataless
        self.isCompressed = isCompressed
    }
}

/// A coarse file kind for the type breakdown, derived from the content type.
public enum FileCategory: String, Sendable, Hashable, Codable, CaseIterable {
    case application
    case image
    case video
    case audio
    case archive
    case code
    case document
    case other

    public init(contentType: UTType?) {
        guard let type = contentType else { self = .other; return }
        // Order matters: source code conforms to text, and an app bundle is a package.
        let checks: [(UTType, FileCategory)] = [
            (.application, .application), (.image, .image), (.movie, .video),
            (.audio, .audio), (.archive, .archive), (.sourceCode, .code),
            (.pdf, .document), (.presentation, .document), (.spreadsheet, .document),
            (.compositeContent, .document), (.text, .document),
        ]
        self = checks.first { type.conforms(to: $0.0) }?.1 ?? .other
    }

    /// System types replaced before recording. The system registers ".bin" as a MacBinary
    /// archive, but files with that extension are nearly always raw data (firmware, disk
    /// images, game assets), and counting them as archives would skew the breakdown.
    static let contentTypeOverrides: [String: UTType] = [
        "com.apple.macbinary-archive": .data,
    ]

    /// The content type to record for a type the system reported.
    public static func effectiveType(_ type: UTType?) -> UTType? {
        guard let type else { return nil }
        return contentTypeOverrides[type.identifier] ?? type
    }
}

/// One item in a snapshot: a regular file, or a package counted as a single leaf.
public struct FileRecord: Sendable, Hashable, Codable, Identifiable {
    public let snapshotID: Int64
    /// Absolute path.
    public let path: String
    public let rootID: String
    /// Provider rule id, or "backup" or "unrecognized".
    public let provider: String
    /// Path below the root.
    public let relativePath: String
    public let name: String
    /// The top-level folder this item counts toward, such as "Documents" or
    /// "My Drive/Projects". Empty for an item directly in the root.
    public let topLevelFolder: String
    /// For a package, the sum over the regular files inside it.
    public let logicalSize: Int64?
    /// For a package, the sum over the regular files inside it.
    public let allocatedSize: Int64?
    public let modified: Date?
    public let isUbiquitous: Bool
    public let downloadStatus: DownloadStatus
    public let isDataless: Bool
    public let isCompressed: Bool
    public let isPackage: Bool
    /// Derived by the snapshot's PlaceholderRule from the facts above.
    public let isPlaceholder: Bool
    /// UTType identifier, when the system reports one.
    public let contentType: String?
    public let category: FileCategory
    /// SHA-256, only when hashing was opted in for the file's folder.
    public let sha256: String?
    /// The file's inode at scan time. A stored hash is reused only while size, date and
    /// inode are all unchanged.
    public let inode: UInt64?
    /// The inode change time (st_ctime, with nanoseconds). Only the system sets it, so an
    /// edit that keeps the size and restores the modification date still changes it.
    public let statusChanged: Date?

    public init(snapshotID: Int64, path: String, rootID: String, provider: String,
                relativePath: String, name: String, topLevelFolder: String, facts: FileFacts,
                modified: Date?, isPackage: Bool, isPlaceholder: Bool, contentType: String?,
                category: FileCategory, sha256: String? = nil, inode: UInt64? = nil,
                statusChanged: Date? = nil) {
        self.snapshotID = snapshotID
        self.path = path
        self.rootID = rootID
        self.provider = provider
        self.relativePath = relativePath
        self.name = name
        self.topLevelFolder = topLevelFolder
        self.logicalSize = facts.logicalSize
        self.allocatedSize = facts.allocatedSize
        self.modified = modified
        self.isUbiquitous = facts.isUbiquitous
        self.downloadStatus = facts.downloadStatus
        self.isDataless = facts.isDataless
        self.isCompressed = facts.isCompressed
        self.isPackage = isPackage
        self.isPlaceholder = isPlaceholder
        self.contentType = contentType
        self.category = category
        self.sha256 = sha256
        self.inode = inode
        self.statusChanged = statusChanged
    }

    /// The path, unique within a snapshot.
    public var id: String { path }

    public var facts: FileFacts {
        FileFacts(logicalSize: logicalSize, allocatedSize: allocatedSize, isUbiquitous: isUbiquitous,
                  downloadStatus: downloadStatus, isDataless: isDataless, isCompressed: isCompressed)
    }

    /// The top-level folder for a path below a root, at the given depth. An item at or above
    /// that depth counts toward its parent folder, or "" when it sits in the root itself.
    static func topLevelFolder(relativePath: String, depth: Int) -> String {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        let folders = parts.dropLast()
        return folders.prefix(depth).joined(separator: "/")
    }
}
