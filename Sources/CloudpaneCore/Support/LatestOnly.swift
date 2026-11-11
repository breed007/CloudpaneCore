import Foundation

/// Runs one piece of work at a time and keeps only the newest result. Starting a run cancels
/// the one before it, and a run that finishes after a newer one started returns nil instead
/// of its stale value. The app uses it so two quick plan saves end with the newer grade.
public actor LatestOnly<Value: Sendable> {
    private var generation = 0
    private var current: Task<Value, Error>?

    public init() {}

    /// The work's value, or nil when a newer run started meanwhile or this one was canceled.
    public func run(_ work: @escaping @Sendable () async throws -> Value) async throws -> Value? {
        generation += 1
        let mine = generation
        current?.cancel()
        let task = Task { try await work() }
        current = task
        do {
            let value = try await task.value
            return mine == generation ? value : nil
        } catch is CancellationError {
            return nil
        } catch {
            // An error from a superseded run is as stale as its value would have been.
            if mine != generation { return nil }
            throw error
        }
    }

    /// Cancels the run in progress, if any.
    public func cancel() {
        generation += 1
        current?.cancel()
        current = nil
    }
}
