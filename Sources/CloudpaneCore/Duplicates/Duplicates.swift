import Foundation

/// How sure a duplicate group is, from the project rules.
public enum DuplicateTier: String, Sendable, Hashable, Codable, CaseIterable, Comparable {
    /// Identical SHA-256: both files were read and hashed.
    case exact
    /// Same size, same name, and modification dates within 2 seconds.
    case strong
    /// Same size only, at least 1 MB.
    case weak

    public var title: String {
        switch self {
        case .exact: return "Exact"
        case .strong: return "Strong"
        case .weak: return "Weak"
        }
    }

    private var rank: Int { self == .exact ? 0 : self == .strong ? 1 : 2 }
    public static func < (lhs: DuplicateTier, rhs: DuplicateTier) -> Bool { lhs.rank < rhs.rank }
}

/// One copy in a group, and where it is.
public struct DuplicateCopy: Sendable, Hashable, Identifiable {
    public let record: FileRecord
    /// The provider's name, or the backup location's label.
    public let locationName: String
    public let isBackup: Bool
    public var id: String { record.path }
}

public struct DuplicateGroup: Sendable, Hashable, Identifiable {
    public let tier: DuplicateTier
    public let size: Int64
    /// Copies in sync clouds, the ones a group is about. At least two.
    public let copies: [DuplicateCopy]
    /// Copies of the same file found in backup locations. Listed, never counted: a backup
    /// copy is the backup doing its job, not waste.
    public let backupCopies: [DuplicateCopy]
    public let id: String

    /// (copies - 1) x size.
    public var reclaimableBytes: Int64 { Int64(copies.count - 1) * size }
    public var placeholderCount: Int { copies.filter(\.record.isPlaceholder).count }
    public var name: String { copies.first?.record.name ?? "" }
}

public struct TierTotal: Sendable, Hashable {
    public let tier: DuplicateTier
    public let groups: Int
    public let files: Int
    public let reclaimableBytes: Int64
}

public struct DuplicateReport: Sendable, Hashable {
    public let snapshotID: Int64
    /// Largest reclaimable first; at most the requested number.
    public let groups: [DuplicateGroup]
    /// Totals over every group, not only the ones listed.
    public let totals: [TierTotal]
    public var totalGroups: Int { totals.reduce(0) { $0 + $1.groups } }
}

/// Tier rules shared by the streaming search in Inventory+Duplicates.
enum DuplicateFinder {
    struct Candidate {
        let rowid: Int64
        let record: FileRecord
        let locationName: String
        var size: Int64 { record.logicalSize ?? 0 }
    }

    static let weakMinimum: Int64 = 1_000_000

    /// Splits same-name, same-size files into groups whose dates all lie within the match
    /// window of the group's earliest file, so any two members are within 2 seconds of each
    /// other. A file with no date matches nothing.
    static func clusters(_ members: [Candidate]) -> [[Candidate]] {
        let dated = members.filter { $0.record.modified != nil }
            .sorted { ($0.record.modified!, $0.record.path) < ($1.record.modified!, $1.record.path) }
        var result: [[Candidate]] = []
        var current: [Candidate] = []
        for candidate in dated {
            if let anchor = current.first?.record.modified,
               candidate.record.modified!.timeIntervalSince(anchor) > Inventory.matchWindow {
                if current.count > 1 { result.append(current) }
                current = []
            }
            current.append(candidate)
        }
        if current.count > 1 { result.append(current) }
        return result
    }

    /// A different SHA-256 proves two files differ. When a group holds more than one hash,
    /// the hashed files are taken out; the rest stay grouped by their weaker evidence.
    static func withoutConflictingHashes(_ members: [Candidate]) -> [Candidate] {
        let hashes = Set(members.compactMap(\.record.sha256))
        guard hashes.count > 1 else { return members }
        return members.filter { $0.record.sha256 == nil }
    }

    static func group(_ tier: DuplicateTier, _ members: [Candidate], id: String) -> DuplicateGroup {
        let copies = members.sorted { $0.record.path < $1.record.path }
            .map { DuplicateCopy(record: $0.record, locationName: $0.locationName, isBackup: false) }
        return DuplicateGroup(tier: tier, size: members[0].size, copies: copies, backupCopies: [], id: id)
    }

    /// Keeps totals for every group and only the largest `limit` groups themselves.
    struct Collector {
        let limit: Int
        var kept: [DuplicateGroup] = []
        var totals: [DuplicateTier: (groups: Int, files: Int, bytes: Int64)] = [:]

        mutating func add(_ group: DuplicateGroup) {
            let current = totals[group.tier] ?? (0, 0, 0)
            totals[group.tier] = (current.groups + 1, current.files + group.copies.count,
                                  current.bytes + group.reclaimableBytes)
            kept.append(group)
            if kept.count >= limit * 2 { trim() }
        }

        mutating func trim() {
            kept.sort(by: DuplicateFinder.ranking)
            if kept.count > limit { kept.removeLast(kept.count - limit) }
        }
    }

    static func ranking(_ a: DuplicateGroup, _ b: DuplicateGroup) -> Bool {
        (a.reclaimableBytes, b.tier, a.size, b.name, b.id) > (b.reclaimableBytes, a.tier, b.size, a.name, a.id)
    }

    static func sameDate(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return false }
        return abs(a.timeIntervalSince(b)) <= Inventory.matchWindow
    }
}
