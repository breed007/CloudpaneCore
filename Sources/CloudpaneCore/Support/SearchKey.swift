import Foundation

/// The comparison form of a name or path: Unicode NFC, then case-folded beyond ASCII.
///
/// APFS keeps names in whatever normalization they were created with, so "résumé" can be
/// stored decomposed (e followed by a combining accent) while a user types it precomposed.
/// Both sides of every search, and every path-containment check, go through this form.
/// Diacritics stay significant: "resume" does not match "résumé".
enum SearchKey {
    static func make(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: nil)
            .precomposedStringWithCanonicalMapping
    }
}
