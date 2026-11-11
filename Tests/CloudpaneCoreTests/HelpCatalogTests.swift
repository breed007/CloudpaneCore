import XCTest
@testable import CloudpaneCore

final class HelpCatalogTests: XCTestCase {
    private let files: [String: String] = [
        "README.md": "# Conventions\n\nNot a topic.",
        "grade.md": """
            ---
            title: Backup grade
            order: 2
            platforms: macOS, iOS
            summary: How each folder is graded.
            ---
            # Backup grade

            Sync is not backup. See [Providers](providers.md#plans) for plans.

            <!-- macOS -->
            Choose a backup location in Settings with the open panel.
            <!-- /macOS -->

            <!-- iOS -->
            Backups come from your Mac.
            <!-- /iOS -->

            A Time Machine copy counts once.
            """,
        "providers.md": """
            ---
            title: Providers
            order: 1
            platforms: macOS, iOS
            summary: Plans and accounts.
            ---
            # Providers

            Résumé of [the grade](./grade.md) and the [web](https://example.com/page.md).

            ## Plans

            One per provider.
            """,
        "shortcuts.md": """
            ---
            title: Keyboard shortcuts
            order: 9
            platforms: macOS
            summary: Keys for the Mac app.
            ---
            Press Command-R to scan. See [missing](nowhere.md).
            """,
    ]

    func testTopicsAreOrderedAndFilteredByPlatform() throws {
        let mac = try HelpCatalog(files: files, platform: .macOS)
        XCTAssertEqual(mac.topics.map(\.id), ["providers", "grade", "shortcuts"], "README is not a topic")
        XCTAssertTrue(mac.topic(id: "grade")!.body.contains("open panel"))
        XCTAssertFalse(mac.topic(id: "grade")!.body.contains("Backups come from your Mac"))
        XCTAssertFalse(mac.topic(id: "grade")!.body.contains("<!--"), "markers are removed")

        let iOS = try HelpCatalog(files: files, platform: .iOS)
        XCTAssertEqual(iOS.topics.map(\.id), ["providers", "grade"], "a Mac-only topic is dropped")
        let grade = try XCTUnwrap(iOS.topic(id: "grade"))
        XCTAssertFalse(grade.body.contains("open panel"), "a Mac-only section is dropped")
        XCTAssertTrue(grade.body.contains("Backups come from your Mac"))
        XCTAssertTrue(grade.body.contains("A Time Machine copy counts once."))
        XCTAssertEqual(grade.summary, "How each folder is graded.")
        XCTAssertEqual(grade.platforms, [.macOS, .iOS])
    }

    func testLinksResolveAndBrokenOnesAreReported() throws {
        let mac = try HelpCatalog(files: files, platform: .macOS)
        XCTAssertEqual(mac.topic(forLink: "providers.md#plans")?.id, "providers")
        XCTAssertEqual(mac.topic(forLink: "./grade.md")?.id, "grade")
        XCTAssertNil(mac.topic(forLink: "https://example.com/page.md"), "a web link is not a topic")
        let broken = mac.unresolvedLinks()
        XCTAssertEqual(broken.map(\.topic), ["shortcuts"])
        XCTAssertEqual(broken.map(\.link), ["nowhere.md"])
    }

    func testAnchorsResolveToHeadings() throws {
        var withAnchors = files
        withAnchors["shortcuts.md"] = """
            ---
            title: Keyboard shortcuts
            order: 9
            platforms: macOS
            summary: Keys.
            ---
            # Keyboard shortcuts

            ## Adding a provider, quickly

            See [above](#adding-a-provider-quickly), [grade](grade.md#sync-is-not-backup) and [bad](grade.md#nowhere).
            """
        withAnchors["grade.md"] = withAnchors["grade.md"]! + "\n\n## Sync is not backup\n\nText."
        let mac = try HelpCatalog(files: withAnchors, platform: .macOS)
        XCTAssertEqual(HelpCatalog.slug("Adding a provider, quickly"), "adding-a-provider-quickly")
        XCTAssertEqual(HelpCatalog.slug("3-2-1 and you"), "3-2-1-and-you")
        XCTAssertTrue(HelpCatalog.anchors(in: mac.topic(id: "grade")!.body).contains("sync-is-not-backup"))
        XCTAssertEqual(HelpCatalog.anchor(forLink: "grade.md#sync-is-not-backup"), "sync-is-not-backup")
        XCTAssertTrue(mac.resolves("grade.md#sync-is-not-backup"))
        XCTAssertFalse(mac.resolves("grade.md#nowhere"))
        XCTAssertEqual(mac.unresolvedLinks().map(\.link), ["grade.md#nowhere"],
                       "an anchor within the page and a good anchor elsewhere resolve; a missing heading does not")
    }

    func testExcerptsStartAndEndOnWholeWords() throws {
        let long = (1...60).map { "word\($0)" }.joined(separator: " ")
        let text = "---\ntitle: T\norder: 1\nplatforms: macOS\nsummary: S\n---\n# T\n\n\(long) needle \(long)"
        let catalog = try HelpCatalog(files: ["t.md": text], platform: .macOS)
        let excerpt = try XCTUnwrap(catalog.search("needle").first?.excerpt)
        XCTAssertTrue(excerpt.hasPrefix("…word"), excerpt)
        XCTAssertTrue(excerpt.contains("needle"))
        let words = excerpt.trimmingCharacters(in: CharacterSet(charactersIn: "…")).split(separator: " ")
        for word in words where word != "needle" {
            XCTAssertTrue(word.hasPrefix("word") && word.count > 4, "\(word) is cut")
        }
    }

    func testSearchMatchesTitlesFirstAndIgnoresCaseAndAccents() throws {
        let mac = try HelpCatalog(files: files, platform: .macOS)
        XCTAssertEqual(mac.search("providers").map(\.id), ["providers", "grade"],
                       "the title match first, then the topic that mentions it")
        let accent = mac.search("resume")
        XCTAssertEqual(accent.map(\.id), ["providers"])
        XCTAssertTrue(accent.first?.excerpt?.contains("Résumé") == true)
        XCTAssertEqual(mac.search("time machine").map(\.id), ["grade"], "every word must match")
        XCTAssertTrue(mac.search("   ").isEmpty)
        XCTAssertTrue(mac.search("example.com").isEmpty, "link targets are not searched")
    }

    func testBadFrontMatterIsReported() {
        XCTAssertThrowsError(try HelpCatalog(files: ["a.md": "# No front matter"], platform: .macOS)) {
            XCTAssertEqual($0 as? HelpCatalogError, .missingFrontMatter("a.md"))
        }
        let noSummary = "---\ntitle: A\norder: 1\nplatforms: macOS\n---\nText"
        XCTAssertThrowsError(try HelpCatalog(files: ["a.md": noSummary], platform: .macOS)) {
            XCTAssertEqual($0 as? HelpCatalogError, .missingField("a.md", "summary"))
        }
        let badPlatform = "---\ntitle: A\norder: 1\nplatforms: watchOS\nsummary: S\n---\nText"
        XCTAssertThrowsError(try HelpCatalog(files: ["a.md": badPlatform], platform: .macOS)) {
            XCTAssertEqual($0 as? HelpCatalogError, .unknownPlatform("a.md", "watchOS"))
        }
        let unclosed = "---\ntitle: A\norder: 1\nplatforms: macOS\nsummary: S\n---\n<!-- macOS -->\nText"
        XCTAssertThrowsError(try HelpCatalog(files: ["a.md": unclosed], platform: .iOS)) {
            XCTAssertEqual($0 as? HelpCatalogError, .unclosedSection("a.md", "macOS"))
        }
    }

    func testTheCatalogReadsABundle() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("help-bundle-\(UUID().uuidString)")
        let help = folder.appendingPathComponent("help")
        try FileManager.default.createDirectory(at: help, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (name, text) in files { try text.write(to: help.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let bundle = try XCTUnwrap(Bundle(path: folder.path))
        let catalog = try HelpCatalog(bundle: bundle, platform: .macOS)
        XCTAssertEqual(catalog.topics.count, 3)
    }
}
