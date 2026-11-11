import Foundation

public enum GradeLetter: String, Sendable, Hashable, Codable, CaseIterable, Comparable {
    case A, B, C, D, F

    /// A = 4 down to F = 0, for the roll-up average.
    public var score: Int {
        switch self {
        case .A: return 4
        case .B: return 3
        case .C: return 2
        case .D: return 1
        case .F: return 0
        }
    }

    init(score: Int) {
        self = GradeLetter.allCases.first { $0.score == min(max(score, 0), 4) } ?? .F
    }

    public static func < (lhs: GradeLetter, rhs: GradeLetter) -> Bool { lhs.score < rhs.score }
}

public enum CheckStatus: String, Sendable, Hashable, Codable {
    case pass
    case fail
    /// Not known yet, such as an unconfirmed version history. Never counted as a pass.
    case unknown
}

public enum GradeCheckKind: String, Sendable, Hashable, Codable, CaseIterable {
    case copies
    case media
    case offsite
    case versioned
    case singlePoint

    public var title: String {
        switch self {
        case .copies: return "Three copies"
        case .media: return "Two kinds of storage"
        case .offsite: return "One copy off-site"
        case .versioned: return "Version history"
        case .singlePoint: return "More than one place"
        }
    }
}

public struct GradeCheck: Sendable, Hashable, Codable {
    public let kind: GradeCheckKind
    public let status: CheckStatus
    /// One sentence saying why.
    public let reason: String
}

/// A place that holds a folder's content.
public struct CopyLocation: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        /// The provider's own cloud.
        case cloud
        /// Downloaded on this Mac: in the provider's sync folder or as an identical
        /// downloaded file in another sync folder.
        case localSync
        /// A backup location the user added.
        case backup
    }

    public let kind: Kind
    public let rootID: String?
    public let name: String
    public let backupKind: BackupKind?
    public let isOffsite: Bool
    /// Share of the folder found here, 0 to 1, by bytes (by file count for an all-empty folder).
    public let coverage: Double
}

public struct FolderGrade: Sendable, Hashable, Identifiable {
    public let provider: String
    public let providerName: String
    public let rootID: String
    public let account: String
    /// Empty for files directly in the root.
    public let folder: String
    public let files: Int
    public let bytes: Int64
    public let letter: GradeLetter
    /// Why this letter, in one sentence.
    public let summary: String
    public let checks: [GradeCheck]
    /// Every location counted as a copy (coverage at or above the threshold).
    public let copies: [CopyLocation]
    /// Locations holding some of it, but not enough to count.
    public let partial: [CopyLocation]
    /// What would raise the letter. Never another cloud.
    public let fix: String?

    public var id: String { "\(rootID)/\(folder)" }
}

/// One letter for a set of folders, with the arithmetic behind it.
public struct GradeRollup: Sendable, Hashable {
    public let letter: GradeLetter
    /// The byte-weighted average score, 0 to 4.
    public let averageScore: Double
    public let folders: Int
    public let bytes: Int64
    /// Folders and bytes per letter.
    public let distribution: [GradeLetter: (folders: Int, bytes: Int64)]
    public let explanation: String

    /// Byte-weighted average of the letters (A = 4 ... F = 0), rounded down, so a large
    /// weak folder pulls the letter down more than a small one. When every folder is empty,
    /// each folder weighs the same.
    static func make(_ grades: [FolderGrade]) -> GradeRollup? {
        guard !grades.isEmpty else { return nil }
        let totalBytes = grades.reduce(Int64(0)) { $0 + $1.bytes }
        let weight: (FolderGrade) -> Double = totalBytes > 0 ? { Double($0.bytes) } : { _ in 1 }
        let totalWeight = grades.reduce(0.0) { $0 + weight($1) }
        let average = grades.reduce(0.0) { $0 + weight($1) * Double($1.letter.score) } / totalWeight
        // Guard against 2.9999999 from floating point when every folder has the same letter.
        let letter = GradeLetter(score: Int((average + 1e-9).rounded(.down)))
        var distribution: [GradeLetter: (folders: Int, bytes: Int64)] = [:]
        for grade in grades {
            let current = distribution[grade.letter] ?? (0, 0)
            distribution[grade.letter] = (current.folders + 1, current.bytes + grade.bytes)
        }
        let basis = totalBytes > 0 ? "byte-weighted average" : "average"
        let count = grades.count == 1 ? "1 folder" : "\(grades.count) folders"
        let explanation = "The \(basis) of \(count) is \(String(format: "%.1f", average)) out of 4, "
            + "which rounds down to \(letter.rawValue)."
        return GradeRollup(letter: letter, averageScore: average, folders: grades.count, bytes: totalBytes,
                           distribution: distribution, explanation: explanation)
    }

    public static func == (lhs: GradeRollup, rhs: GradeRollup) -> Bool {
        lhs.letter == rhs.letter && lhs.averageScore == rhs.averageScore && lhs.folders == rhs.folders
            && lhs.bytes == rhs.bytes && lhs.explanation == rhs.explanation
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(letter)
        hasher.combine(folders)
        hasher.combine(bytes)
    }
}

/// A file that exists in exactly one place: a placeholder whose content is only in its
/// provider's cloud, with no match on this Mac, in another cloud, or in a backup.
public struct SinglePointList: Sendable, Hashable {
    public let files: [FileRecord]
    public let totalFiles: Int
    public let totalBytes: Int64
}

public struct GradeReport: Sendable, Hashable {
    public let snapshotID: Int64
    public let folders: [FolderGrade]
    public let overall: GradeRollup?
    public let byProvider: [String: GradeRollup]
    public let singlePoint: SinglePointList
    /// Backup roots in the graded scan, so the view can say when there were none.
    public let backupRoots: [ScanRoot]
}

// MARK: - Grading one folder

/// The facts gathered for one top-level folder. Only non-empty files are counted.
struct FolderEvidence: Sendable {
    let rootID: String
    let provider: String
    let providerName: String
    let account: String
    let folder: String
    let files: Int
    let bytes: Int64
    /// Files downloaded here, or with an identical downloaded file elsewhere on this Mac.
    let localFiles: Int
    let localBytes: Int64
    /// Per backup root: files and bytes of this folder it holds.
    let backups: [String: (files: Int, bytes: Int64)]
    /// Per backup root: files that match there by name and size but not by date. Never a
    /// copy; it explains a backup made by a tool that reset modification dates.
    var dateMismatches: [String: (files: Int, bytes: Int64)] = [:]
}

enum Grader {
    /// A location counts as a copy when it holds at least this share of the folder.
    static let coverageThreshold = 0.9
    /// Share of a folder matching a backup by name and size only that earns an explanation.
    static let dateMismatchNotice = 0.5

    static func coverage(_ files: Int, _ bytes: Int64, of evidence: FolderEvidence) -> Double {
        if evidence.bytes > 0 { return Double(bytes) / Double(evidence.bytes) }
        return evidence.files > 0 ? Double(files) / Double(evidence.files) : 0
    }

    /// The versioned check, from data. A claim always cites the retention it rests on.
    static func versionCheck(provider: String, name: String, facts: ProviderFacts,
                             paidPlans: Set<String>) -> GradeCheck {
        guard let fact = facts.fact(for: provider) else {
            return GradeCheck(kind: .versioned, status: .unknown,
                              reason: "Cloudpane has no information on whether \(name) keeps file history.")
        }
        let retention = fact.retention.map { " \($0)" } ?? ""
        switch fact.versioning {
        case .keepsHistory where fact.requiresPaidPlan == true && !paidPlans.contains(provider):
            return GradeCheck(kind: .versioned, status: .fail,
                              reason: "\(name) keeps file history only on paid plans, and no active paid \(name) plan is entered in Providers.\(retention)")
        case .keepsHistory:
            return GradeCheck(kind: .versioned, status: .pass, reason: "\(name) keeps file history.\(retention)")
        case .noHistory:
            return GradeCheck(kind: .versioned, status: .fail, reason: "\(name) keeps no file history.\(retention)")
        case .toVerify:
            return GradeCheck(kind: .versioned, status: .unknown,
                              reason: "Cloudpane has not yet confirmed that \(name) keeps file history.")
        }
    }

    static func grade(_ evidence: FolderEvidence, roots: [String: ScanRoot], facts: ProviderFacts,
                      paidPlans: Set<String> = []) -> FolderGrade {
        let name = evidence.providerName
        // The provider's cloud is the one sync cloud that counts. Another cloud holding the
        // same files never adds a copy: sync is not backup.
        var copies = [CopyLocation(kind: .cloud, rootID: evidence.rootID, name: name, backupKind: nil,
                                   isOffsite: true, coverage: 1)]
        var partial: [CopyLocation] = []

        let local = coverage(evidence.localFiles, evidence.localBytes, of: evidence)
        let localCopy = CopyLocation(kind: .localSync, rootID: evidence.rootID, name: "This Mac", backupKind: nil,
                                     isOffsite: false, coverage: local)
        if local >= coverageThreshold { copies.append(localCopy) } else if local > 0 { partial.append(localCopy) }

        var anyBackupContent = false
        for (rootID, match) in evidence.backups.sorted(by: { $0.key < $1.key }) {
            guard let root = roots[rootID] else { continue }
            let share = coverage(match.files, match.bytes, of: evidence)
            guard share > 0 else { continue }
            anyBackupContent = true
            let location = CopyLocation(kind: .backup, rootID: rootID, name: root.name, backupKind: root.backupKind,
                                        isOffsite: root.isOffsite, coverage: share)
            if share >= coverageThreshold { copies.append(location) } else { partial.append(location) }
        }
        let backups = copies.filter { $0.kind == .backup }

        let copiesCheck = GradeCheck(
            kind: .copies, status: copies.count >= 3 ? .pass : .fail,
            reason: copies.count >= 3
                ? "Held in \(copies.count) places: \(copies.map(\.name).joined(separator: ", "))."
                : "Held in \(copies.count == 1 ? "1 place" : "\(copies.count) places"): "
                    + copies.map(\.name).joined(separator: ", ") + ". Three are needed.")

        // Media: a copy that is not a sync folder. The downloaded copy on this Mac does not
        // count: deleting the file in the cloud deletes it there too.
        let mediaCheck = backups.first.map {
            GradeCheck(kind: .media, status: .pass, reason: "\($0.name) is a backup, not a sync folder.")
        } ?? GradeCheck(kind: .media, status: .fail,
                        reason: "Every copy is synced, so a deletion in the cloud reaches all of them.")

        // Off-site: off the Mac and outside the home. The provider's cloud is.
        let offsiteBackup = backups.first(where: \.isOffsite)
        let offsiteCheck = GradeCheck(
            kind: .offsite, status: .pass,
            reason: offsiteBackup.map { "\($0.name) is kept off-site, and \(name) stores a copy off the Mac." }
                ?? "\(name) stores a copy off the Mac and outside the home.")

        let version = versionCheck(provider: evidence.provider, name: name, facts: facts, paidPlans: paidPlans)

        let singleCheck = GradeCheck(
            kind: .singlePoint, status: copies.count > 1 ? .pass : .fail,
            reason: copies.count > 1 ? "Not only in one place."
                : "Only in \(name)'s cloud. Nothing here is downloaded on this Mac or held by a backup.")

        let checks = [copiesCheck, mediaCheck, offsiteCheck, version, singleCheck]

        // Letter, in this order (provisional; see DECISIONS.md):
        // F: no file downloaded anywhere on this Mac and no backup holds any of it.
        // A or B: a backup holds it. A with all four of copies, media, off-site and versioned;
        //   B with one missing; C with more missing, since a real backup still exists.
        // C: no backup, provider versioned. D: otherwise.
        let letter: GradeLetter
        let summary: String
        let missing = [copiesCheck, mediaCheck, offsiteCheck, version].filter { $0.status != .pass }
        if evidence.localFiles == 0 && !anyBackupContent {
            letter = .F
            summary = "Nothing in this folder is downloaded on this Mac or held by a backup."
        } else if !backups.isEmpty {
            switch missing.count {
            case 0:
                letter = .A
                summary = "A backup holds it, and all four checks pass."
            case 1:
                letter = .B
                summary = "A backup holds it; one check is missing: \(missing[0].kind.title.lowercased())."
            default:
                letter = .C
                summary = "A backup holds it, but \(missing.count) checks are missing: "
                    + missing.map { $0.kind.title.lowercased() }.joined(separator: ", ") + "."
            }
        } else if version.status == .pass {
            letter = .C
            summary = "No backup holds it. \(name) keeps file history, which is as far as sync alone goes."
        } else {
            letter = .D
            summary = version.status == .fail
                ? "No backup holds it, and \(name) keeps no file history for it."
                : "No backup holds it, and \(name)'s file history is not confirmed."
        }

        // A backup whose files match by name and size but not by date: say so, so a folder
        // that looks unprotected is not a mystery. It still does not count.
        var explained = summary
        for (rootID, near) in evidence.dateMismatches.sorted(by: { $0.key < $1.key }) {
            guard let root = roots[rootID], !copies.contains(where: { $0.rootID == rootID }),
                  coverage(near.files, near.bytes, of: evidence) >= dateMismatchNotice else { continue }
            explained += " Most files in \(root.name) match by name and size but not by date, so they were not counted."
                + " The backup may have been made without keeping dates."
        }

        return FolderGrade(provider: evidence.provider, providerName: name, rootID: evidence.rootID,
                           account: evidence.account, folder: evidence.folder, files: evidence.files,
                           bytes: evidence.bytes, letter: letter, summary: explained, checks: checks,
                           copies: copies, partial: partial,
                           fix: fix(letter: letter, missing: missing, hasBackup: !backups.isEmpty,
                                    localShare: local, providerName: name))
    }

    /// Fixes follow sync-is-not-backup: a backup destination, never another cloud.
    static func fix(letter: GradeLetter, missing: [GradeCheck], hasBackup: Bool, localShare: Double,
                    providerName: String) -> String? {
        let destination = "a backup location such as a Time Machine disk, an external drive or a NAS share"
        let missingCopies = missing.contains { $0.kind == .copies }
        let version = missing.first { $0.kind == .versioned }
        switch letter {
        case .A:
            return nil
        case .F:
            return "Keep this folder downloaded on this Mac so a backup can copy it, then add \(destination) in Settings and scan again."
        case .C, .D:
            guard hasBackup else { return "Add \(destination) in Settings and scan again." }
            return missingCopies && localShare < coverageThreshold
                ? "Keep this folder downloaded on this Mac, or add a second backup location."
                : "Add a second backup location."
        case .B:
            if missingCopies {
                return localShare < coverageThreshold
                    ? "Keep this folder downloaded on this Mac, or add a second backup location."
                    : "Add a second backup location."
            }
            if let version {
                let cause = version.status == .unknown
                    ? "Cloudpane has not confirmed that \(providerName) keeps file history."
                    : "\(providerName) keeps no file history for this folder."
                return cause + " A Time Machine backup keeps its own history of the folder."
            }
            return nil
        }
    }

    static func report(snapshotID: Int64, evidence: [FolderEvidence], roots: [ScanRoot], facts: ProviderFacts,
                       paidPlans: Set<String> = [], singlePoint: SinglePointList) -> GradeReport {
        let byID = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0) })
        let grades = evidence.map { grade($0, roots: byID, facts: facts, paidPlans: paidPlans) }
            .sorted { ($0.provider, $0.rootID, $0.folder) < ($1.provider, $1.rootID, $1.folder) }
        var byProvider: [String: GradeRollup] = [:]
        for provider in Set(grades.map(\.provider)) {
            byProvider[provider] = GradeRollup.make(grades.filter { $0.provider == provider })
        }
        return GradeReport(snapshotID: snapshotID, folders: grades, overall: GradeRollup.make(grades),
                           byProvider: byProvider, singlePoint: singlePoint,
                           backupRoots: roots.filter { $0.kind == .backup })
    }
}
