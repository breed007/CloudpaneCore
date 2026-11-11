# Decisions

Design decisions for CloudpaneCore, with the reasoning behind each. Newest decisions go at
the end of their section. When a decision changes, edit it here and say what replaced it.

## Persistence: raw sqlite3, no GRDB

The inventory uses the system SQLite through `import SQLite3`, wrapped in a thin connection
and statement layer (`Store/SQLite.swift`): prepared statements reused across a batch,
`BEGIN IMMEDIATE` transactions that roll back on any error, and `SQLITE_TRANSIENT` for every
bound string.

- GRDB is a third-party dependency, and adding one needs sign-off. SQLite ships with macOS,
  so the package keeps zero SPM dependencies.
- The wrapper follows the in-house pattern in Log Recon's LogCore package
  (`LogCore/Sources/LogCore/Store/SQLite.swift` in the Log Recon repository). It is a copy of
  the pattern, not a dependency on LogCore. If a third app needs the same wrapper, it
  moves into its own shared package.
- The `Inventory` actor owns the connection and serializes access. The connection itself is
  not `Sendable` and has no locking of its own.
- Schema changes go through `PRAGMA user_version`. An unknown version is an error, not a
  silent rebuild. Version 2 added the normalized search columns. Version 1 only ever came
  from a pre-release build, so it is refused with a message to delete the database and scan
  again rather than migrated.
- One process owns the database at a time. When it opens, any snapshot still marked
  `running` belonged to a scan that was killed or crashed, and is marked `interrupted`.

Schema, one database: `snapshots` (id, started, finished, status, home path, placeholder
rule id), `snapshot_roots` (per-root totals for each snapshot, including the skip and error
counts that never reach the files table), and `files` (one row per record, keyed by snapshot
and path). The extra `snapshot_roots` table holds the "per-provider totals" the project
notes put on `snapshots`, normalized so two accounts of one provider stay separate.

## Placeholder rule: raw facts stored, rule swappable (provisional)

No real provider data has been scanned yet, so the scanner does not bake in a definition of
"placeholder". Every record stores the raw facts: logical size, allocated size, ubiquitous
flag, download status, `SF_DATALESS` and `UF_COMPRESSED` from `lstat(2)`. `isPlaceholder` is
derived from those facts by one small `PlaceholderRule` value, and the rule's id is stored
with each snapshot.

Default rule, `dataless-or-strict-v1`:

1. `SF_DATALESS` set: placeholder. This is the kernel's own answer.
2. Otherwise a placeholder only when logical size > 0, allocated size is 0 (or not
   reported), the download status is not `current`, and the file is not compressed.

The compressed exclusion matters because a small `UF_COMPRESSED` file keeps its data in an
attribute and reports 0 allocated bytes while fully on the Mac. The M0 spike's "strict"
definition counted such a file as a placeholder; this rule does not.

This rule is provisional. When the spike runs against real accounts, compare it with the
dataless count per provider and change it here if they disagree. Because the raw facts are
stored, an old snapshot can be re-derived under a new rule without rescanning.

## Packages: one record, sized by their contents

Packages (`.photoslibrary`, `.app` and other bundles) are leaves: one record each, and the
walk never emits anything inside them. The spike found that a package directory reports no
`fileSizeKey` or `totalFileAllocatedSizeKey`, so a package counted as 0 bytes. That would
make a 200 GB Photos library vanish from the footprint.

The scanner therefore walks the package's contents for metadata only and records the sums
of their logical and allocated sizes on the package's record.

- Only regular files count. Hidden files inside the package are included, since they are
  part of what it occupies. Symbolic links and other file types inside are ignored.
- A hard link already counted elsewhere in the scan adds nothing.
- Nothing inside a package is opened. Reading metadata is enough.
- A package is dataless when the package directory is dataless or every file inside is. It
  is compressed when any file inside is. The placeholder rule then applies as usual: a
  package is a placeholder only when none of its contents is on the Mac.
- Skips inside a package do not show up in the root's skip counts. Errors do.
- `RootSummary.packageLogicalBytes` and `packageAllocatedBytes` show how much of a root's
  total came from package contents. Subtracting them gives the spike's numbers exactly.

## Provider states: installed, partial, missing, unavailable

Detection returns one of four states per provider and per root, each with a sentence saying
why. `unavailable` is a fourth state beyond the three in the milestone notes. It covers a
root or parent that exists but cannot be read: a symbolic link (never followed), a file
where a folder belongs, or a permission error. A sandboxed app sees permission errors
before the user grants access, and calling that "not installed" would be wrong.

Status is kept per account root and rolled up per provider. All roots installed: installed.
No root that can be walked: the worst root's state. Anything in between is partial, because
the scan sees some of the provider's data. Every working account is still scanned, and the
reason names the accounts that are not ("Scanning 1 of 2 accounts. OneDrive-Contoso: ...").
One broken account never makes a working one look unavailable.

## Detection under the App Sandbox

The app is granted two folders: `~/Library/CloudStorage` and the CloudDocs folder itself.
It is never granted `~/Library/Mobile Documents`. A sandboxed probe on macOS 27 showed what
the sandbox allows without a grant: `lstat(2)` works anywhere and reports ENOENT correctly,
while listing a folder and `access(2)` fail with EPERM.

So a rule with an exact folder name (iCloud Drive, Box) is looked up directly: every parent
component is checked with `lstat` (no symbolic links), then the root itself, without listing
the parent. Prefix rules (Dropbox, Google Drive, OneDrive) and unrecognized folders still need
the parent listed, which the CloudStorage grant allows. A missing folder reads as "not
installed" even before any grant.

## Partial view: from what the scan could not list

Superseded on 2026-10-25 by the folder-listing rule (below). The first version marked a
provider root partial when the root itself was `SF_DATALESS`. With folder listing allowed, a
dataless root is no longer a sign of a partial view: the scan asks the provider for its list
like any other folder. That check is removed.

A root is now a partial view when the last scan could not see some of its folders: the
listing call failed, or the folder was still dataless after its listing call. The scan
counts those per root (`RootSummary.unlistedFolders`, schema 7, split by cause in schema 8), reports each as an issue
naming the provider, and `ScanPartialViewDetector` turns the counts into the provider's
partial-view reason. Before any scan, `NoPartialViewDetector` marks nothing partial.

Core still cannot detect Dropbox Selective Sync or OneDrive "Choose folders". The
`PartialViewDetector` protocol stays the hook for those checks, and each provider rule names
its setting (`partialViewSetting`) for when real data shows what those settings leave on
disk. The app shows no setting name today.

## Scanner: a dedicated thread, an event stream

- The walk runs on its own `Thread`, not on the Swift concurrency pool. It is long, blocking
  file-system work, and the dataless-materialization policy is set per thread, which only
  holds if the walk never changes threads.
- That thread turns off dataless materialization with
  `setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, OFF)`, and
  turns it on only around folder listing calls (see "The folder-listing rule"). The scan
  summary records whether turning it off worked. `cloudpane-scan` also turns it off for the whole
  process. The app should not use the process scope if it ever offers opt-in hashing of
  dataless files.
- `scan(snapshotID:)` returns `AsyncStream<ScanEvent>`: root started, file record, issue,
  progress, root finished, and finished. One stream with all of it lets a consumer handle
  records and progress in one loop.
- Cancellation: when the consumer stops iterating or its task is canceled, the stream
  terminates and sets a flag that the walk checks before each item.
- The stream buffers without limit. The inventory writes in batches faster than the walk
  reads, so this should not matter in practice. If it ever does, the fix is a bounded
  channel with backpressure, not dropping records.
- Progress is sent at every root boundary and at most every 100 ms in between.
- Every item is handled inside its own autorelease pool, and so is every folder listing
  (the enumerator's `nextObject()` call, before the folder-listing rule). Foundation autoreleases URLs and resource values on each step, and a
  secondary thread drains its outer pool only when it exits. Without the per-item pool, a
  scan kept about 12 KB per file until it finished (2.48 GB at 200,000 files). With it, peak
  footprint stays near 4 MB however large the tree. `ScannerMemoryTests` guards this.

## Canceled and incomplete snapshots

- A canceled scan keeps the records it wrote. The root being walked at the moment of
  cancellation gets a root row built from the records that arrived, flagged
  `wasInterrupted`, so the files table and the root rows always agree. Its skip counts are
  unknown and stay 0. Rolling those rows back would hide work that was done, and showing
  partial results is the app's choice to make.
- Totals, folder totals, the type breakdown and diff refuse a snapshot that is not
  `complete` with `InventoryError.incompleteSnapshot`, because files a partial scan never
  reached would read as files that are gone. `allowIncomplete: true` lets the app show a
  partial scan when it labels it as one. Search, root rows and export are not gated; the
  JSON export carries the snapshot's status.

## Backup roots: sync is not backup

A backup root at or inside a provider root, at or inside an unrecognized folder under
`Library/CloudStorage`, or anywhere under `Library/CloudStorage` or
`Library/Mobile Documents` is refused. `CatalogReport.backupRejectionReason(for:)` gives the
sentence to show ("Photos is inside the Dropbox folder Dropbox, which syncs to the cloud.
Sync is not backup, so it is not scanned as a backup."), and `scanRoots(backups:)` leaves
such roots out.

The scanner applies the same rule to whatever roots it is handed, as a second line of
defense: a backup root at or inside any synced root is dropped and listed in
`rejectedBackups`. Backup roots always walk after synced roots, so a hard link shared with a
synced root is credited to the synced root. A backup root never changes a provider's
totals.

Paths are compared after realpath(3), Unicode normalization and case folding, since the
default APFS volume ignores both case and normalization. On a case-sensitive volume this can
refuse a folder whose name differs only in case, which errs on the safe side.

A backup root that contains provider roots (a whole `~/Library`, say) is accepted. The
provider roots inside it are skipped and walked under their own identity.

## What gets walked

- Every walkable provider root, then walkable unrecognized folders under
  `Library/CloudStorage`, then user-added backup roots. Unrecognized folders are scanned by
  default, as the spike did, because they are usually other File Provider apps. Callers can
  turn this off.
- Hidden items are skipped (dot names and `UF_HIDDEN`). Symbolic links are never followed.
  Directories, FIFOs, sockets and devices are counted but produce no record.
- Hard links are counted once per scan, by device and inode. The first path seen wins.
- A folder that is another scan root is skipped and walked under its own identity, so a
  backup root that contains a provider root does not count it twice. The same folder listed
  twice as a root is walked once.
- Top-level folders follow `ProviderRule.topLevelDepth`. Google Drive uses 2, so its
  top-level folders are "My Drive/Projects" rather than just "My Drive".
- Paths longer than `PATH_MAX` (1024 bytes) stop the walk below that point and log
  `NSCocoaErrorDomain 258, errno 63`. Walking past it would need an `openat`-based walker.
  That is not built, since nobody has seen such paths in real provider data yet.

## Home directory

`ProviderCatalog.userHome` reads the home directory from the password database
(`getpwuid`). Inside the App Sandbox, `FileManager`'s home directory is the app's container,
which holds no provider roots. Tests and `cloudpane-scan --home` pass a different home.

## Export

- CSV follows RFC 4180: CRLF row endings, and a field is quoted when it contains a comma, a
  double quote, CR or LF, or starts or ends with a space. Quotes inside are doubled.
- By default, a text field that starts with `=`, `+`, `-`, `@`, tab or CR gets a leading
  single quote, so a spreadsheet does not run a file name as a formula. This changes how such
  names look in the CSV. `CSVOptions(neutralizeFormulas: false)` turns it off. JSON export is
  always verbatim.
- Dates are ISO 8601 in UTC with six fractional digits, rounded to the microsecond. The
  system date format styles stop at milliseconds, so the export formats the fraction
  itself. The inventory keeps the date the system reported, a double that can carry
  sub-microsecond digits; those digits are not exported, so a date read back from an export
  can differ from the stored one by up to half a microsecond.
- Both formats stream row by row. The file is written in the system's item-replacement
  directory and moved into place at the end, so a failed export never leaves a truncated
  file under the real name.
- Export never replaces a file. The final move is `renamex_np` with `RENAME_EXCL`, one
  atomic step that fails if anything has the name, including a file that appeared while the
  export ran. The caller gets `ExportError.destinationExists` and picks another name.

## File types

The content type is the one the system reports, with a short override table
(`FileCategory.contentTypeOverrides`). The system registers `.bin` as a MacBinary archive,
but such files are nearly always raw data, so they are recorded as `public.data` and fall
under "other" rather than "archive".

## Search

Search is a literal substring match (SQLite `instr`) on the name or the full path. Each file
row stores a search form of its name and path, and the query is converted the same way:
Unicode NFC, then case folding beyond ASCII. APFS keeps names in whatever normalization they
were created with, so a decomposed "résumé.pdf" is found by "résumé" and by "RÉSUMÉ", and
"STRASSE" finds "Straße". Diacritics stay significant: "resume" does not match "résumé".
Results carry the exact original name and path. Full-text search can replace this if it
proves too weak.

## Diff

Diff compares the versions present in one snapshot and not the other, so unchanged files cost
nothing. Same path in both is a change (size, date or placeholder state). A removed file and
an added file with the same SHA-256 (both hashed), or the same name, size and modification
date within 2 seconds, are reported as a move or rename instead of a removal and an addition.
Hash matches are paired first. Each file pairs at most once.

## M3: subscriptions, backup locations and the grade

Entries marked **Confirmed** were interpretations that needed checking; all of them were
confirmed on 2026-11-01.

### Schema version 3

Additive only: a `subscriptions` table (one row per provider, enforced by a unique column;
confirmed 2026-10-24: two accounts with one provider share one plan entry),
a `backup_locations` table (label, kind, off-site flag and the read-only bookmark), two
columns on `snapshot_roots` recording how each backup root was labeled at scan time, and an
index on `files (snapshot_id, search_name, logical_size)` for matching across locations.
The version 2 DDL is frozen in `Inventory.schemaV2`, so a test can build a real version 2
database and migrate it. Each migration step runs in its own transaction.

A database this build cannot read is refused before anything writes to it (the version is
read before switching to WAL, which changes the file header), and the message never tells
the user to delete it: version 1 came from a pre-release build, and a newer version came
from a newer Cloudpane that should be updated to.

### Money

- Prices are `Decimal`, stored as decimal strings, so 119.88 a year is exactly 9.99 a month.
- Normalization: price x cycles per year / (12 x frequency), with a 365.25-day year and
  cycles per year kept as a fraction (365.25/7 for weekly), so there is one division at the
  end. 1 a day, 7 a week and 30.4375 a month are exactly the same plan. A result with no
  terminating decimal form (9.99 a week) carries Decimal's 38 significant digits; the app
  rounds only for display.
- No currency conversion. There is no network and no exchange-rate table, so totals are kept
  per currency and the app says plainly when there is more than one.
- The personal monthly total leaves out inactive plans and bundle plans (Apple One, Google
  One family, Microsoft 365, employer-paid). Active bundle plans have their own total, shown
  for reference.

### Plan table

- **Confirmed 2026-11-01.** Used is the logical size of the provider's roots on this Mac in the latest
  complete scan, placeholders included, since a quota counts what is in the cloud. A provider
  with no root in that scan reads as "not on this Mac", not as zero.
- **Confirmed 2026-11-01.** Cost per TB is the monthly price per terabyte of plan size, with 1 TB = 10^12
  bytes as providers sell it, not per terabyte used.
- **Confirmed 2026-11-01.** Growth and months to full need two complete scans at least a day apart. The
  baseline is the newest complete scan at least 24 hours older than the latest, chosen by
  time, not from a fixed number of recent scans, so any number of scans in a day never hides
  it. Two scans minutes apart would otherwise project a plan full within hours. With fewer
  than two complete scans, both stay hidden and the table says why.
- Months to full is headroom / growth per month. A plan already over its size shows "Full".
  A provider that shrank or held steady is "not on course to fill".
- **Confirmed 2026-11-01.** Dead weight: under 5% of the plan in the latest complete scan and in the same
  baseline growth uses (at least a day older), counted only for active, paid, personal plans
  with a plan size, and only when the provider was on this Mac in both scans. A bundle or
  employer-paid plan is never flagged. The plan size cannot exceed 10,000 TB.
- **Confirmed 2026-11-01.** Consolidation options are a set that can all be taken together. Active, paid,
  personal plans are considered from the largest monthly price down; each moves into the
  plan in the same currency with the most room left after the options already chosen, so no
  two options count the same free space. A plan that receives files is never also offered
  for canceling, and a canceled plan never receives any. Each is stated as "Option: move X
  into Y and cancel X" with the monthly saving. Never across currencies, never involving a
  bundle. Moving files between providers never adds a cloud copy. The app shows each option
  beside the backup grade of the provider it would cancel. Switching to a smaller tier of the
  same provider is not offered yet.

### Price catalog and provider facts

- `Resources/price-catalog.json` is data, updated with releases. Each tier carries provider,
  tier name, plan bytes, price (a decimal string), currency, cycle, frequency, region, bundle
  kind, verified flag, source URL, as-of date and notes. Loading fails when either as-of date
  is missing or malformed, a source is missing or not https, a plan size is zero or less, or
  a price or currency code is malformed. The first catalog is US prices in USD as of
  2026-10-24. Four Dropbox and Box tiers are unverified; the app pre-fills
  them the same way and labels the price as not confirmed.
- `Resources/provider-facts.json` holds version history per provider as data: whether it is
  kept, the retention the grade quotes, and the cited sources. Any claim, history or no
  history, must cite https sources and say what is kept, or the file fails to load. Only
  "to verify" may stand without a source. As of 2026-10-24, from the providers' own pages:
  - Dropbox keeps history: 30 days on Basic, Plus and Family; 180 days on Professional and
    Essentials.
  - Google Drive keeps history: old versions of uploaded files for 30 days or until 100
    newer versions exist, unless marked to keep forever.
  - OneDrive keeps history: the last 25 versions on personal accounts. Work and school
    accounts follow the organization's settings and are treated as versioned.
  - **Confirmed 2026-11-01.** Box keeps history only on paid plans (Personal Pro keeps 10 versions; the
    free plan keeps 1, which is no history). Box counts as versioned only when an active Box
    plan with a price above zero, or marked employer-paid, is entered in Providers (then called Subscriptions);
    otherwise the check fails and says why. The grade is recomputed when plans change.
  - iCloud Drive keeps no provider-side file history: only files deleted in the last 30 days
    can be recovered, through Recently Deleted and Data Recovery on iCloud.com. That is a
    recovery window for deleted files, not version history; Apple's pages say nothing about
    earlier versions of a file that still exists. Document versions some Mac apps keep live
    on the Mac, not with iCloud Drive. Sources: Apple's "Recover deleted files" guide for
    iCloud and support article 111763.
  Without a backup, folders therefore cap at C, except iCloud Drive and Box without a paid
  plan, which cap at D. With a backup, iCloud Drive caps at B.

### Content matching between locations

A file counts as present in another location when that location has a downloaded file with
the same name (compared in SearchKey form: NFC and case-folded), the same logical size, and a
modification date within 2 seconds, anywhere in it. This is the strong duplicate tier from
the project rules. Name and size alone (the first M3 rule) let an unrelated file of the same
size count as a backup. Relative paths were rejected: Time Machine and NAS copies sit under
unrelated paths. The limits: a copy tool that resets dates breaks the match, and two
different files created within 2 seconds with the same name and size cannot be told apart
without hashing, the exact tier in M4.

A backup made by a tool that resets dates matches nothing under this rule. Files that match a
backup by name and size but not by date are counted separately and never as a copy; when they
cover at least half of a folder, its explanation says the backup may have been made without
keeping dates, so a folder that looks unprotected is not a mystery.

Only downloaded files hold content. A placeholder never counts as a copy, in a backup root or
in another cloud. Empty files hold nothing to lose: they are not counted as downloaded
copies, and a folder of only empty files is not graded.

A location counts as a copy of a folder when it holds at least 90% of the folder by size.
Below that it is listed as a partial copy and does not count.

### Grade checks

- Copies: the provider's cloud, a downloaded copy on this Mac, and every backup root that
  holds the folder. Three are needed. The copy on this Mac counts when at least 90% of the
  folder is downloaded, either in the folder itself or as identical downloaded files in any
  sync folder on the Mac.
- **Confirmed 2026-11-01 (resolves a conflict inside the project rules).** The rules' definition of
  copies lists "each cloud", while the hard rule says the grade never rewards more cloud
  copies. The hard rule wins: at most one sync cloud, the provider's own, counts. Another
  cloud holding the same files adds no copy and no medium, and cannot make anything
  off-site. The first M3 build counted other clouds, and adding the same files to Google
  Drive raised a folder from C to B.
- **Confirmed 2026-11-01.** The downloaded copy in a sync folder counts toward copies but not toward
  media, because deleting the file in the cloud deletes it there too. Media passes only when
  a backup root holds the folder.
- **Confirmed 2026-10-24.** Off-site passes through the provider's own cloud,
  which is off the Mac and outside the home, as the rule is written. That makes the check
  pass for every graded folder, and the on-site or off-site label on a backup location
  changes only the explanation, never a letter. The stricter alternative, requiring an
  off-site copy that is not a sync cloud, was considered and not taken.
- Versioned: the provider fact from data, quoting its retention. Unknown is never a pass.
- Single-point: fails when the folder is in exactly one place.

### Letters

**Confirmed 2026-11-01.** In this order:

1. F when no non-empty file in the folder is downloaded anywhere on this Mac (in the folder
   itself, or as an identical downloaded file in any sync folder) and no backup root holds any
   of it: no materialized or backed-up copy anywhere seen. Partial backup coverage keeps a
   folder out of F. Another cloud's placeholders do not.
2. When a backup root holds the folder (at least 90%): A with all four of copies, media,
   off-site and versioned; B with one missing; C with two or more missing, since a real
   backup still exists. The C fallback is an addition to the original plan; without it, a backed-up
   folder could grade below a cloud-only one.
3. Without a backup: C when the provider keeps file history, D otherwise. Sync is not
   backup, so nothing scores above C without a backup root, however many clouds hold it.

Each folder grade carries the five checks with pass, fail or unknown and a one-line reason,
the locations holding it with their coverage, a one-line summary of why the letter, and a
fix. Fixes always point to a backup destination (Time Machine, an external drive, a NAS
share) or to keeping the folder downloaded so a backup can copy it, never to another cloud.

Unrecognized folders under `Library/CloudStorage` are not graded, since nothing is known
about their history. Downloaded files in them count as copies on this Mac, like any other
sync folder.

### Roll-up

**Confirmed 2026-11-01.** The overall letter is the byte-weighted average of the folder scores (A = 4 down
to F = 0), rounded down, so a large weak folder weighs more than a small one. When every
folder is empty, folders weigh the same. The explanation states the average, and the
distribution (folders and bytes per letter) is shown beside it. The rejected alternative was
the worst letter weighted by size, which lets one tiny folder decide the whole grade.
Providers get their own roll-up the same way, which is what consolidation options show.

### Exists only in one place

A non-empty placeholder in a provider root with no downloaded copy anywhere Cloudpane looked:
none on this Mac and none in a backup, by the matching rule above. Another cloud's
placeholder is not a copy. This is the same test as F, so a folder graded F has every file in
this list and a folder kept out of F by a downloaded copy has none of those files in it.
Sorted by size, largest first; the first 500 are listed with the full count and size.

### Backup locations

- The user adds a folder with the open panel and labels it: name, kind (Time Machine,
  external drive, NAS share, other) and on-site or off-site. Cloudpane cannot tell where a
  disk physically sits, so it asks. The bookmark is read-only and app-scope, stored with the
  location in the inventory database. Removing a location deletes its row and bookmark;
  past scans keep the root rows they recorded.
- A folder at or inside a synced folder is refused with `backupRejectionReason`, as before.
- Each scan root records the location's kind and off-site flag, so a snapshot can be graded
  the same way later even after a label changes.
- A location whose bookmark does not resolve (a disk not connected) is left out of the scan.
  The grade then sees no backup for its folders. Carrying the last seen backup contents
  forward is left for incremental rescans in M4.
- The open panel asks for the latest Time Machine backup rather than the whole disk.
  Scanning every dated backup on a Time Machine disk would take a very long time and count
  the same files many times.

### Grading speed

Grading must stay interactive on large libraries. On a 200,000-file Dropbox account with a
backup root holding all 200,000 files (names repeating 1,000 times), the first M3 build was
still running after 9 minutes: the cross-location join scanned an unindexed key list for
every file.

- Downloaded, non-empty files go into a temporary table with two indexes, (name, size,
  location, date) and (name, size, date). Every check is an EXISTS probe that seeks one of
  them and stops at the first match. Each location (this Mac, then each backup root) is one
  aggregate query, so duplicates never multiply rows.
- The single-point matching runs once into a temporary table of row ids and sizes; the
  totals and the 500 largest come from that table.
- Memory-mapped reads and a 64 MB page cache keep repeat passes over the files table cheap.
- On disk, grading runs on its own read-only connection off the Inventory actor, so search,
  totals and plans are answered while it works (WAL lets both read at once). An in-memory
  database is graded on the actor's connection.
- `GradePerformanceTests` checks every grading query's plan for an index seek on the key
  table and grades 100,000 files against a time limit; removing the index fails both.

Grading can be canceled. Each stage checks for cancellation, and on disk a canceled grade
interrupts the SQLite statement in flight on its reader connection. The app runs grades
through `LatestOnly`: starting one cancels the one before, and a grade that finishes after a
newer one started is dropped, so two quick plan saves always end with the newer result. Saving
a plan closes the sheet at once; the Backup grade view shows that it is regrading meanwhile.

Measured in a release build on 200,000-file test databases: 1.5 to 1.6 seconds warm, about
2.7 seconds on the first run with a cold page cache.

M4 update: the per-backup passes made grading slow with many backup roots (14 s on a
420,000-row test database with 21 backups, against 5.3 s in M3). Grading now makes one pass over
the graded files whatever the number of backups: every location has a bit (this Mac bit 0,
backups 1 to 62), a covering index on (name, size, date, bit, hash) lets each file's single
range seek collect the bits of every location holding a match, and the masks are unpacked in
Swift. More than 62 backups fall back to one pass each for the rest. The same database now
grades in 2.2 to 2.3 s warm. The timing guard grades 120,000 files across 21 backups. A search started mid-grade returns in
0.2 seconds instead of waiting.

### Grading needs a complete scan

The grade is computed only from a complete snapshot. When the latest scan was canceled or
interrupted, the app grades the last complete one and says so.

## M4: duplicates, hashing, incremental snapshots

Entries marked **Confirmed** were interpretations that needed checking; all of them were
confirmed on 2026-11-01.

### System frameworks beyond Foundation

The package rule is system frameworks only, no third-party code. M4 adds two, both shipped
with macOS and neither a user-interface framework:

- CoreServices, for FSEvents. The watcher belongs in Core because it is file-system logic with
  no UI, and in Core `swift test` runs it against a real temporary folder.
- CryptoKit, for SHA-256. A system framework, so no dependency is added.

### Snapshot storage: versioned rows

Files are stored as versions. A row is valid from the snapshot in `snapshot_id` (the first
that recorded it) through `last_snapshot`, or is current when `last_snapshot` is NULL. A scan
writes staged rows, visible only to itself. When a scan completes, a merge runs in one
transaction: a staged row equal to the current version is dropped, a changed or vanished
file closes its old version, and new rows become current. A full scan's merge covers every
current version; an incremental snapshot's covers only the paths it rescanned, and everything
else carries forward without being written. Every query selects a snapshot's rows through one
helper; for the latest complete snapshot that is the current versions, which partial indexes
serve, so the M1 to M3 queries keep their speed. A scan that never completes keeps its staged
rows private, as before. Version 3 databases migrate in place: the latest complete snapshot's
rows become current, other complete snapshots' rows stay valid for exactly their snapshot.

Rejected: copying every unchanged row into each snapshot with a retention policy. It would
leave queries untouched, but each coalesced watcher update would rewrite about 200,000 rows on
a large library, and diffs would be limited to the snapshots kept.

Measured in a release build on a 220,000-file tree (a generated test layout), with the
database checkpointed before each reading:

| Step | Database | Notes |
| --- | --- | --- |
| Full scan | 243.0 MB | 47.8 s, I/O-bound |
| After 20 incremental snapshots (11 files changed each) | 243.3 MB | +0.2 MB in all; 0.23 s median per snapshot, 0.81 s max |
| First unchanged full rescan | 421.6 MB | 178 MB of that is free pages left by the staged rows |
| Second unchanged full rescan | 421.6 MB | No growth; SQLite reuses the free pages |

A full copy per snapshot would have added about 4.9 GB over the same 20 snapshots. Closed
versions are kept, so history is complete; pruning old versions is not needed yet and is not
built.

The merge looks up the current version by path. Its equality on root and top-level folder
once led the planner to the folder index instead, 21 s instead of 0.13 s for 100,000 files,
so the lookups name `files_open_path` with INDEXED BY. A test merges 100,000 unchanged files
and checks that no rows are written.

### Incremental snapshots

- A changed path is mapped to its scan root and to the item a full walk would record: the path
  itself, or the package containing it, since packages are leaves. Paths inside hidden folders
  or below a symbolic link are ignored, as a full walk would. The item's subtree is walked again
  with the same rules and becomes the merge scope.
- Per-root totals that come from rows (files, bytes, placeholders, packages, zero-byte) are
  recomputed. Counts only a full walk sees (folders, skipped links and other types, errors)
  carry over from the base snapshot until the next full scan.
- A full scan runs instead when FSEvents reports MustScanSubDirs, dropped events, a wrapped
  event ID or a moved watched folder; when a folder appears or disappears directly inside
  `~/Library/CloudStorage` (a provider added or removed); when the roots differ from the last
  scan's (a backup location added or reconnected); and on demand.
- A new hard link to a file already recorded in the same root is dropped by the merge (same
  root and inode as a current version at another path), so it never counts as a second file
  or forms a duplicate group. The check runs after closing, so a full scan that no longer saw
  the first path keeps the link.
- Scans and incremental updates run one at a time inside the inventory, in the order they
  asked, through a write gate taken before reading the base snapshot; nothing read before the
  walk's await can go stale. The app also queues a manual scan behind an update in progress.
  A test runs both at once and checks the two snapshots do not overlap.
- Starting any scan deletes the staged rows earlier canceled, failed or interrupted scans left
  behind (their snapshot records stay), so at most one unfinished scan's rows exist and
  repeated cancels do not grow the database; SQLite reuses the freed pages. Tested.
- A test edits a fixture in every way (add, remove, modify, new nested folder, removed folder,
  change inside a package, move), records the change incrementally, and compares with a full
  rescan: totals, folder totals, type breakdown, root totals, grade and single-point list are
  identical, and the move is detected.

### Watcher

- FSEvents with file-level events, coalesced until the tree is quiet for 2 seconds or 20
  seconds have passed since the first pending change, so a single change is reported about
  2.2 seconds after it happens (measured 2.2 s; the 2 s quiet period dominates). The
  acceptance target (within one minute) is a test on a temporary folder with a shorter quiet
  period for speed; the app uses 2 seconds.
- The app watches the two granted folders and connected backup locations, starts the watcher
  only while their security-scoped access is active, and restarts it when grants or backup
  locations change. Changes that arrive while a scan or an update is running are queued and
  applied afterwards. The watcher can be turned off in Settings (on by default).
- A sandboxed probe confirmed FSEvents delivers events inside the App Sandbox for a folder the
  process can read. Delivery for a folder reached through a security-scoped bookmark is
  expected to work the same way but is unverified, as is everything about real File Provider
  trees: **unverified on real providers**, since this Mac has none. Whether providers update
  placeholders in ways FSEvents reports is the main open question.

### Hashing

- Opt-in per top-level folder. Before hashing, the app shows exact counts and bytes: how much
  is only in the cloud and will download, and how much is already on the Mac and is read
  without downloading, with a note that downloaded files take space until macOS evicts them.
- The hashing worker runs on its own thread at utility quality of service. A run the user
  confirmed is the only place dataless materialization is turned on for files, for that
  thread (the scan turns it on only around folder listing calls), and
  only the cloud-only files counted in the confirmation sheet may download: the app passes
  the exact plan the sheet showed, so files that appeared since wait for the next
  confirmation. Right before opening each file the worker checks SF_DATALESS with lstat(2);
  eviction keeps size, dates and inode, so this is the only way to tell. A dataless file
  outside the confirmed set is skipped and reported as needing confirmation. The automatic
  pass over files already on the Mac runs with materialization off on its thread, so a
  mistake fails instead of downloading. Tests simulate eviction by injecting the dataless
  check. setiopolicy_np(3) says a
  thread follows the process policy only while its own is left at the default, so the
  worker's "on" takes precedence over the app's process-wide "off", which the app now sets
  at launch. The man page also gives the system default as off. Whether a provider then
  downloads on read is unverified here.
- Files are opened read-only with O_NOFOLLOW and F_NOCACHE, never coordinated, written or
  moved, read in 1 MB chunks inside an autorelease pool, and checked again after reading; a
  file whose size, modification date, inode change time or inode changed meanwhile is
  skipped. Hashes are written as they
  arrive, so a cancel keeps what was done.
- History stays immutable. A hash is known from the latest complete snapshot on: when a file's
  current version began in an earlier snapshot, recording the hash closes that version and
  starts a copy carrying the hash at the latest snapshot, so earlier snapshots and diffs
  never see a hash they did not have. After that the version carries forward unchanged, with
  its hash.
- The facts that decide whether a file changed, and whether a hash still applies, include the
  inode change time (st_ctime, with nanoseconds), which only the system sets. An edit that
  keeps the size and restores the modification date (touch -r, rsync --inplace -t) still
  changes it, so the old hash is dropped; the tests restore the date to the nanosecond to
  prove it. A side effect: downloading a placeholder changes its ctime, so a file hashed while
  in the cloud is hashed again later, from the local copy, by the automatic pass. Rows from
  before schema version 5 have no ctime; it is filled in when a merge next sees the file
  unchanged, which is the next full scan (an incremental update fills it only for the files
  it rescans) or the file's next change. An old hash on such a row is dropped rather than
  trusted. Known and accepted: until then, a migrated row's ctime cannot reveal an edit.
- **Confirmed 2026-11-01.** After each update, files already on the Mac in an opted-in folder are hashed
  automatically, since nothing downloads. Files only in the cloud are hashed only when the user
  chooses Hash this folder again and confirms the download.
- Packages are folders and are never hashed.
- In the grade, when both files of a name, size and date match have hashes, the hashes must be
  equal; a different hash overrides the match. That resolves test case s7 and is tested.

### Duplicates

- Tiers from the project rules: exact (equal SHA-256), strong (same size, same name, dates
  within 2 seconds), weak (same size only, at least 1 MB). Each file lands in its highest tier
  only. **Confirmed 2026-11-01:** 1 MB is 1,000,000 bytes, matching the decimal units used for plans.
- Display only, known and accepted: a backup copy is listed with every strong group whose
  date window (earliest to latest member, widened by 2 seconds) contains it, so a backup copy
  can appear under two neighboring groups. It is never counted in either.
- Strong groups are anchored, as the project rules say "within 2 seconds": a group starts at
  its earliest file and takes every file within 2 seconds of it, so any two members are within
  2 seconds of each other. The next file outside the window starts the next group. (The first
  M4 version chained neighbors and built a 200-copy group spanning about 20 seconds.)
- A group holding two or more different hashes drops its hashed files, since a hash proves
  they differ; the rest stay grouped on the weaker evidence.
- **Confirmed 2026-11-01.** Groups are made of copies in sync clouds (provider and unrecognized folders).
  Copies in backup locations are listed with exact and strong groups as "also in backups" and
  never counted: a backup copy is the backup doing its job, and calling it reclaimable would
  turn sync-is-not-backup upside down. Weak groups do not list backups, because size alone
  says too little.
- **Confirmed 2026-11-01.** Packages take part as single leaves sized by their contents: they can be strong
  or weak duplicates, never exact.
- Ranked by reclaimable bytes, (copies - 1) x size. Nothing is ever resolved automatically;
  the only actions are Reveal in Finder and Copy path.
- Like the grade, duplicates run on a read-only connection off the actor, cancel through
  LatestOnly in the app, and read only current versions (checked by a test on each query's
  plan). The search streams: each tier's query reads only rows whose key occurs more than once
  (hash and size, name and size, or size of at least 1 MB), in key order, holding one key's
  rows at a time; a bounded collector keeps the 500 largest groups and totals for all. Backup
  copies are looked up by index for the listed groups only. On a 420,000-row test database,
  where all 200,000 cloud files are real duplicates, a release build takes 1.9 s with a peak
  footprint of about 85 MB (the first M4 version loaded every row: 2.9 s and 880 MB). On a
  library of unique files the footprint grows by about 1 MB, which a test guards.


## M5: iCloud figures, the report and launch preparation

### Schema version 6

Two tables, added only. `reported_usage` holds a total the user typed in, one row per
provider. `photos_library` holds the one Photos library the user chose: its path, its
read-only security-scoped bookmark, and the last estimate (NULL until measured). Choosing the
same library again keeps the estimate; choosing another clears it.

### iCloud in Providers (then Subscriptions)

- iCloud Drive comes from the latest complete scan, as before.
- **Confirmed 2026-11-01.** Photos is an estimate: the logical size of every regular file inside the
  Photos library package the user picks in an open panel. It reads metadata only, through the
  same code that sizes packages during a scan (`PackageMeasure`, shared with `Walker`): no
  file is opened, the library's database is not read, PhotoKit is not used, and nothing reads
  private properties. It is labeled as an estimate in both directions: Optimize Mac Storage
  keeps smaller versions on the Mac (iCloud holds more), and the package holds thumbnails,
  caches and edits iCloud does not count (iCloud holds less). APFS clones inside the library
  (Photos duplicates and imports can be clones) share blocks on disk but each count in full,
  so the estimate can be far above what Finder shows: on one real library, 29.25 GB against
  Finder's 12.74 GB. The per-file allocated sum has the same flaw (it came to 29.33 GB), so
  the app no longer shows a "stored on this Mac" figure at all. Cloudpane cannot tell whether
  Optimize Mac Storage is on without reading Photos' settings, so it explains rather than
  detects.
- **Confirmed 2026-11-01.** The estimate never enters the plan math. Without an entered total, the iCloud
  plan's used figure is iCloud Drive from the scan only, as in M3.
- **Unverified.** Whether macOS privacy protection lets a sandboxed app list a Photos library
  the user picked in an open panel. If listing is refused, the estimate reports "macOS did not
  let Cloudpane read the size of this library" and asks for the entered total instead; it is
  never measured as empty and never worked around (no Full Disk Access request). The refusal
  path is tested with a mode-000 package, which stands in for the refusal but is not TCC.
- The entered total comes from System Settings, under your name, then iCloud. When present
  it replaces the scanned figure for the iCloud plan's used, headroom, percentage and
  consolidation lines. While a total is in use:
  - growth and months to full are hidden ("Growth is not measured while the plan uses the
    total you entered."), because a typed-in figure compared with a scanned one would count
    Photos and backups as growth;
  - **Confirmed 2026-11-01.** dead weight needs the two-scan rule on scanned figures and the entered total
    also under 5% of the plan. An entered total can only clear the flag, never raise it.
  - **Confirmed 2026-11-01.** a consolidation option that cancels iCloud moves the whole entered total,
    which includes device backups that cannot move to another provider. It overstates what
    moves, which errs toward needing more room, never less.
- "Everything else" is the entered total minus iCloud Drive and the Photos estimate, floored
  at zero, and labeled as covering device backups, Messages, Mail and other apps.
- Device backups, Mail and Messages are listed as "Not available in this build", each with
  one sentence: backups live in the Apple Account, which Cloudpane never signs in to; Mail and
  Messages need Full Disk Access, which Cloudpane does not request.
- **Confirmed 2026-11-01.** The iCloud section appears only when iCloud Drive is on the Mac or the user
  has already entered something for iCloud (a plan, a total or a library). A Mac with only
  Google Drive sees no iCloud section.
- Apple One tiers were already bundles in the price catalog (M3) and stay out of the
  personal total.

### Report

- Core builds the report as text blocks (`ReportDocument`); the app only lays it out as a
  PDF with Core Text. Core stays Foundation-only and the content and redaction are tested in
  Core.
- Sections: footprint, plans (with the iCloud breakdown when shown), backup grade with each
  folder's explanation and fix, single points of failure, duplicate totals per tier, history
  totals (newest 12 scans and the change since the oldest), and a note on how it was made.
- **Confirmed 2026-11-01.** "Hide file paths and names" is on by default. It leaves out file paths, file
  names, folder names, account folder names (which hold email addresses for Google Drive),
  and backup location labels and paths. Folders are numbered per provider ("Google Drive
  folder 2"), single points of failure are summarized per provider, backup locations are
  counted by kind, and partial-view reasons are replaced by a pointer to the app. A backup
  label inside a folder's explanation is replaced with "a backup location". Plan names stay,
  because the user typed them as plan names, even though one could hold an email address;
  the setting's label and the report's closing note both say "Plan names you typed are
  included." Payment method, notes and URL never appear in either mode. A test fails if any name, path or label from the fixture appears in the hidden
  report, and the same input with names shown must contain them, so the check cannot pass
  vacuously.
- The PDF carries a title and creator ("Cloudpane") and no author.
- The report reads the latest complete scan. Grade and duplicates already on screen are
  reused when they belong to that scan; otherwise they are computed for it.
- The PDF goes to ~/Downloads through the same no-clobber move as JSON and CSV
  (`writeNewFile`, `renamex_np` with `RENAME_EXCL`), named "Cloudpane report <date> at
  <time>.pdf", with "2", "3" and so on when a name is taken.

### Releasing the package

- **Confirmed 2026-11-01.** Package tags are plain semantic versions with no "v", which is
  what SwiftPM expects, so they never look like the app's `v<marketing-version>` release
  tags.
- The app pins the package to an exact version in its `project.yml`.

## The folder-listing rule (2026-10-25)

This was approved after the real-provider runs recorded in the app repository's
`Spike/RESULTS.md`; the project rules carry it as the one exception to "never materializes".

What the runs showed:

- With materialization off for the whole walk, listing a folder the provider has not listed
  on this Mac yet fails with errno 11 (EDEADLK). That hid all of Google Drive (its one
  top-level folder was dataless) and 34 OneDrive and Box folders.
- The spike's `--allow-folder-listing` walk turned materialization on for the walk thread
  only around each folder listing call: 270 cloud-only folders were listed, with zero errors,
  and Cloudpane's own reads touched no file's contents. One of 2,153 cloud-only files did
  gain local data during that run: a 168-byte OneNote "Notebook.url" shortcut in OneDrive.
  The unified log shows fileproviderd fetching it from its own background-download
  scheduler (`fetch-content … why:materialization|itemChangedRemotely|backgroundWork
  sched:background`, a watcher that fires about once a minute), while the spike's listings
  appear only as `populate-directory … sched:default`. Listing the folder made OneDrive aware
  of the item, and OneDrive's own policy downloaded it, as it would after opening the folder
  in Finder. So the accurate claim is that Cloudpane never reads or downloads a file's
  contents (except opt-in hashing), not that nothing downloads.

What the scanner does now:

- The enumerator walk is replaced by a depth-first listing walk (`Walker.walk`). Each
  folder is listed with `contentsOfDirectory(at:includingPropertiesForKeys: [], options: [])`,
  with materialization on for exactly that call (`FolderLister`). No resource values are
  prefetched and no options are passed (`.skipsHiddenFiles` reads each child's hidden flag),
  so nothing about the children is read while it is on. Dot-named children are dropped after
  the policy is restored, and items with the hidden flag are dropped by the walk, which reads
  each item's flags with lstat anyway. The thread is then set back to its previous policy, off on a scan thread,
  and the policy is read back to check. Every lstat and resource-value read runs with it off.
- If the policy cannot be turned back off, the walk stops at once: no further item is read,
  the scan ends as interrupted, and an issue says why. The scan's thread ends with the walk,
  so the policy cannot leak to other work.
- If it cannot be turned on, the folder is listed with the policy unchanged, which fails for
  an unlisted folder (reported) and works for every other folder.
- Package contents are measured under the same rule (`PackageMeasure` lists folders too).
  The Photos library estimate is the exception: it runs on a shared Swift concurrency
  thread in the app, and the library is a local folder, so it lists without touching the
  thread's policy (`FolderLister.withoutMaterialization`).
- Kept from the enumerator walk: hidden items skipped, symbolic links never followed,
  packages as leaves, hard links counted once (first path seen; children are now visited in
  path order), nested scan roots left to their own root, an autorelease pool per folder and
  per item, cancellation before each item, progress at most every 100 ms, errno in every
  issue, and the PATH_MAX hint (now also for ENAMETOOLONG from lstat).
- A folder that was dataless when reached gets a progress update with `gettingFolderList`
  set while the provider fetches its list, so the app can say so. A first scan can spend most
  of its time there (OneDrive took 40 seconds for 195 folders in the spike).
- Incremental rescans walk changed folders with the same rule. If a folder inside a rescanned
  subtree cannot be listed, that subtree is left out of the merge, so rows the walk could not
  see are not closed. The base snapshot's `unlisted_folders` counts carry forward unchanged
  through incremental snapshots; the next full scan recounts them.
- The hashing worker is unchanged.
- Unlisted folders are counted by cause (schema 8): still dataless after the listing call
  (the provider did not provide the list), permission denied (EACCES, EPERM), path too long
  (ENAMETOOLONG, from a listing or from lstat), or another failure. Folders inside packages
  count the same way. The partial-view reason names each cause, so a permission problem is
  not blamed on the provider.
- Measured on this Mac with `cloudpane-scan` against the real home on 2026-10-25, the files and
  logical bytes per provider match the spike's folder-listing run exactly (Dropbox 147 /
  955,661,056; Google Drive 236 / 319,892,295; OneDrive 1,486 / 5,025,866,783; Box 284 /
  30,953,160,551), with 0 unlisted folders and 0 errors. Afterward, all 2,152 files recorded
  as dataless still had SF_DATALESS. The folders had already been listed by the spike run,
  so this run did not exercise slow first listings.

## Adding and removing providers (2026-10-25)

Adding and removing providers in the Providers view was approved on this date. The calls
below were made then, and the ones marked **Confirmed** were confirmed on 2026-11-01. All of them change only
Cloudpane's own database. Nothing installs, signs in, or touches a provider app or a file.

### Schema version 9

Three tables, added only. `custom_providers` (id, name, folder_name, created_at) holds the
providers the user added; `excluded_roots` and `forgotten_roots` hold account root paths,
canonical, with the time they were set. `ScanChoices` reads all three at once.

### Custom providers

- **Confirmed 2026-11-01.** One record covers both kinds that were asked for: a cost-only plan is a custom
  provider with no folder; a named folder is one with `folder_name` set. Its provider id is
  `custom-<id>`, and its plan is stored like any other plan under that id. The
  one-plan-per-provider rule is unchanged: a custom provider is a new provider, so it may
  own one plan, and built-in providers still have one each.
- A folder can carry one name (unique `folder_name`), compared exactly. Names are trimmed,
  required, and at most 60 characters. A name that matches a built-in provider, "Other cloud
  folders", or another custom provider is refused, comparing case-insensitively after Unicode
  normalization: two lookalike names would show as one provider in every list.
- Ids use AUTOINCREMENT and are never reused. Past snapshots keep rows, root totals and
  history points filed under a removed provider's id and last name; a provider added later
  gets a new id and starts with no history. (Schema 9 was changed in place before release:
  no shipped database ever had the earlier table.)
- Removing a custom provider deletes its plan in the same transaction.
- A named folder is scanned as a root of kind `provider` with the custom provider id and
  name (`ScanRoot.custom`, applied by `CatalogReport.scanRoots(choices:)`), so its records,
  root totals, history points, duplicates, File search results and grade all carry the name.
  The grade has no facts for it, so version history is "unknown" and never a pass.
- **Confirmed 2026-11-01.** Naming a folder takes effect at the next scan, which the app starts at once.
  Snapshots taken before keep the folder under "Other cloud folders"; History shows the two
  names as separate lines rather than rewriting the past. Removing the name works the same
  way in reverse.

### Cost-only plans

- `PlanReport.build(costOnly:)` takes the provider ids of plans with no folder. Such a plan
  counts toward the per-currency totals and follows the same bundle and inactive rules. It
  has no used space, room left, growth, months to full or dead-weight flag, even if usage
  data carried its id, and consolidation options never move files into it or suggest
  canceling it. Cost per terabyte still shows when a plan size is entered.
- **Confirmed 2026-11-01.** The growth note reads "Not on this Mac, so only its cost is tracked." The
  Providers row shows the status "Not on this Mac", and Overview lists the plan as "Plan
  only, not on this Mac" so its plan can be edited from there too.

### Excluded accounts

- Keyed by the account root's path. `Scanner(excluding:)`, `IncrementalScanner(excluding:)`,
  `FileWatcher(excluding:)` and `CatalogReport.scanRoots(choices:)` all drop a root at or
  inside an excluded path. The watcher drops excluded events before anything else, including
  events that would ask for a full rescan.
- Excluding or including starts a full scan. The full scan closes the excluded root's current
  rows, so the latest snapshot leaves it out of totals, Overview, File search, duplicates and
  the grade, while older snapshots keep what they recorded. The opt-in hashing worker only
  hashes current rows, so an excluded account is never hashed.
- **Confirmed 2026-11-01.** If a scan is already running when the user excludes or includes an account or
  names a folder, the app does not cancel it. It queues one full rescan that starts as soon
  as the running scan ends, so the change always reaches the latest snapshot. Stopping a
  scan by hand drops the queued one too.
- The row stays in Providers with the status "Excluded from scans" and no used space.
  Overview counts only included accounts ("2 accounts, 5 files, 1 excluded") and shows a
  built-in provider as "Excluded from scans" when every one of its accounts is excluded.
- `cloudpane-scan` applies exclusions and names stored in the database given with `--db`,
  and takes `--exclude <dir>` (repeatable) as well.

### Forgotten accounts

- Forget is offered only on an account marked "Not found" (walked by the latest complete
  scan, not found now). It hides the row. `reconcileForgotten(detectedRoots:)` runs whenever
  the app reloads its choices: an account found again loses its mark and shows by itself, and
  if it goes missing later it shows as "Not found" again.

### The Providers view

- **Confirmed 2026-11-01.** Add provider is one sheet with three tabs: supported service (the built-in
  providers not on this Mac, with how each shows up and a Scan again button), plan without a
  folder (a name, then the plan form), and name a folder (an unrecognized folder and a name).
- The ⋯ menu offers only what applies: on a provider line, Remove plan (with a confirmation
  that names the plan) and, for a provider the user added, Remove from Cloudpane (with a
  confirmation); on an account line, Exclude from scans or Include in scans, or Forget for an
  account that is not found.

## Distribution on GitHub (2026-11-11)

Cloudpane 1.0 was first prepared for the Mac App Store. It is released on GitHub instead, as
a Developer ID signed and notarized app with the same sandbox and the same four
entitlements.

- No App Store build exists, so shipped strings say what Cloudpane does, not what an "App
  Store version" does. The reason shown for Mail and Messages is now "Reading it needs Full
  Disk Access, which Cloudpane does not request."
- Nothing else in the package changes. It still makes no network connections and still never
  asks for Full Disk Access.
