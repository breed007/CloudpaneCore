import Foundation

/// What a report leaves out.
public struct ReportOptions: Sendable, Hashable {
    /// Leaves out every file path, file name, folder name, account name and backup location
    /// label, so the report can be shared. Figures are kept; they are grouped by provider
    /// and folders are numbered instead of named.
    public var hidePaths: Bool

    public init(hidePaths: Bool = true) {
        self.hidePaths = hidePaths
    }
}

/// Everything a report is built from. The app gathers it from the inventory; the report
/// reads nothing itself.
public struct ReportInput: Sendable {
    public var generatedAt: Date
    /// The scan the figures come from; nil before the first complete scan.
    public var snapshot: Snapshot?
    public var catalog: CatalogReport?
    public var totals: [ProviderTotal]
    public var roots: [RootSummary]
    public var plans: PlanReport?
    public var iCloud: ICloudUsage?
    public var grade: GradeReport?
    public var duplicates: DuplicateReport?
    public var history: [HistoryPoint]
    /// Providers the user added, so their plans show by name.
    public var customProviders: [CustomProvider] = []

    public init(generatedAt: Date = Date(), snapshot: Snapshot? = nil, catalog: CatalogReport? = nil,
                totals: [ProviderTotal] = [], roots: [RootSummary] = [], plans: PlanReport? = nil,
                iCloud: ICloudUsage? = nil, grade: GradeReport? = nil, duplicates: DuplicateReport? = nil,
                history: [HistoryPoint] = []) {
        self.generatedAt = generatedAt
        self.snapshot = snapshot
        self.catalog = catalog
        self.totals = totals
        self.roots = roots
        self.plans = plans
        self.iCloud = iCloud
        self.grade = grade
        self.duplicates = duplicates
        self.history = history
    }
}

/// A report as text blocks, ready for the app to lay out as a PDF. Core decides what the
/// report says and what it leaves out; the app only draws it.
public struct ReportDocument: Sendable, Hashable {
    public enum Block: Sendable, Hashable {
        case paragraph(String)
        /// Smaller, secondary text.
        case note(String)
        case table(headers: [String], rows: [[String]])
    }

    public struct Section: Sendable, Hashable {
        public let title: String
        public let blocks: [Block]
    }

    public let title: String
    public let subtitle: String
    public let sections: [Section]

    /// Every string in the document, one per line, for tests and for checking what a
    /// shared report contains.
    public var plainText: String {
        var lines = [title, subtitle]
        for section in sections {
            lines.append(section.title)
            for block in section.blocks {
                switch block {
                case .paragraph(let text), .note(let text): lines.append(text)
                case .table(let headers, let rows):
                    lines.append(headers.joined(separator: " | "))
                    lines += rows.map { $0.joined(separator: " | ") }
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Single-point files listed by name when paths are shown.
    public static let singlePointLimit = 50
    /// Graded folders listed per provider, largest first.
    public static let foldersPerProviderLimit = 50
    /// Scans listed in the history table, newest first.
    public static let historyLimit = 12

    public static func build(_ input: ReportInput, options: ReportOptions = ReportOptions(),
                             locale: Locale = .current) -> ReportDocument {
        let format = ReportFormat(locale: locale)
        let subtitle: String
        if let snapshot = input.snapshot, let finished = snapshot.finishedAt {
            subtitle = "Scan finished \(format.date(finished)). Report made \(format.date(input.generatedAt))."
        } else {
            subtitle = "No complete scan yet. Report made \(format.date(input.generatedAt))."
        }
        let sections = [
            footprint(input, options, format),
            plans(input, options, format),
            grade(input, options, format),
            singlePoint(input, options, format),
            duplicates(input, format),
            history(input, format),
            about(options),
        ]
        return ReportDocument(title: "Cloudpane report", subtitle: subtitle, sections: sections)
    }

    // MARK: - Sections

    static func footprint(_ input: ReportInput, _ options: ReportOptions, _ format: ReportFormat) -> Section {
        var blocks: [Block] = []
        let totals = input.totals.filter { $0.provider != "backup" }
        if input.snapshot == nil {
            blocks.append(.paragraph("Run a scan to see how much is stored with each provider."))
        } else if totals.isEmpty {
            blocks.append(.paragraph("The last scan found no files in any cloud storage folder."))
        } else {
            let files = totals.reduce(0) { $0 + $1.files }
            let bytes = totals.reduce(Int64(0)) { $0 + $1.logicalBytes }
            blocks.append(.paragraph("\(format.files(files)), \(format.bytes(bytes)) in total."))
            blocks.append(.table(
                headers: ["Provider", "Files", "Size", "Only in the cloud"],
                rows: totals.map {
                    [$0.providerName, format.count($0.files), format.bytes($0.logicalBytes),
                     format.bytes($0.placeholderBytes)]
                }))
        }
        if !options.hidePaths {
            let accounts = input.roots.filter { $0.root.kind != .backup }
            if !accounts.isEmpty {
                blocks.append(.table(
                    headers: ["Account folder", "Provider", "Files", "Size"],
                    rows: accounts.map {
                        [$0.root.name, $0.root.providerName, format.count($0.files), format.bytes($0.logicalBytes)]
                    }))
            }
        }
        if let catalog = input.catalog {
            let notInstalled = catalog.providers.filter { $0.state == .missing }.map(\.rule.displayName)
            if !notInstalled.isEmpty {
                blocks.append(.note("Not installed on this Mac: \(notInstalled.joined(separator: ", "))."))
            }
            for status in catalog.providers where status.state == .partial || status.state == .unavailable {
                let label = status.state == .partial ? "partial view" : "not readable"
                blocks.append(.note("\(status.rule.displayName), \(label): \(options.hidePaths ? "see Cloudpane for details." : status.reason)"))
            }
        }
        return Section(title: "Overview", blocks: blocks)
    }

    static func plans(_ input: ReportInput, _ options: ReportOptions, _ format: ReportFormat) -> Section {
        var blocks: [Block] = []
        if let plans = input.plans, !plans.rows.isEmpty {
            blocks.append(.table(
                headers: ["Provider", "Plan", "Per month", "Used", "Plan size", "Room left"],
                rows: plans.rows.map { row in
                    let sub = row.subscription
                    var plan = sub.name
                    if let bundle = sub.bundle { plan += " (\(bundle.displayName))" }
                    if sub.inactive { plan += " (inactive)" }
                    return [providerName(sub.provider, input), plan, format.money(row.monthly),
                            row.usedBytes.map(format.bytes) ?? "Not on this Mac",
                            sub.planBytes.map(format.bytes) ?? "Not entered",
                            row.headroomBytes.map(format.bytes) ?? ""]
                }))
            if !plans.personalTotal.isEmpty {
                blocks.append(.paragraph("Personal total: \(format.totals(plans.personalTotal)) a month."))
            }
            if !plans.bundledTotal.isEmpty {
                blocks.append(.note("Bundles, shown but not added to the personal total: \(format.totals(plans.bundledTotal)) a month."))
            }
            for row in plans.rows where row.reportedTotal != nil {
                blocks.append(.note("\(providerName(row.id, input)) uses the total you entered from System Settings."))
            }
            for row in plans.rows where row.isDeadWeight {
                blocks.append(.note("\(providerName(row.id, input)) is under 5% used in the last two scans."))
            }
            for option in plans.options {
                blocks.append(.paragraph("Option: move \(format.bytes(option.movedBytes)) from \(providerName(option.cancel, input)) into \(providerName(option.into, input)) and cancel \(providerName(option.cancel, input)), saving \(format.money(option.monthlySaving)) a month."))
            }
            if !plans.options.isEmpty {
                blocks.append(.note("Canceling a plan removes a copy of your files. Check the backup grade below before taking any option."))
            }
        } else {
            blocks.append(.paragraph("No plans entered. Plan sizes and prices are not readable on this Mac, so they are entered by hand in Providers."))
        }
        blocks += iCloudBlocks(input.iCloud, format)
        return Section(title: "Plans", blocks: blocks)
    }

    static func iCloudBlocks(_ usage: ICloudUsage?, _ format: ReportFormat) -> [Block] {
        guard let usage else { return [] }
        var rows: [[String]] = []
        rows.append(["iCloud Drive", usage.driveBytes.map(format.bytes) ?? "Not scanned", "Measured by the scan"])
        if let photos = usage.photos {
            rows.append(["Photos", format.bytes(photos.logicalBytes), "Estimate from the Photos library on this Mac"])
        } else {
            rows.append(["Photos", "Not measured", "Choose the Photos library in Providers"])
        }
        if let total = usage.reportedTotal {
            rows.append(["Total in iCloud", format.bytes(total.bytes), "Entered from System Settings"])
            if let other = usage.otherBytes {
                rows.append(["Everything else", format.bytes(other), "The total minus iCloud Drive and Photos"])
            }
        }
        for item in ICloudUnavailable.all {
            rows.append([item.title, "Not available in this build", item.reason])
        }
        return [.table(headers: ["iCloud", "Size", "Source"], rows: rows)]
    }

    static func grade(_ input: ReportInput, _ options: ReportOptions, _ format: ReportFormat) -> Section {
        guard let grade = input.grade, let overall = grade.overall else {
            return Section(title: "Backup grade", blocks: [
                .paragraph("The grade appears after a complete scan that finds at least one folder."),
            ])
        }
        var blocks: [Block] = [
            .paragraph("Overall: \(overall.letter.rawValue). \(overall.explanation)"),
            .note("Sync is not backup: another cloud copy never raises the grade. A backup location you add as a scan root does."),
        ]
        if grade.backupRoots.isEmpty {
            blocks.append(.note("No backup location was part of this scan."))
        } else if options.hidePaths {
            let kinds = Dictionary(grouping: grade.backupRoots) { $0.backupKind ?? .other }
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.displayName) (\($0.value.count))" }
            blocks.append(.note("Backup locations in this scan: \(kinds.joined(separator: ", "))."))
        } else {
            let names = grade.backupRoots.map { "\($0.name) (\(($0.backupKind ?? .other).displayName)\($0.isOffsite ? ", off-site" : ""))" }
            blocks.append(.note("Backup locations in this scan: \(names.joined(separator: ", "))."))
        }
        blocks.append(.table(
            headers: ["Provider", "Grade", "Folders", "Size", "How it was worked out"],
            rows: grade.byProvider.sorted { $0.key < $1.key }.map { provider, rollup in
                [providerName(provider, input), rollup.letter.rawValue, format.count(rollup.folders),
                 format.bytes(rollup.bytes), rollup.explanation]
            }))
        // Largest folders first within each provider, so the cap keeps the ones that matter
        // most. Ties fall back to the folder name in Finder's order (2 before 10).
        let backupNames = grade.backupRoots.map(\.name).filter { !$0.isEmpty }
        let byProvider = Dictionary(grouping: grade.folders, by: \.provider).sorted { $0.key < $1.key }
        var rows: [[String]] = []
        var omitted: [(provider: String, count: Int)] = []
        for (_, folders) in byProvider {
            let sorted = folders.sorted {
                if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
                return $0.folder.localizedStandardCompare($1.folder) == .orderedAscending
            }
            for (index, folder) in sorted.prefix(foldersPerProviderLimit).enumerated() {
                let label: String
                var why = folder.summary
                if options.hidePaths {
                    label = "\(folder.providerName) folder \(index + 1)"
                    // The only free text naming a place is a backup's label in a summary.
                    for name in backupNames { why = why.replacingOccurrences(of: name, with: "a backup location") }
                } else {
                    label = folder.folder.isEmpty ? "\(folder.providerName) (top level)" : "\(folder.providerName): \(folder.folder)"
                }
                rows.append([label, format.bytes(folder.bytes), folder.letter.rawValue, why, folder.fix ?? ""])
            }
            if sorted.count > foldersPerProviderLimit, let first = sorted.first {
                omitted.append((first.providerName, sorted.count - foldersPerProviderLimit))
            }
        }
        blocks.append(.table(headers: ["Folder", "Size", "Grade", "Why", "To improve it"], rows: rows))
        for (provider, count) in omitted {
            let noun = count == 1 ? "folder" : "folders"
            blocks.append(.note("And \(format.count(count)) more \(provider) \(noun), not listed here. Cloudpane shows every folder."))
        }
        return Section(title: "Backup grade", blocks: blocks)
    }

    static func singlePoint(_ input: ReportInput, _ options: ReportOptions, _ format: ReportFormat) -> Section {
        guard let list = input.grade?.singlePoint else {
            return Section(title: "Single points of failure", blocks: [
                .paragraph("The list appears with the backup grade."),
            ])
        }
        var blocks: [Block] = []
        if list.totalFiles == 0 {
            blocks.append(.paragraph("No file was found in only one place."))
            return Section(title: "Single points of failure", blocks: blocks)
        }
        let verb = list.totalFiles == 1 ? "exists" : "exist"
        blocks.append(.paragraph("\(format.files(list.totalFiles)), \(format.bytes(list.totalBytes)), \(verb) in only one place, with no other copy anywhere this scan looked."))
        if options.hidePaths {
            var byProvider: [String: (files: Int, bytes: Int64)] = [:]
            for file in list.files {
                let current = byProvider[file.provider] ?? (0, 0)
                byProvider[file.provider] = (current.files + 1, current.bytes + (file.logicalSize ?? 0))
            }
            if !byProvider.isEmpty {
                let shown = list.files.count < list.totalFiles ? "Largest \(format.counted(list.files.count, "file")) by provider" : "By provider"
                blocks.append(.table(headers: [shown, "Files", "Size"],
                                     rows: byProvider.sorted { $0.key < $1.key }.map {
                                         [providerName($0.key, input), format.count($0.value.files), format.bytes($0.value.bytes)]
                                     }))
            }
        } else {
            let home = input.snapshot?.homePath ?? ""
            let shown = list.files.prefix(singlePointLimit)
            blocks.append(.table(headers: ["File", "Provider", "Size"],
                                 rows: shown.map {
                                     [format.path($0.path, home: home), providerName($0.provider, input),
                                      format.bytes($0.logicalSize ?? 0)]
                                 }))
            if list.totalFiles > shown.count {
                blocks.append(.note("The \(format.count(shown.count)) largest are listed; Cloudpane shows the rest."))
            }
        }
        return Section(title: "Single points of failure", blocks: blocks)
    }

    static func duplicates(_ input: ReportInput, _ format: ReportFormat) -> Section {
        guard let report = input.duplicates else {
            return Section(title: "Duplicates", blocks: [.paragraph("Duplicates appear after a complete scan.")])
        }
        guard report.totalGroups > 0 else {
            return Section(title: "Duplicates", blocks: [.paragraph("No duplicates were found.")])
        }
        return Section(title: "Duplicates", blocks: [
            .table(headers: ["Match", "Groups", "Files", "Could be freed"],
                   rows: report.totals.map {
                       [$0.tier.title, format.count($0.groups), format.count($0.files), format.bytes($0.reclaimableBytes)]
                   }),
            .note("Could be freed counts every copy after the first. Cloudpane never removes a file; each group is for you to review."),
        ])
    }

    static func history(_ input: ReportInput, _ format: ReportFormat) -> Section {
        let points = input.history.filter { $0.provider != "backup" }
        guard !points.isEmpty else {
            return Section(title: "History", blocks: [.paragraph("History appears after the first complete scan.")])
        }
        var byScan: [Int64: (date: Date, bytes: Int64)] = [:]
        for point in points {
            let current = byScan[point.snapshotID] ?? (point.date, 0)
            byScan[point.snapshotID] = (current.date, current.bytes + point.logicalBytes)
        }
        let scans = byScan.sorted { $0.key > $1.key }
        var blocks: [Block] = [
            .table(headers: ["Scan", "Total in the cloud"],
                   rows: scans.prefix(historyLimit).map { [format.date($0.value.date), format.bytes($0.value.bytes)] }),
        ]
        if let newest = scans.first, let oldest = scans.last, scans.count > 1 {
            let change = newest.value.bytes - oldest.value.bytes
            let direction = change >= 0 ? "grew by" : "shrank by"
            blocks.append(.paragraph("Since \(format.date(oldest.value.date)), the total \(direction) \(format.bytes(abs(change)))."))
        }
        return Section(title: "History", blocks: blocks)
    }

    static func about(_ options: ReportOptions) -> Section {
        var blocks: [Block] = [
            .note("Cloudpane reads file metadata on this Mac. It made no network connection and downloaded nothing to make this report. Sizes are logical sizes, as each provider counts them."),
        ]
        blocks.append(.note(options.hidePaths
            ? "File paths, file and folder names, account names and backup labels are left out of this report. Plan names you typed are included."
            : "This report includes file paths, folder names and account names."))
        return Section(title: "About this report", blocks: blocks)
    }

    static func providerName(_ id: String, _ input: ReportInput) -> String {
        if let custom = input.customProviders.first(where: { $0.providerID == id }) { return custom.name }
        if let total = input.totals.first(where: { $0.provider == id }) { return total.providerName }
        if let status = input.catalog?.providers.first(where: { $0.rule.id == id }) { return status.rule.displayName }
        return ProviderRule.defaultTable.first { $0.id == id }?.displayName ?? id
    }
}

/// iCloud categories this build cannot see, each with the reason.
public struct ICloudUnavailable: Sendable, Hashable, Identifiable {
    public let title: String
    public let reason: String
    public var id: String { title }

    public static let all: [ICloudUnavailable] = [
        ICloudUnavailable(title: "Device backups",
                          reason: "They are stored in your Apple Account, which Cloudpane never signs in to."),
        ICloudUnavailable(title: "Mail",
                          reason: "Reading it needs Full Disk Access, which Cloudpane does not request."),
        ICloudUnavailable(title: "Messages",
                          reason: "Reading it needs Full Disk Access, which Cloudpane does not request."),
    ]
}

/// Number, size, money and date formatting for reports, in one locale.
public struct ReportFormat: Sendable {
    public let locale: Locale

    public init(locale: Locale = .current) {
        self.locale = locale
    }

    /// Decimal units, as providers sell plans; "0 bytes" rather than "Zero KB".
    public func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: value)
    }

    public func count(_ value: Int) -> String { value.formatted(.number.locale(locale)) }

    /// "1 file", "2 files", "1,200 files". The noun is singular and takes a plain "s".
    public func counted(_ value: Int, _ noun: String) -> String {
        "\(count(value)) \(value == 1 ? noun : noun + "s")"
    }

    /// "1 file", "2 files".
    public func files(_ value: Int) -> String { counted(value, "file") }

    public func money(_ value: Money) -> String {
        value.amount.formatted(.currency(code: value.currency).locale(locale))
    }

    /// "$13.98 + €10.00" when currencies are mixed. Never converted.
    public func totals(_ value: CurrencyTotals) -> String {
        value.totals.map(money).joined(separator: " + ")
    }

    public func date(_ value: Date) -> String {
        value.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale))
    }

    /// A path with the home folder shown as "~".
    public func path(_ path: String, home: String) -> String {
        !home.isEmpty && path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
