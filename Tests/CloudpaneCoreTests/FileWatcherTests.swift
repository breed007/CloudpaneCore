import CoreServices
import XCTest
@testable import CloudpaneCore

final class FileWatcherTests: XCTestCase {
    private var tree: FixtureTree!

    override func setUpWithError() throws {
        tree = try FixtureTree(empty: true)
        try tree.folder(FixtureTree.dropbox + "/Docs")
    }

    override func tearDown() {
        tree?.remove()
        tree = nil
        super.tearDown()
    }

    /// The first event after a timeout, or nil.
    private func next(_ events: AsyncStream<WatchEvent>, within seconds: Double) async -> WatchEvent? {
        await withTaskGroup(of: WatchEvent?.self) { group in
            group.addTask {
                for await event in events { return event }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Acceptance target: a file added under a provider root is picked up within a minute.
    func testAFileAddedUnderAProviderRootIsPickedUpWithinSeconds() async throws {
        let root = tree.path(FixtureTree.dropbox)
        let watcher = FileWatcher(paths: [root], latency: 0.2, quietPeriod: 0.5)
        let events = watcher.start()
        try await Task.sleep(for: .milliseconds(300))
        let clock = ContinuousClock()
        let start = clock.now
        try tree.real(100, FixtureTree.dropbox + "/Docs/new.txt")
        let event = await next(events, within: 60)
        let elapsed = clock.now - start
        watcher.stop()
        guard case .changed(let paths) = event else { return XCTFail("no change reported: \(String(describing: event))") }
        XCTAssertTrue(paths.contains(root + "/Docs/new.txt"), "\(paths)")
        XCTAssertLessThan(elapsed, .seconds(5), "picked up after \(elapsed)")
    }

    func testABurstOfChangesArrivesAsOneBatch() async throws {
        let root = tree.path(FixtureTree.dropbox)
        let watcher = FileWatcher(paths: [root], latency: 0.1, quietPeriod: 1.0)
        let events = watcher.start()
        try await Task.sleep(for: .milliseconds(300))
        for index in 0..<50 { try tree.real(10, FixtureTree.dropbox + "/Docs/f\(index).txt") }
        guard case .changed(let paths) = await next(events, within: 30) else { return XCTFail("no batch") }
        watcher.stop()
        let created = Set((0..<50).map { root + "/Docs/f\($0).txt" })
        XCTAssertTrue(created.isSubset(of: paths), "all 50 files in the first batch, not one batch per file")
    }

    func testFlagsThatLoseEventsAskForAFullRescan() async throws {
        let cases: [(Int, String)] = [
            (kFSEventStreamEventFlagMustScanSubDirs, "macOS asked for a full rescan of a folder"),
            (kFSEventStreamEventFlagUserDropped, "were not delivered"),
            (kFSEventStreamEventFlagKernelDropped, "were not delivered"),
            (kFSEventStreamEventFlagEventIdsWrapped, "wrapped around"),
            (kFSEventStreamEventFlagRootChanged, "moved or removed"),
        ]
        for (flag, phrase) in cases {
            let watcher = FileWatcher(paths: [tree.path(FixtureTree.dropbox)], quietPeriod: 5)
            let events = watcher.start()
            watcher.inject([("/a/pending.txt", FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated))])
            watcher.inject([("/a", FSEventStreamEventFlags(flag))])
            let event = await next(events, within: 2)
            watcher.stop()
            guard case .rescanNeeded(let reason) = event else { return XCTFail("flag \(flag): \(String(describing: event))") }
            XCTAssertTrue(reason.contains(phrase), reason)
        }
    }

    func testPendingChangesFlushByTheMaximumDelayEvenWhileBusy() async throws {
        let watcher = FileWatcher(paths: [tree.path(FixtureTree.dropbox)], quietPeriod: 10, maximumDelay: 0.5)
        let events = watcher.start()
        watcher.inject([("/a/one.txt", FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified))])
        let event = await next(events, within: 3)
        watcher.stop()
        // Real events for the fixture's own folders may arrive in the same batch.
        guard case .changed(let paths) = event else { return XCTFail("no batch: \(String(describing: event))") }
        XCTAssertTrue(paths.contains("/a/one.txt"))
    }
}
