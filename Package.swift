// swift-tools-version: 6.0
import PackageDescription

// CloudpaneCore is the UI-free engine behind Cloudpane: provider detection, the read-only
// scanner, the SQLite inventory and export.
//
// Rule: system frameworks only (Foundation, Darwin, SQLite3, UniformTypeIdentifiers,
// CoreServices for FSEvents, CryptoKit for SHA-256). No
// AppKit, no SwiftUI, no SPM dependencies, nothing that touches the network. Adding a
// dependency needs sign-off; see DECISIONS.md.
let package = Package(
    name: "CloudpaneCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "CloudpaneCore", targets: ["CloudpaneCore"]),
        .executable(name: "cloudpane-scan", targets: ["cloudpane-scan"])
    ],
    targets: [
        .target(
            name: "CloudpaneCore",
            // Bundled data, updated with releases: the price catalog and provider facts.
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                // import SQLite3 does not imply the link in every toolchain configuration.
                .linkedLibrary("sqlite3"),
                // FSEvents, for the change watcher. A system framework with no user interface.
                .linkedFramework("CoreServices"),
                // SHA-256 for opt-in hashing. A system framework.
                .linkedFramework("CryptoKit")
            ]
        ),
        .executableTarget(
            name: "cloudpane-scan",
            dependencies: ["CloudpaneCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "CloudpaneCoreTests",
            dependencies: ["CloudpaneCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
