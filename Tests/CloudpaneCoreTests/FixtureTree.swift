import Darwin
import Foundation
@testable import CloudpaneCore

/// A fake home directory with the File Provider layout, built in a fresh temporary
/// directory. Placeholders are simulated with sparse files (logical size set, nothing
/// allocated); sparse files are never ubiquitous and never carry SF_DATALESS.
final class FixtureTree {
    let base: String
    let home: String
    let backup: String
    let outside: String
    private var lockedFolders: [String] = []

    static let iCloud = "Library/Mobile Documents/com~apple~CloudDocs"
    static let cloudStorage = "Library/CloudStorage"
    static let dropbox = cloudStorage + "/Dropbox"
    static let googleDrive = cloudStorage + "/GoogleDrive-test.user@example.com"
    static let oneDrivePersonal = cloudStorage + "/OneDrive-Personal"
    static let oneDriveContoso = cloudStorage + "/OneDrive-Contoso"
    static let box = cloudStorage + "/Box-Box"

    /// An empty home, for building custom layouts.
    init(empty: Bool) throws {
        let created = NSTemporaryDirectory() + "cloudpane-fixture-" + UUID().uuidString
        guard mkdir(created, 0o700) == 0 else { throw POSIXErrorCode() }
        base = canonicalPath(created)
        home = base + "/home"
        backup = base + "/backup"
        outside = base + "/outside"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        if !empty { try buildStandardTree() }
    }

    convenience init() throws { try self.init(empty: false) }

    /// Restores permissions on locked folders, then removes the whole tree.
    func remove() {
        for folder in lockedFolders { chmod(folder, 0o755) }
        try? FileManager.default.removeItem(atPath: base)
    }

    func path(_ relative: String) -> String { home + "/" + relative }

    // MARK: - Builders (paths relative to home unless absolute)

    private func absolute(_ path: String) -> String { path.hasPrefix("/") ? path : home + "/" + path }

    private func makeParent(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
    }

    /// A file with size bytes of non-repeating data, so every block is allocated.
    func real(_ size: Int, _ relative: String) throws {
        let target = absolute(relative)
        try makeParent(target)
        var state: UInt64 = 0x9E3779B97F4A7C15 ^ UInt64(size)
        var bytes = [UInt8](repeating: 0, count: size)
        for index in bytes.indices {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            bytes[index] = UInt8(truncatingIfNeeded: state >> 33)
        }
        guard FileManager.default.createFile(atPath: target, contents: Data(bytes)) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target])
        }
    }

    /// A sparse file: logical size set with ftruncate, no blocks allocated.
    func sparse(_ size: Int64, _ relative: String) throws {
        let target = absolute(relative)
        try makeParent(target)
        let fd = open(target, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        guard fd >= 0 else { throw POSIXErrorCode() }
        defer { close(fd) }
        guard ftruncate(fd, off_t(size)) == 0 else { throw POSIXErrorCode() }
    }

    func hardLink(_ existing: String, _ relative: String) throws {
        guard link(absolute(existing), absolute(relative)) == 0 else { throw POSIXErrorCode() }
    }

    func symlink(to destination: String, at relative: String) throws {
        let target = absolute(relative)
        try makeParent(target)
        guard Darwin.symlink(destination, target) == 0 else { throw POSIXErrorCode() }
    }

    func fifo(_ relative: String) throws {
        let target = absolute(relative)
        try makeParent(target)
        guard mkfifo(target, 0o644) == 0 else { throw POSIXErrorCode() }
    }

    func hide(_ relative: String) throws {
        guard chflags(absolute(relative), UInt32(UF_HIDDEN)) == 0 else { throw POSIXErrorCode() }
    }

    func lock(_ relative: String, mode: mode_t = 0) throws {
        let target = absolute(relative)
        guard chmod(target, mode) == 0 else { throw POSIXErrorCode() }
        lockedFolders.append(target)
    }

    /// Sets a file's modification date, as a backup tool that preserves dates would.
    func setModified(_ relative: String, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: absolute(relative))
    }

    func folder(_ relative: String) throws {
        try FileManager.default.createDirectory(atPath: absolute(relative), withIntermediateDirectories: true)
    }

    // MARK: - The standard tree

    private func buildStandardTree() throws {
        let ic = FixtureTree.iCloud
        try real(1000, "\(ic)/Documents/notes.txt")
        try sparse(2_000_000, "\(ic)/Documents/report.pdf")
        try real(500, "\(ic)/.hidden-config")
        try real(8192, "\(ic)/Archive.photoslibrary/database/Photos.sqlite")
        try real(4096, "\(ic)/Archive.photoslibrary/originals/IMG_0001.heic")
        try real(10, "\(ic)/Archive.photoslibrary/.lock")
        try symlink(to: "database", at: "\(ic)/Archive.photoslibrary/current")
        try real(4096, "Library/Mobile Documents/iCloud~com~example~notes/Documents/a.txt")

        let db = FixtureTree.dropbox
        try real(8192, "\(db)/Photos/beach.jpg")
        try hardLink("\(db)/Photos/beach.jpg", "\(db)/Photos/beach-hardlink.jpg")
        try sparse(3_000_000, "\(db)/Photos/trip/day1.jpg")
        try real(0, "\(db)/empty.txt")
        try fifo("\(db)/pipe.fifo")
        try real(4096, "\(db)/Tool.app/Contents/MacOS/tool")
        try real(200, "\(db)/Tool.app/Contents/Info.plist")
        try real(4096, "\(db)/.dropbox.cache/cached.bin")
        try real(4096, outside + "/big.bin")
        try symlink(to: outside, at: "\(db)/link-to-outside")
        try symlink(to: "Photos/beach.jpg", at: "\(db)/link-to-file")

        let gd = FixtureTree.googleDrive
        try real(12288, "\(gd)/My Drive/Budget.xlsx")
        try sparse(1_500_000, "\(gd)/My Drive/Projects/plan.docx")
        try sparse(10_000_000, "\(gd)/My Drive/Projects/old/archive.zip")
        try real(4096, "\(gd)/Shared drives/Team/spec.pdf")
        try real(100, "\(gd)/Shared drives/Team/flagged.txt")
        try hide("\(gd)/Shared drives/Team/flagged.txt")

        let odp = FixtureTree.oneDrivePersonal
        try real(20000, "\(odp)/Documents/cv.docx")
        try real(10, "\(odp)/Documents/line\nbreak.txt")
        try real(7, "\(odp)/Documents/a,b \"quoted\".txt")
        try sparse(750_000, "\(odp)/Pictures/pic.png")
        try sparse(1000, "\(odp)/Pictures/a|b.png")
        try real(5, "\(odp)/Pictures/=cmd.png")
        try real(3, "\(odp)/Pictures/100%_done.txt")
        try real(3, "\(odp)/Pictures/100xxdone.txt")

        let odc = FixtureTree.oneDriveContoso
        try sparse(5_000_000, "\(odc)/Shared/q3.pptx")
        try real(300, "\(odc)/Shared/readme.md")
        try real(4096, "\(odc)/Shared/locked/secret.txt")
        try lock("\(odc)/Shared/locked")

        let bx = FixtureTree.box
        try real(40960, "\(bx)/Contracts/nda.pdf")
        try sparse(2_500_000, "\(bx)/Contracts/msa.pdf")

        let cs = FixtureTree.cloudStorage
        try real(4096, "\(cs)/ProtonDrive-test/file.bin")
        try real(10, "\(cs)/stray-file.txt")
        try real(10, "\(cs)/.DS_Store")

        try real(1000, backup + "/Documents/notes.txt")
    }
}

/// Runs a full scan of a home into a fresh in-memory inventory.
struct ScanRun {
    let inventory: Inventory
    let snapshotID: Int64
    let report: CatalogReport
    let summary: ScanSummary?
    let issues: [ScanIssue]

    static func run(home: String, backups: [String] = [], inventory: Inventory? = nil) async throws -> ScanRun {
        let report = ProviderCatalog(home: URL(fileURLWithPath: home)).detect()
        let roots = report.scanRoots(backups: backups.map { ScanRoot.backup(URL(fileURLWithPath: $0)) })
        let store = try inventory ?? Inventory(path: ":memory:")
        let collector = EventCollector()
        let id = try await store.recordScan(Scanner(roots: roots), homePath: report.homePath) {
            collector.add($0)
        }
        return ScanRun(inventory: store, snapshotID: id, report: report, summary: collector.summary,
                       issues: collector.issues)
    }
}

final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _issues: [ScanIssue] = []
    private var _summary: ScanSummary?
    private var _progress: [ScanProgress] = []

    func add(_ event: ScanEvent) {
        lock.withLock {
            switch event {
            case .issue(let issue): _issues.append(issue)
            case .finished(let summary): _summary = summary
            case .progress(let progress): _progress.append(progress)
            default: break
            }
        }
    }

    var issues: [ScanIssue] { lock.withLock { _issues } }
    var summary: ScanSummary? { lock.withLock { _summary } }
    var progress: [ScanProgress] { lock.withLock { _progress } }
}
