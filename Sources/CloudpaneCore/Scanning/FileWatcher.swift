import CoreServices
import Foundation

/// What the watcher reports after coalescing.
public enum WatchEvent: Sendable, Equatable {
    /// Paths of files and folders that changed, for an incremental snapshot.
    case changed(Set<String>)
    /// Events were lost or the system asked for a full rescan; the reason is a sentence.
    case rescanNeeded(String)
}

/// Watches folders with FSEvents (CoreServices, a system framework with no user interface,
/// so it belongs in Core and runs under swift test) and reports coalesced batches.
///
/// File-level events are collected until the tree has been quiet for `quietPeriod`, or
/// `maximumDelay` has passed since the first pending change, then reported as one batch.
/// MustScanSubDirs, dropped events, a wrapped event ID and a moved or removed watched folder
/// are reported at once as rescanNeeded. All state lives on one serial queue.
///
/// Under the App Sandbox, start the watcher only while the folders' security-scoped access
/// is active, and stop it before that access ends.
public final class FileWatcher: @unchecked Sendable {
    public let paths: [String]
    public let latency: TimeInterval
    public let quietPeriod: TimeInterval
    public let maximumDelay: TimeInterval
    /// Account roots the user excluded from scans. Events at or inside one are dropped.
    public let excluded: ScanChoices

    private let queue = DispatchQueue(label: "CloudpaneCore.FileWatcher", qos: .utility)
    private var stream: FSEventStreamRef?
    private var continuation: AsyncStream<WatchEvent>.Continuation?
    private var pending: Set<String> = []
    private var firstPending: Date?
    private var flushWork: DispatchWorkItem?

    public init(paths: [String], latency: TimeInterval = 0.5, quietPeriod: TimeInterval = 2,
                maximumDelay: TimeInterval = 20, excluding: Set<String> = []) {
        self.paths = paths
        self.excluded = ScanChoices(excludedRoots: excluding)
        self.latency = latency
        self.quietPeriod = quietPeriod
        self.maximumDelay = maximumDelay
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    /// Starts watching and returns the batches. Calling start again restarts the watch.
    public func start() -> AsyncStream<WatchEvent> {
        let (events, continuation) = AsyncStream.makeStream(of: WatchEvent.self, bufferingPolicy: .unbounded)
        queue.sync {
            stopOnQueue()
            self.continuation = continuation
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer)
            guard let created = FSEventStreamCreate(
                kCFAllocatorDefault, FileWatcher.callback, &context, paths as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
                continuation.yield(.rescanNeeded("The folders could not be watched for changes."))
                return
            }
            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else {
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
                continuation.yield(.rescanNeeded("The folders could not be watched for changes."))
                return
            }
            stream = created
        }
        continuation.onTermination = { [weak self] _ in self?.stop() }
        return events
    }

    /// Stops watching and ends the stream. Pending changes are reported first.
    public func stop() {
        queue.async { [self] in
            flushOnQueue()
            stopOnQueue()
            continuation?.finish()
            continuation = nil
        }
    }

    private func stopOnQueue() {
        flushWork?.cancel()
        flushWork = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
        let array = unsafeBitCast(paths, to: NSArray.self)
        var events: [(String, FSEventStreamEventFlags)] = []
        for index in 0..<count {
            if let path = array[index] as? String { events.append((path, flags[index])) }
        }
        watcher.handle(events)
    }

    /// Turns raw events into pending changes or an immediate rescan. Runs on the queue.
    func handle(_ allEvents: [(path: String, flags: FSEventStreamEventFlags)]) {
        dispatchPrecondition(condition: .onQueue(queue))
        // Nothing inside an excluded account counts, not even an event that would ask for a
        // full rescan.
        let events = allEvents.filter { !excluded.isExcluded($0.path) }
        guard !events.isEmpty else { return }
        if let reason = FileWatcher.rescanReason(events) {
            pending.removeAll()
            firstPending = nil
            flushWork?.cancel()
            continuation?.yield(.rescanNeeded(reason))
            return
        }
        guard !events.isEmpty else { return }
        for event in events where event.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) == 0 {
            pending.insert(event.path)
        }
        guard !pending.isEmpty else { return }
        let now = Date()
        if firstPending == nil { firstPending = now }
        flushWork?.cancel()
        let waited = now.timeIntervalSince(firstPending ?? now)
        let delay = max(0, min(quietPeriod, maximumDelay - waited))
        let work = DispatchWorkItem { [weak self] in self?.flushOnQueue() }
        flushWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// For tests: feed events as if FSEvents delivered them.
    func inject(_ events: [(path: String, flags: FSEventStreamEventFlags)]) {
        queue.async { self.handle(events) }
    }

    private func flushOnQueue() {
        guard !pending.isEmpty else { return }
        continuation?.yield(.changed(pending))
        pending.removeAll()
        firstPending = nil
        flushWork = nil
    }

    static func rescanReason(_ events: [(path: String, flags: FSEventStreamEventFlags)]) -> String? {
        func has(_ flag: Int) -> Bool { events.contains { $0.flags & FSEventStreamEventFlags(flag) != 0 } }
        if has(kFSEventStreamEventFlagUserDropped) || has(kFSEventStreamEventFlagKernelDropped) {
            return "Some file system changes were not delivered, so Cloudpane is scanning everything again."
        }
        if has(kFSEventStreamEventFlagEventIdsWrapped) {
            return "The file system change history wrapped around, so Cloudpane is scanning everything again."
        }
        if has(kFSEventStreamEventFlagRootChanged) {
            return "A watched folder was moved or removed, so Cloudpane is scanning everything again."
        }
        if has(kFSEventStreamEventFlagMustScanSubDirs) {
            return "macOS asked for a full rescan of a folder, so Cloudpane is scanning everything again."
        }
        return nil
    }
}
