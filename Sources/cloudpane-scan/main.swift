// cloudpane-scan: runs one read-only scan and prints the per-provider table.
//
// Usage:
//   cloudpane-scan [--home <dir>] [--backup <dir>]... [--exclude <dir>]... [--db <file>]
//
//   --home <dir>    Look for provider roots under <dir> instead of the real home directory.
//   --backup <dir>  Also scan <dir> as a backup root. Repeatable.
//   --exclude <dir> Leave out the account root <dir>. Repeatable.
//   --db <file>     Keep the inventory in <file>. By default it lives in memory only. The
//                   exclusions and provider names stored in it (by the app, from Providers)
//                   apply too.

import CloudpaneCore
import Foundation

struct Options {
    var home: URL?
    var backups: [URL] = []
    var excluded: [String] = []
    var database = ":memory:"
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(2)
}

func parseOptions() -> Options {
    var options = Options()
    var args = CommandLine.arguments.dropFirst()
    func value(for flag: String) -> String {
        guard let value = args.popFirst() else { fail("\(flag) needs a value") }
        return (value as NSString).expandingTildeInPath
    }
    while let arg = args.popFirst() {
        switch arg {
        case "--home": options.home = URL(fileURLWithPath: value(for: arg), isDirectory: true)
        case "--backup": options.backups.append(URL(fileURLWithPath: value(for: arg), isDirectory: true))
        case "--exclude": options.excluded.append(value(for: arg))
        case "--db": options.database = value(for: arg)
        case "-h", "--help":
            print("usage: cloudpane-scan [--home <dir>] [--backup <dir>]... [--exclude <dir>]... [--db <file>]")
            exit(0)
        default: fail("unknown argument \(arg)")
        }
    }
    return options
}

/// Makes control characters visible and escapes pipes, so a name never breaks a table row.
func cell(_ text: String) -> String {
    var out = ""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "|": out += "\\|"
        default:
            if scalar.value < 0x20 || scalar.value == 0x7f {
                out += String(format: "\\x%02x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out
}

func row(_ cells: [String]) -> String { "| " + cells.map(cell).joined(separator: " | ") + " |" }

func human(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

let options = parseOptions()
let materialization: String
switch MaterializationPolicy.disableForProcess() {
case .success: materialization = "off for this process, and on for the walk thread only around each folder listing call"
case .failure(let error): materialization = "could not disable (\(error)); the scan still never reads file contents"
}

let catalog = ProviderCatalog(home: options.home)
let report = catalog.detect()
let backupRoots = options.backups.map { ScanRoot.backup($0) }

let inventory: Inventory
do {
    inventory = try Inventory(path: options.database)
} catch {
    fail("could not open the inventory: \(error)")
}

// Choices stored in the database (an in-memory one has none), plus --exclude.
var choices: ScanChoices
do {
    choices = try await inventory.scanChoices()
} catch {
    fail("could not read the scan choices: \(error)")
}
choices.excludedRoots.formUnion(options.excluded.map(canonicalRootPath))
let roots = report.scanRoots(includeUnrecognized: true, backups: backupRoots, choices: choices)
let scanner = Scanner(roots: roots)

let issues = IssueLog()
let snapshotID: Int64
do {
    snapshotID = try await inventory.recordScan(scanner, homePath: report.homePath) { event in
        if case .issue(let issue) = event { issues.append(issue) }
    }
} catch {
    fail("scan failed: \(error)")
}

print("# Cloudpane scan")
print("")
print("- Home: \(cell(report.homePath))" + (options.home == nil ? "" : " (--home)"))
print("- Snapshot: \(snapshotID)")
print("- Dataless materialization: \(materialization)")
print("- Placeholder rule: \(scanner.placeholderRule.id) (\(scanner.placeholderRule.summary))")
print("- Packages count as one item sized by the regular files inside them.")

print("")
print("## Providers")
print("")
print(row(["Provider", "Account root", "State", "Reason"]))
print(row(["---", "---", "---", "---"]))
for status in report.providers {
    print(row([status.rule.displayName, "-", status.state.rawValue, status.reason]))
    if status.roots.count > 1 {
        for root in status.roots {
            print(row([status.rule.displayName, root.folderName, root.state.rawValue, root.reason]))
        }
    }
}
for entry in report.unrecognized {
    let named = choices.customProvider(forFolder: entry.folderName)
    print(row([named?.name ?? "Unrecognized", entry.folderName, entry.state.rawValue,
               named == nil ? entry.reason : "Named in Providers"]))
}
for excluded in scanner.excludedRoots + report.scanRoots(includeUnrecognized: true, backups: backupRoots)
    .filter({ choices.isExcluded($0.path) }) where !roots.contains(where: { $0.path == excluded.path }) {
    print(row([excluded.providerName, excluded.name, "excluded", "Excluded from scans"]))
}
for backup in backupRoots {
    if let reason = report.backupRejectionReason(for: backup) {
        print(row(["Backup", backup.path, "refused", reason]))
    } else {
        print(row(["Backup", backup.path, "added", "Scanned as a backup root"]))
    }
}

let summaries: [RootSummary]
do {
    summaries = try await inventory.rootSummaries(snapshotID: snapshotID)
} catch {
    fail("could not read the inventory: \(error)")
}

print("")
print("## Totals")
print("")
if summaries.isEmpty {
    print("No roots found. Nothing to scan.")
} else {
    print(row(["Provider", "Account root", "Files", "Packages", "Dirs", "Logical bytes", "Logical",
               "Allocated bytes", "Allocated", "Placeholders", "Dataless (st_flags)", "Compressed",
               "Zero-byte", "Hard links skipped", "Symlinks skipped", "Other types skipped",
               "Errors", "Unlisted folders", "Package logical bytes", "Package allocated bytes", "Walk ms"]))
    print(row(Array(repeating: "---", count: 21)))
    for s in summaries {
        print(row([s.root.providerName, s.root.name, "\(s.files)", "\(s.packages)", "\(s.directories)",
                   "\(s.logicalBytes)", human(s.logicalBytes), "\(s.allocatedBytes)",
                   human(s.allocatedBytes), "\(s.placeholders)", "\(s.dataless)", "\(s.compressed)",
                   "\(s.zeroByte)", "\(s.hardLinksSkipped)", "\(s.symlinksSkipped)",
                   "\(s.otherTypesSkipped)", "\(s.errors)", "\(s.unlistedFolders)", "\(s.packageLogicalBytes)",
                   "\(s.packageAllocatedBytes)", String(format: "%.1f", s.elapsedMilliseconds)]))
    }
}

let logged = issues.all
if !logged.isEmpty {
    print("")
    print("## Errors")
    print("")
    for issue in logged {
        print("- \(cell(issue.rootID)): \(cell(issue.path)): \(cell(issue.message))")
    }
}

/// realpath(3), so --exclude matches the canonical paths roots carry.
func canonicalRootPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return (path as NSString).standardizingPath }
    defer { free(resolved) }
    return String(cString: resolved)
}

final class IssueLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ScanIssue] = []
    func append(_ issue: ScanIssue) { lock.withLock { items.append(issue) } }
    var all: [ScanIssue] { lock.withLock { items } }
}
