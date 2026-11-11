import Foundation

extension Inventory {
    // MARK: - Everything at once

    /// The user's scan choices, for building scan roots and filtering views.
    public func scanChoices() throws -> ScanChoices {
        ScanChoices(excludedRoots: try excludedRoots(), customProviders: try customProviders(),
                    forgottenRoots: try forgottenRoots())
    }

    // MARK: - Custom providers

    public func customProviders() throws -> [CustomProvider] {
        let statement = try db.prepare("SELECT id, name, folder_name FROM custom_providers ORDER BY name, id")
        var result: [CustomProvider] = []
        while try statement.step() {
            result.append(CustomProvider(id: statement.int64(0), name: statement.string(1) ?? "",
                                         folderName: statement.string(2)))
        }
        return result
    }

    /// Adds a custom provider or renames one (by id). A folder can carry one name.
    @discardableResult
    public func save(_ provider: CustomProvider) throws -> CustomProvider {
        let problems = provider.validationProblems()
        guard problems.isEmpty else { throw PlanError.invalid(problems) }
        var saved = provider
        saved.name = provider.name.trimmingCharacters(in: .whitespacesAndNewlines)
        // A lookalike name would show two providers as one in every list.
        let key = SearchKey.make(saved.name)
        if let builtIn = ProviderRule.defaultTable.first(where: { SearchKey.make($0.displayName) == key }) {
            throw PlanError.invalid(["\(builtIn.displayName) is a supported provider. Choose another name."])
        }
        if key == SearchKey.make(ScanRoot.unrecognizedProviderName) {
            throw PlanError.invalid(["Choose another name."])
        }
        if let other = try customProviders().first(where: { $0.id != saved.id && SearchKey.make($0.name) == key }) {
            throw PlanError.invalid(["There is already a provider named \(other.name)."])
        }
        if let folder = saved.folderName {
            let taken = try db.prepare("SELECT name FROM custom_providers WHERE folder_name = ? AND id IS NOT ?")
            taken.bind(1, folder)
            taken.bind(2, saved.id)
            if try taken.step() {
                throw PlanError.invalid(["\(folder) already has the name \(taken.string(0) ?? "")."])
            }
        }
        let statement: SQLiteStatement
        if let id = saved.id {
            statement = try db.prepare("UPDATE custom_providers SET name = ?, folder_name = ? WHERE id = ?")
            statement.bind(3, id)
        } else {
            statement = try db.prepare("INSERT INTO custom_providers (name, folder_name, created_at) VALUES (?, ?, ?)")
            statement.bind(3, Date())
        }
        statement.bind(1, saved.name)
        statement.bind(2, saved.folderName)
        try statement.step()
        if saved.id == nil { saved.id = db.lastInsertRowID }
        return saved
    }

    /// Deletes a custom provider and its plan. A named folder goes back to being an
    /// unrecognized folder at the next scan; past scans keep what they recorded.
    public func removeCustomProvider(id: Int64) throws {
        let providerID = CustomProvider(id: id, name: "").providerID
        try db.transaction {
            let plan = try db.prepare("DELETE FROM subscriptions WHERE provider = ?")
            plan.bind(1, providerID)
            try plan.step()
            let provider = try db.prepare("DELETE FROM custom_providers WHERE id = ?")
            provider.bind(1, id)
            try provider.step()
        }
    }

    // MARK: - Excluded accounts

    public func excludedRoots() throws -> Set<String> {
        try paths("SELECT path FROM excluded_roots")
    }

    /// Excludes an account root from scans, or includes it again.
    public func setExcluded(_ excluded: Bool, rootPath: String) throws {
        let path = canonicalPath(rootPath)
        let statement = try db.prepare(excluded
            ? "INSERT OR IGNORE INTO excluded_roots (path, excluded_at) VALUES (?, ?)"
            : "DELETE FROM excluded_roots WHERE path = ?")
        statement.bind(1, path)
        if excluded { statement.bind(2, Date()) }
        try statement.step()
    }

    // MARK: - Forgotten accounts

    public func forgottenRoots() throws -> Set<String> {
        try paths("SELECT path FROM forgotten_roots")
    }

    /// Hides a missing account until it is found again.
    public func forget(rootPath: String) throws {
        let statement = try db.prepare("INSERT OR IGNORE INTO forgotten_roots (path, forgotten_at) VALUES (?, ?)")
        statement.bind(1, canonicalPath(rootPath))
        statement.bind(2, Date())
        try statement.step()
    }

    /// Clears the forgotten mark of every account found on this Mac now, so it shows again
    /// by itself, and returns the paths still forgotten.
    @discardableResult
    public func reconcileForgotten(detectedRoots: Set<String>) throws -> Set<String> {
        let found = Set(detectedRoots.map(canonicalPath))
        for path in try forgottenRoots() where found.contains(path) {
            let statement = try db.prepare("DELETE FROM forgotten_roots WHERE path = ?")
            statement.bind(1, path)
            try statement.step()
        }
        return try forgottenRoots()
    }

    private func paths(_ sql: String) throws -> Set<String> {
        let statement = try db.prepare(sql)
        var result: Set<String> = []
        while try statement.step() { if let path = statement.string(0) { result.insert(path) } }
        return result
    }
}
