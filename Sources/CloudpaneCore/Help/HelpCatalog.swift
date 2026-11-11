import Foundation

/// The platforms a help topic or section is written for.
public enum HelpPlatform: String, Sendable, Hashable, CaseIterable, Codable {
    case macOS
    case iOS
}

/// One help page: its front matter and its Markdown body, already filtered for a platform.
public struct HelpTopic: Sendable, Hashable, Identifiable {
    /// The file name without ".md", such as "backup-grade". Links between topics use it.
    public let id: String
    public let title: String
    public let order: Int
    public let platforms: Set<HelpPlatform>
    public let summary: String
    /// Markdown, with sections for other platforms removed and the front matter stripped.
    public let body: String
}

/// A search hit: the topic, and a short excerpt around the first match in the text.
public struct HelpSearchResult: Sendable, Hashable, Identifiable {
    public let topic: HelpTopic
    /// Nil when only the title or summary matched.
    public let excerpt: String?
    public var id: String { topic.id }
}

public enum HelpCatalogError: Error, Equatable, CustomStringConvertible {
    case missingFrontMatter(String)
    case missingField(String, String)
    case badOrder(String, String)
    case unknownPlatform(String, String)
    case unclosedSection(String, String)

    public var description: String {
        switch self {
        case .missingFrontMatter(let file): return "\(file): no front matter between --- lines"
        case .missingField(let file, let field): return "\(file): front matter has no \(field)"
        case .badOrder(let file, let value): return "\(file): order \"\(value)\" is not a number"
        case .unknownPlatform(let file, let value): return "\(file): unknown platform \"\(value)\""
        case .unclosedSection(let file, let platform): return "\(file): <!-- \(platform) --> has no <!-- /\(platform) -->"
        }
    }
}

/// The help topics for one platform, read from Markdown files with front matter.
///
/// Each file starts with front matter:
///
///     ---
///     title: Backup grade
///     order: 5
///     platforms: macOS, iOS
///     summary: How Cloudpane grades each folder against the 3-2-1 rule.
///     ---
///
/// A section for one platform only sits between `<!-- macOS -->` and `<!-- /macOS -->` (or
/// the iOS pair) on lines of their own; the catalog drops it for other platforms. Links
/// between topics are relative Markdown links to the file, such as `[Providers](providers.md)`.
/// `README.md` in the folder documents the conventions and is not a topic.
///
/// Foundation only, so an iOS target can use the same files and the same catalog.
public struct HelpCatalog: Sendable {
    public let platform: HelpPlatform
    /// Topics for this platform, in order.
    public let topics: [HelpTopic]

    /// Reads every `.md` file in the bundle's `subdirectory`, except README.md.
    public init(bundle: Bundle, subdirectory: String = "help", platform: HelpPlatform) throws {
        let urls = bundle.urls(forResourcesWithExtension: "md", subdirectory: subdirectory) ?? []
        var files: [String: String] = [:]
        for url in urls {
            files[url.lastPathComponent] = try String(contentsOf: url, encoding: .utf8)
        }
        try self.init(files: files, platform: platform)
    }

    /// files maps a file name ("providers.md") to its text.
    public init(files: [String: String], platform: HelpPlatform) throws {
        self.platform = platform
        var topics: [HelpTopic] = []
        for (name, text) in files where name.lowercased() != "readme.md" {
            let topic = try HelpCatalog.parse(text, file: name, platform: platform)
            if topic.platforms.contains(platform) { topics.append(topic) }
        }
        self.topics = topics.sorted { ($0.order, $0.title) < ($1.order, $1.title) }
    }

    public func topic(id: String) -> HelpTopic? {
        topics.first { $0.id == id }
    }

    /// The topic a link points at: "providers.md", "providers.md#anchor", "./providers.md"
    /// or a bare id. Nil for anything else, such as a web address.
    public func topic(forLink link: String) -> HelpTopic? {
        guard let id = HelpCatalog.topicID(forLink: link) else { return nil }
        return topic(id: id)
    }

    /// Links in a topic's body that point at a topic, or a heading in one, that does not
    /// exist for this platform. A link to "#heading" points within the same topic.
    public func unresolvedLinks() -> [(topic: String, link: String)] {
        topics.flatMap { topic in
            HelpCatalog.links(in: topic.body)
                .filter { !resolves($0, from: topic) }
                .map { (topic.id, $0) }
        }
    }

    /// True when a link is not a topic link (a web address) or points at a topic, and at a
    /// heading in it when it has an anchor.
    public func resolves(_ link: String, from topic: HelpTopic? = nil) -> Bool {
        if link.hasPrefix("#") {
            guard let topic else { return false }
            return HelpCatalog.anchors(in: topic.body).contains(String(link.dropFirst()))
        }
        guard HelpCatalog.topicID(forLink: link) != nil else { return true }
        guard let target = self.topic(forLink: link) else { return false }
        guard let anchor = HelpCatalog.anchor(forLink: link) else { return true }
        return HelpCatalog.anchors(in: target.body).contains(anchor)
    }

    /// The anchor of a link, "plans" for "providers.md#plans", or nil.
    public static func anchor(forLink link: String) -> String? {
        let parts = link.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        return String(parts[1])
    }

    /// The anchor of a heading, as GitHub makes it: lowercase, letters, digits, spaces
    /// turned into hyphens, other punctuation dropped. "Adding a provider" is
    /// "adding-a-provider".
    public static func slug(_ heading: String) -> String {
        var slug = ""
        for character in heading.lowercased() {
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                slug.append(character)
            } else if character == " " {
                slug.append("-")
            }
        }
        return slug
    }

    /// The anchors of every heading in a Markdown body.
    public static func anchors(in markdown: String) -> Set<String> {
        Set(markdown.components(separatedBy: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { return nil }
            let text = trimmed.drop { $0 == "#" }
            guard text.hasPrefix(" ") else { return nil }
            return slug(text.trimmingCharacters(in: .whitespaces))
        })
    }

    /// Topics whose title, summary or text contain every word of the query, compared without
    /// case or diacritics. Title and summary matches come first, then text matches, each in
    /// topic order.
    public func search(_ query: String) -> [HelpSearchResult] {
        let words = query.split(whereSeparator: \.isWhitespace).map { HelpCatalog.fold(String($0)) }
        guard !words.isEmpty else { return [] }
        var heading: [HelpSearchResult] = []
        var text: [HelpSearchResult] = []
        for topic in topics {
            let head = HelpCatalog.fold(topic.title + " " + topic.summary)
            let plain = HelpCatalog.plainText(topic.body)
            let body = HelpCatalog.fold(plain)
            if words.allSatisfy({ head.contains($0) }) {
                heading.append(HelpSearchResult(topic: topic, excerpt: nil))
            } else if words.allSatisfy({ head.contains($0) || body.contains($0) }) {
                text.append(HelpSearchResult(topic: topic, excerpt: HelpCatalog.excerpt(plain, around: words)))
            }
        }
        return heading + text
    }

    // MARK: - Parsing

    static func parse(_ text: String, file: String, platform: HelpPlatform) throws -> HelpTopic {
        let id = file.hasSuffix(".md") ? String(file.dropLast(3)) : file
        var lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { throw HelpCatalogError.missingFrontMatter(file) }
        var fields: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        for field in ["title", "order", "platforms", "summary"] where (fields[field] ?? "").isEmpty {
            throw HelpCatalogError.missingField(file, field)
        }
        guard let order = Int(fields["order"]!) else { throw HelpCatalogError.badOrder(file, fields["order"]!) }
        var platforms: Set<HelpPlatform> = []
        for value in fields["platforms"]!.split(separator: ",") {
            let name = value.trimmingCharacters(in: .whitespaces)
            guard let platform = HelpPlatform(rawValue: name) else { throw HelpCatalogError.unknownPlatform(file, name) }
            platforms.insert(platform)
        }
        lines.removeSubrange(0...end)
        let body = try filter(lines, for: platform, file: file)
        return HelpTopic(id: id, title: fields["title"]!, order: order, platforms: platforms,
                         summary: fields["summary"]!, body: body)
    }

    /// Drops sections marked for other platforms and the marker lines themselves.
    static func filter(_ lines: [String], for platform: HelpPlatform, file: String) throws -> String {
        var kept: [String] = []
        var open: HelpPlatform?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marked = marker(trimmed, closing: false) {
                open = marked
                continue
            }
            if let marked = marker(trimmed, closing: true), marked == open {
                open = nil
                continue
            }
            if open == nil || open == platform { kept.append(line) }
        }
        if let open { throw HelpCatalogError.unclosedSection(file, open.rawValue) }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func marker(_ line: String, closing: Bool) -> HelpPlatform? {
        guard line.hasPrefix("<!--"), line.hasSuffix("-->") else { return nil }
        var inner = line.dropFirst(4).dropLast(3).trimmingCharacters(in: .whitespaces)
        if closing {
            guard inner.hasPrefix("/") else { return nil }
            inner.removeFirst()
        } else if inner.hasPrefix("/") {
            return nil
        }
        return HelpPlatform(rawValue: inner.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Links and text

    /// The targets of Markdown links, `[text](target)`, in order.
    static func links(in markdown: String) -> [String] {
        var result: [String] = []
        var rest = markdown[...]
        while let open = rest.range(of: "](") {
            let after = rest[open.upperBound...]
            guard let close = after.firstIndex(of: ")") else { break }
            result.append(String(after[..<close]))
            rest = after[close...]
        }
        return result
    }

    /// "providers.md#plans" or "./providers.md" is "providers". Anything with a scheme, or
    /// not ending in .md once the anchor is gone, is not a topic link.
    public static func topicID(forLink link: String) -> String? {
        if link.contains("://") || link.hasPrefix("mailto:") { return nil }
        var path = link.split(separator: "#", maxSplits: 1).first.map(String.init) ?? link
        if path.hasPrefix("./") { path.removeFirst(2) }
        guard path.hasSuffix(".md"), !path.contains("/") else { return nil }
        return String(path.dropLast(3))
    }

    /// Markdown reduced to words: link targets, markers and table rules removed.
    static func plainText(_ markdown: String) -> String {
        var text = markdown
        // [label](target) keeps the label.
        while let open = text.range(of: "]("), let close = text[open.upperBound...].firstIndex(of: ")") {
            text.removeSubrange(open.lowerBound...close)
        }
        for mark in ["[", "#", "*", "`", "|", "---"] { text = text.replacingOccurrences(of: mark, with: " ") }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// About 140 characters around the first word that matches, starting and ending on
    /// whole words.
    static func excerpt(_ plain: String, around words: [String]) -> String? {
        let folded = fold(plain)
        guard folded.count == plain.count else { return String(plain.prefix(140)) }
        guard let hit = words.compactMap({ folded.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) else {
            return nil
        }
        let offset = folded.distance(from: folded.startIndex, to: hit.lowerBound)
        var start = plain.index(plain.startIndex, offsetBy: max(offset - 50, 0))
        var end = plain.index(start, offsetBy: min(140, plain.distance(from: start, to: plain.endIndex)))
        // Move the start forward to the next word, and the end back to the last whole one.
        if start > plain.startIndex, plain[plain.index(before: start)] != " " {
            start = plain[start...].firstIndex(of: " ").map { plain.index(after: $0) } ?? start
        }
        if end < plain.endIndex, plain[end] != " ", let space = plain[start..<end].lastIndex(of: " ") {
            end = space
        }
        var excerpt = String(plain[start..<end]).trimmingCharacters(in: .whitespaces)
        if start > plain.startIndex { excerpt = "…" + excerpt }
        if end < plain.endIndex { excerpt += "…" }
        return excerpt
    }
}
