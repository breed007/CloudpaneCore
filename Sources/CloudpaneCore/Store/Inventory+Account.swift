import Foundation

/// The Photos library the user chose, with its read-only bookmark and the last estimate.
public struct PhotosLibraryRecord: Sendable, Hashable {
    public let path: String
    public let bookmark: Data
    /// Nil until the library has been measured.
    public let estimate: PhotosLibraryEstimate?

    public init(path: String, bookmark: Data, estimate: PhotosLibraryEstimate?) {
        self.path = path
        self.bookmark = bookmark
        self.estimate = estimate
    }
}

extension Inventory {
    // MARK: - Totals the user entered

    public func reportedUsage() throws -> [String: ReportedUsage] {
        let statement = try db.prepare("SELECT provider, bytes, entered_at FROM reported_usage")
        var result: [String: ReportedUsage] = [:]
        while try statement.step() {
            let provider = statement.string(0) ?? ""
            result[provider] = ReportedUsage(provider: provider, bytes: statement.int64(1),
                                             enteredAt: statement.dateOrNil(2) ?? Date())
        }
        return result
    }

    /// Saves the total for the provider, replacing any earlier one.
    public func setReportedUsage(_ usage: ReportedUsage) throws {
        let problems = ReportedUsage.validationProblems(bytes: usage.bytes)
        guard problems.isEmpty else { throw PlanError.invalid(problems) }
        let statement = try db.prepare("""
            INSERT INTO reported_usage (provider, bytes, entered_at) VALUES (?, ?, ?)
            ON CONFLICT (provider) DO UPDATE SET bytes = excluded.bytes, entered_at = excluded.entered_at
            """)
        statement.bind(1, usage.provider)
        statement.bind(2, usage.bytes)
        statement.bind(3, usage.enteredAt)
        try statement.step()
    }

    public func clearReportedUsage(provider: String) throws {
        let statement = try db.prepare("DELETE FROM reported_usage WHERE provider = ?")
        statement.bind(1, provider)
        try statement.step()
    }

    // MARK: - Photos library

    public func photosLibrary() throws -> PhotosLibraryRecord? {
        let statement = try db.prepare("""
            SELECT path, bookmark, logical_bytes, allocated_bytes, file_count, dataless_count,
                unreadable_count, measured_at
            FROM photos_library WHERE id = 1
            """)
        guard try statement.step() else { return nil }
        let s = statement
        var estimate: PhotosLibraryEstimate?
        if let logical = s.int64OrNil(2), let measured = s.dateOrNil(7) {
            estimate = PhotosLibraryEstimate(logicalBytes: logical, allocatedBytes: s.int64OrNil(3) ?? 0,
                                             fileCount: s.int(4), datalessCount: s.int(5),
                                             unreadableCount: s.int(6), measuredAt: measured)
        }
        return PhotosLibraryRecord(path: s.string(0) ?? "", bookmark: s.data(1) ?? Data(), estimate: estimate)
    }

    /// Records the library the user chose. Choosing a different library drops the old
    /// estimate; choosing the same one again keeps it until it is measured again.
    public func setPhotosLibrary(path: String, bookmark: Data) throws {
        let statement = try db.prepare("""
            INSERT INTO photos_library (id, path, bookmark) VALUES (1, ?, ?)
            ON CONFLICT (id) DO UPDATE SET bookmark = excluded.bookmark, path = excluded.path,
                logical_bytes = CASE WHEN path = excluded.path THEN logical_bytes END,
                allocated_bytes = CASE WHEN path = excluded.path THEN allocated_bytes END,
                file_count = CASE WHEN path = excluded.path THEN file_count END,
                dataless_count = CASE WHEN path = excluded.path THEN dataless_count END,
                unreadable_count = CASE WHEN path = excluded.path THEN unreadable_count END,
                measured_at = CASE WHEN path = excluded.path THEN measured_at END
            """)
        statement.bind(1, path)
        statement.bind(2, bookmark)
        try statement.step()
    }

    /// Stores an estimate for the chosen library. Does nothing when no library is chosen.
    public func recordPhotosEstimate(_ estimate: PhotosLibraryEstimate) throws {
        let statement = try db.prepare("""
            UPDATE photos_library SET logical_bytes = ?, allocated_bytes = ?, file_count = ?,
                dataless_count = ?, unreadable_count = ?, measured_at = ? WHERE id = 1
            """)
        statement.bind(1, estimate.logicalBytes)
        statement.bind(2, estimate.allocatedBytes)
        statement.bind(3, estimate.fileCount)
        statement.bind(4, estimate.datalessCount)
        statement.bind(5, estimate.unreadableCount)
        statement.bind(6, estimate.measuredAt)
        try statement.step()
    }

    /// Forgets the library, its bookmark and its estimate.
    public func clearPhotosLibrary() throws {
        try db.execute("DELETE FROM photos_library")
    }

    /// iCloud as the Providers view shows it: Drive from the latest complete scan, the
    /// Photos estimate and the entered total.
    public func iCloudUsage() throws -> ICloudUsage {
        let drive = try usageHistory().last?.usedBytes[ProviderRule.iCloudDrive.id]
        return ICloudUsage(driveBytes: drive, photos: try photosLibrary()?.estimate,
                           reportedTotal: try reportedUsage()[ProviderRule.iCloudDrive.id])
    }
}
