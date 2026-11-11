import Foundation

/// Decides whether an item is a placeholder (its content is in the cloud, not on the Mac)
/// from its raw facts.
///
/// Kept as one small swappable value because the right rule is not settled: no real
/// provider data has been scanned yet. The rule's id is stored with each snapshot, and the
/// raw facts are stored with each file, so a snapshot can be re-derived under another rule.
public struct PlaceholderRule: Sendable {
    public let id: String
    public let summary: String
    private let test: @Sendable (FileFacts) -> Bool

    public init(id: String, summary: String, _ test: @escaping @Sendable (FileFacts) -> Bool) {
        self.id = id
        self.summary = summary
        self.test = test
    }

    public func isPlaceholder(_ facts: FileFacts) -> Bool { test(facts) }

    /// Provisional default. SF_DATALESS is the kernel's own answer and wins when set.
    /// Otherwise an item is a placeholder only when it has content (logical size > 0),
    /// nothing is allocated, the ubiquity status is not current, and it is not a compressed
    /// file (UF_COMPRESSED files can report 0 allocated with their data on disk).
    public static let datalessOrStrict = PlaceholderRule(
        id: "dataless-or-strict-v1",
        summary: "dataless flag set, or logical > 0 and allocated == 0 and status != current and not compressed"
    ) { facts in
        if facts.isDataless { return true }
        guard let logical = facts.logicalSize, logical > 0 else { return false }
        return (facts.allocatedSize ?? 0) == 0
            && facts.downloadStatus != .current
            && !facts.isCompressed
    }

    public static let `default` = datalessOrStrict
}
