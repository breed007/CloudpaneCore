import Darwin
import XCTest
@testable import CloudpaneCore

final class ProviderCatalogTests: XCTestCase {
    private var tree: FixtureTree!

    override func tearDown() {
        tree?.remove()
        tree = nil
        super.tearDown()
    }

    private func detect(_ home: String, detector: any PartialViewDetector = NoPartialViewDetector()) -> CatalogReport {
        ProviderCatalog(home: URL(fileURLWithPath: home), partialViewDetector: detector).detect()
    }

    private func status(_ report: CatalogReport, _ id: String) -> ProviderStatus {
        report.providers.first { $0.rule.id == id }!
    }

    func testFixtureProvidersAreInstalledWithAccounts() throws {
        tree = try FixtureTree()
        let report = detect(tree.home)

        XCTAssertEqual(report.providers.map(\.rule.id),
                       ["icloud-drive", "dropbox", "google-drive", "onedrive", "box"])
        XCTAssertEqual(report.providers.map(\.state), Array(repeating: .installed, count: 5))

        let oneDrive = status(report, "onedrive")
        XCTAssertEqual(oneDrive.roots.map(\.folderName), ["OneDrive-Contoso", "OneDrive-Personal"])
        XCTAssertEqual(oneDrive.roots.map(\.account), ["Contoso", "Personal"])
        XCTAssertEqual(oneDrive.reason, "Found 2 accounts")
        XCTAssertEqual(status(report, "google-drive").roots.first?.account, "test.user@example.com")
        XCTAssertNil(status(report, "box").roots.first?.account)
        XCTAssertNil(status(report, "dropbox").roots.first?.account)

        // Unrecognized entries come from CloudStorage only; other iCloud containers and
        // hidden names are not listed.
        let unrecognized = Dictionary(uniqueKeysWithValues: report.unrecognized.map { ($0.folderName, $0) })
        XCTAssertEqual(Set(unrecognized.keys), ["ProtonDrive-test", "stray-file.txt"])
        XCTAssertEqual(unrecognized["ProtonDrive-test"]?.state, .installed)
        XCTAssertEqual(unrecognized["stray-file.txt"]?.state, .unavailable)
        XCTAssertEqual(unrecognized["stray-file.txt"]?.reason, "stray-file.txt is not a folder")
    }

    func testEmptyHomeReportsEveryProviderMissing() throws {
        tree = try FixtureTree(empty: true)
        let report = detect(tree.home)
        XCTAssertEqual(report.providers.map(\.state), Array(repeating: .missing, count: 5))
        XCTAssertEqual(status(report, "dropbox").reason,
                       "Not installed: Library does not exist")
        XCTAssertTrue(report.scanRoots().isEmpty)
    }

    func testParentWithoutMatchNamesThePattern() throws {
        tree = try FixtureTree(empty: true)
        try tree.folder(FixtureTree.cloudStorage)
        let report = detect(tree.home)
        XCTAssertEqual(status(report, "onedrive").reason,
                       "Not installed: no OneDrive-* in Library/CloudStorage")
        XCTAssertEqual(status(report, "icloud-drive").reason,
                       "Not installed: Library/Mobile Documents does not exist")
    }

    func testSymlinkedCloudStorageIsNotFollowed() throws {
        tree = try FixtureTree(empty: true)
        try tree.folder(tree.outside + "/CloudStorage/Box-Box")
        try tree.folder("Library")
        try tree.symlink(to: tree.outside + "/CloudStorage", at: FixtureTree.cloudStorage)
        let report = detect(tree.home)
        let box = status(report, "box")
        XCTAssertEqual(box.state, .unavailable)
        XCTAssertEqual(box.reason, "Library/CloudStorage is a symbolic link, not followed")
        XCTAssertTrue(box.roots.isEmpty)
        XCTAssertEqual(status(report, "icloud-drive").state, .missing)
        XCTAssertTrue(report.scanRoots().isEmpty)
    }

    func testUnreadableCloudStorageIsUnavailableNotMissing() throws {
        tree = try FixtureTree(empty: true)
        try tree.folder(FixtureTree.box)
        try tree.lock(FixtureTree.cloudStorage)
        let report = detect(tree.home)
        let dropbox = status(report, "dropbox")
        XCTAssertEqual(dropbox.state, .unavailable)
        XCTAssertTrue(dropbox.reason.contains("Could not read Library/CloudStorage"), dropbox.reason)
        XCTAssertTrue(dropbox.reason.contains("errno 13"), dropbox.reason)
        // Box has an exact folder name, so it is looked up directly; with no search
        // permission on the parent, that lookup fails too.
        let box = status(report, "box")
        XCTAssertEqual(box.state, .unavailable)
        XCTAssertTrue(box.reason.contains("errno 13"), box.reason)
    }

    /// The App Sandbox grants the CloudDocs folder itself, never Library/Mobile Documents,
    /// so the parent can be traversed but not listed. Mode 311 reproduces that locally.
    func testExactNameRootsAreFoundWithoutListingTheirParent() throws {
        tree = try FixtureTree()
        try tree.lock("Library/Mobile Documents", mode: 0o311)
        try tree.lock(FixtureTree.cloudStorage, mode: 0o311)
        let report = detect(tree.home)
        XCTAssertEqual(status(report, "icloud-drive").state, .installed)
        XCTAssertEqual(status(report, "box").state, .installed)
        XCTAssertEqual(status(report, "dropbox").state, .unavailable)
        XCTAssertTrue(report.unrecognized.isEmpty)
        XCTAssertEqual(report.scanRoots().map(\.id), ["icloud-drive/com~apple~CloudDocs", "box/Box-Box"])
    }

    func testExactNameRootMissingUnderAnExistingParent() throws {
        tree = try FixtureTree(empty: true)
        try tree.folder("Library/Mobile Documents")
        let iCloud = status(detect(tree.home), "icloud-drive")
        XCTAssertEqual(iCloud.state, .missing)
        XCTAssertEqual(iCloud.reason, "Not installed: no com~apple~CloudDocs in Library/Mobile Documents")
    }

    func testRootThatIsASymlinkOrFileIsUnavailable() throws {
        tree = try FixtureTree(empty: true)
        try tree.folder(tree.outside + "/real-box")
        try tree.symlink(to: tree.outside + "/real-box", at: FixtureTree.box)
        try tree.real(10, FixtureTree.cloudStorage + "/Dropbox")
        let report = detect(tree.home)
        XCTAssertEqual(status(report, "box").state, .unavailable)
        XCTAssertEqual(status(report, "box").reason, "Box-Box: Box-Box is a symbolic link, not followed")
        XCTAssertEqual(status(report, "dropbox").state, .unavailable)
        XCTAssertEqual(status(report, "dropbox").reason, "Dropbox: Dropbox is not a folder")
        XCTAssertTrue(report.scanRoots(includeUnrecognized: false).isEmpty)
    }

    func testOneBrokenAccountDoesNotHideAWorkingOne() async throws {
        tree = try FixtureTree()
        try tree.lock(FixtureTree.oneDriveContoso)
        let report = detect(tree.home)
        let oneDrive = status(report, "onedrive")
        XCTAssertEqual(oneDrive.state, .partial)
        XCTAssertTrue(oneDrive.reason.hasPrefix("Scanning 1 of 2 accounts. OneDrive-Contoso: Could not read"),
                      oneDrive.reason)
        XCTAssertEqual(oneDrive.roots.map(\.state), [.unavailable, .installed])
        XCTAssertEqual(report.scanRoots().filter { $0.provider == "onedrive" }.map(\.name), ["OneDrive-Personal"])
    }

    func testBackupRootsInsideSyncedFoldersAreRefusedWithAReason() throws {
        tree = try FixtureTree()
        let report = detect(tree.home)
        func reason(_ path: String) -> String? {
            report.backupRejectionReason(for: .backup(URL(fileURLWithPath: path)))
        }
        XCTAssertEqual(reason(tree.path(FixtureTree.dropbox + "/Photos")),
                       "Photos is inside the Dropbox folder Dropbox, which syncs to the cloud. "
                       + "Sync is not backup, so it is not scanned as a backup.")
        XCTAssertEqual(reason(tree.path(FixtureTree.box)),
                       "Box-Box is the Box folder Box-Box, which syncs to the cloud. "
                       + "Sync is not backup, so it is not scanned as a backup.")
        XCTAssertEqual(reason(tree.path(FixtureTree.cloudStorage + "/ProtonDrive-test")),
                       "ProtonDrive-test is the folder ProtonDrive-test in Library/CloudStorage, "
                       + "which syncs to the cloud. Sync is not backup, so it is not scanned as a backup.")
        let container = tree.path("Library/Mobile Documents/iCloud~com~example~notes")
        XCTAssertEqual(reason(container),
                       "iCloud~com~example~notes is inside Library/Mobile Documents, where cloud providers "
                       + "keep synced folders. Sync is not backup, so it is not scanned as a backup.")
        // Case and normalization differences do not get around the check.
        XCTAssertNotNil(reason(tree.path(FixtureTree.dropbox + "/Photos").uppercased()))
        // A symbolic link to a synced folder resolves to it.
        try tree.symlink(to: tree.path(FixtureTree.dropbox), at: tree.outside + "/dropbox-link")
        XCTAssertNotNil(reason(tree.outside + "/dropbox-link"))

        XCTAssertNil(reason(tree.backup))
        XCTAssertNil(reason(tree.path("Library")), "a folder that contains synced roots is fine")
        XCTAssertFalse(report.scanRoots(backups: [.backup(URL(fileURLWithPath: tree.path(FixtureTree.dropbox + "/Photos")))])
            .contains { $0.kind == .backup })
    }

    func testUnreadableRootIsUnavailable() throws {
        tree = try FixtureTree(empty: true)
        try tree.folder(FixtureTree.box)
        try tree.lock(FixtureTree.box)
        let box = status(detect(tree.home), "box")
        XCTAssertEqual(box.state, .unavailable)
        XCTAssertTrue(box.reason.contains("errno 13"), box.reason)
    }

    func testPartialViewHookMarksRootPartialAndItIsStillScanned() throws {
        struct Detector: PartialViewDetector {
            func partialViewReason(rule: ProviderRule, rootPath: String) -> String? {
                guard rule.id == "onedrive", rootPath.hasSuffix("Personal") else { return nil }
                return "Some folders are hidden by \(rule.partialViewSetting ?? "a setting")"
            }
        }
        tree = try FixtureTree()
        let report = detect(tree.home, detector: Detector())
        let oneDrive = status(report, "onedrive")
        XCTAssertEqual(oneDrive.state, .partial)
        XCTAssertEqual(oneDrive.reason, "OneDrive-Personal: Some folders are hidden by Choose folders")
        XCTAssertEqual(oneDrive.roots.map(\.state), [.installed, .partial])
        XCTAssertTrue(report.scanRoots().contains { $0.id == "onedrive/OneDrive-Personal" })
    }

    func testScanRootsOrderAndBackupDeduplication() throws {
        tree = try FixtureTree()
        let report = detect(tree.home)
        let backup = ScanRoot.backup(URL(fileURLWithPath: tree.backup), label: "Archive disk")
        let duplicateOfProvider = ScanRoot.backup(URL(fileURLWithPath: tree.path(FixtureTree.box)))
        let roots = report.scanRoots(backups: [backup, backup, duplicateOfProvider])
        XCTAssertEqual(roots.map(\.id), [
            "icloud-drive/com~apple~CloudDocs", "dropbox/Dropbox",
            "google-drive/GoogleDrive-test.user@example.com",
            "onedrive/OneDrive-Contoso", "onedrive/OneDrive-Personal", "box/Box-Box",
            "unrecognized/ProtonDrive-test", "backup/\(tree.backup)",
        ])
        XCTAssertEqual(roots.last?.name, "Archive disk")
        XCTAssertEqual(roots.first { $0.provider == "google-drive" }?.topLevelDepth, 2)
        XCTAssertFalse(report.scanRoots(includeUnrecognized: false).contains { $0.kind == .unrecognized })
    }

    func testProviderTableIsData() {
        // A provider added or renamed in the table is detected with no code change.
        let rule = ProviderRule(id: "example", displayName: "Example", parent: "Library/CloudStorage",
                                match: .prefix("Example-"), suffixIsAccount: true)
        XCTAssertEqual(rule.account(forFolderName: "Example-Work"), "Work")
        XCTAssertNil(rule.account(forFolderName: "Other"))
        XCTAssertEqual(ProviderRule.dropbox.account(forFolderName: "Dropbox-Team Space"), "Team Space")
        XCTAssertEqual(rule.match.pattern, "Example-*")
    }

    func testUserHomeIsTheRealHome() {
        XCTAssertEqual(ProviderCatalog.userHome.path, NSHomeDirectory())
    }
}
