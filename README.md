# CloudpaneCore

The engine behind Cloudpane, a free, read-only macOS app from 404 Cybersecurity LLC that
audits cloud storage across iCloud Drive, Dropbox, Google Drive, OneDrive and Box without
logging in to any of them. This package finds the providers' File Provider folders, walks
them for metadata, and stores each scan in SQLite. On top of the inventory it finds
duplicates, grades each folder against the 3-2-1 backup rule, works out what each storage
plan costs, and builds the text of a shareable report. It exports a scan as JSON or CSV. It
has no user interface; the Cloudpane app is a SwiftUI shell over it.

## Rules the package keeps

- Read-only. Scans read metadata through `lstat(2)` and URL resource values. It never moves,
  copies, deletes or uploads a file. Scans turn off dataless-file materialization on their
  thread for every file, so the scan never reads or downloads a file's contents, and turn it
  on only around each folder listing call, so a provider can fetch the list of a folder it
  has not listed on the Mac yet, as Finder does. A provider may then download items it keeps
  on the Mac by its own policy, as it would after the folder is opened in Finder.
- No network, no accounts, no provider APIs.
- System frameworks only: Foundation, Darwin, SQLite3, UniformTypeIdentifiers, CoreServices
  (FSEvents) and CryptoKit (SHA-256). No AppKit, no SwiftUI, no package dependencies.
- It reads file contents in one place only: opt-in hashing of folders the user chooses, after
  showing how much will download. The Photos library estimate reads file sizes inside the
  library package and nothing else.
- Swift 6 language mode with strict concurrency, macOS 14 or later.

Design decisions and their reasons are in [DECISIONS.md](DECISIONS.md).

## Build and test

```sh
swift build
swift test
```

The tests build a fake home directory in a temporary folder for each test: provider roots
for all five providers, two OneDrive accounts, a `GoogleDrive-<email>` root, sparse files
standing in for placeholders, packages, hidden files, symbolic links, hard links, a FIFO, an
unreadable folder and a path longer than `PATH_MAX`. Sparse files are never ubiquitous and
never carry the dataless flag, so the tests cannot show how real providers behave.

`ScannerMemoryTests` scans 10,000 files and fails if the process footprint grows by 40 MB or
more. A healthy walk grows by a few megabytes. Activity Monitor's Memory column during a
`cloudpane-scan` run of a large tree is the manual check; it should stay flat.

## cloudpane-scan

A command-line tool that runs one scan and prints a Markdown table per provider root.

```sh
swift run cloudpane-scan                       # the real home directory
swift run cloudpane-scan --home <dir>          # a fake home, such as one built by the M0 spike
swift run cloudpane-scan --backup /Volumes/Archive --db scan.sqlite
```

`--backup` adds a backup root and can be repeated. A folder inside a provider's synced folders
is refused and the table says why: sync is not backup. `--db` keeps the inventory in a file;
by default it lives in memory. Package contents are counted in the package's size, and the
table shows those bytes in their own columns, so the numbers can be compared with the M0
spike, which counted packages as 0 bytes.

## Layout

| Path | Contents |
| --- | --- |
| `Sources/CloudpaneCore/Providers` | The provider table, detection (`ProviderCatalog`) and the user's scan choices (`ScanChoices`, `CustomProvider`) |
| `Sources/CloudpaneCore/Scanning` | `Scanner`, the walk, `FileRecord` and the placeholder rule |
| `Sources/CloudpaneCore/Store` | The SQLite wrapper and `Inventory` with its queries, migrations, grade and duplicate searches |
| `Sources/CloudpaneCore/Duplicates` | Duplicate tiers, grouping and ranking |
| `Sources/CloudpaneCore/Grade` | The 3-2-1 grade |
| `Sources/CloudpaneCore/Hashing` | Opt-in SHA-256 hashing |
| `Sources/CloudpaneCore/Subscriptions` | Plans, billing, the price catalog, plan math and the iCloud figures |
| `Sources/CloudpaneCore/Export` | JSON and CSV export, and the report (`ReportDocument`) |
| `Sources/CloudpaneCore/Support` | Small POSIX and concurrency helpers |
| `Sources/CloudpaneCore/Resources` | The price catalog and provider facts, with sources |
| `Sources/cloudpane-scan` | The command-line tool |
| `Tests/CloudpaneCoreTests` | XCTest suite and the fixture tree builder |

## Using it

```swift
let report = ProviderCatalog().detect()
let scanner = Scanner(roots: report.scanRoots(backups: [.backup(backupURL)]))
let inventory = try Inventory(path: databasePath)
let snapshot = try await inventory.recordScan(scanner, homePath: report.homePath) { event in
    // Progress, issues and records arrive here as they happen.
}
let totals = try await inventory.providerTotals(snapshotID: snapshot)
```

## License

CloudpaneCore is released under the MIT License; see [LICENSE](LICENSE). It has no
third-party dependencies.
