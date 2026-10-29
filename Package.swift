// swift-tools-version: 6.2
//
// mail42 — the standalone macOS CLI that reads Apple Mail's local store, read-only, and exposes it to agents
// and the Work42 mail widget. It mirrors meet42's structure: a signed mail42.app (bundle id
// com.work42.mail42) owns Full Disk Access and ~/.work42/mail42/mail.db; the Work42 plugin in work42-plugin/
// talks to it only through the CLI.
//
// Mail42Kit        domain code: paths, the mail.db store (sqlite3), the query language, HTML sanitising.
// Mail42AppleMail  Apple Mail's local store: Envelope Index snapshot, .emlx / MIME parsing, sync.
// mail42           the CLI executable (hand-parsed verbs, no ArgumentParser).

import PackageDescription

let package = Package(
    name: "mail42",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Mail42Kit", targets: ["Mail42Kit"]),
        .library(name: "Mail42AppleMail", targets: ["Mail42AppleMail"]),
        .library(name: "Mail42Actions", targets: ["Mail42Actions"]),
        .executable(name: "mail42", targets: ["mail42"]),
    ],
    targets: [
        .target(
            name: "Mail42Kit",
            path: "Sources/Mail42Kit",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "Mail42AppleMail",
            dependencies: ["Mail42Kit"],
            path: "Sources/Mail42AppleMail"
        ),
        // What mail42 asks Apple Mail to do (mark, move, archive, delete, junk, drafts): Apple Events to Mail.app,
        // never a send. Knows nothing about how mail is read; it is handed a `MessageRef` and the mailbox paths.
        .target(
            name: "Mail42Actions",
            dependencies: ["Mail42Kit"],
            path: "Sources/Mail42Actions"
        ),
        .executableTarget(
            name: "mail42",
            dependencies: ["Mail42Kit", "Mail42AppleMail", "Mail42Actions"],
            path: "Sources/mail42"
        ),
        // Test-only helpers shared by both test targets: a builder for synthetic Envelope Index databases and
        // .emlx fixtures. Not a product; nothing outside the tests depends on it.
        .target(
            name: "Mail42TestSupport",
            dependencies: ["Mail42Kit"],
            path: "Tests/Mail42TestSupport"
        ),
        .testTarget(
            name: "Mail42KitTests",
            dependencies: ["Mail42Kit", "Mail42TestSupport"],
            path: "Tests/Mail42KitTests"
        ),
        .testTarget(
            name: "Mail42ActionsTests",
            dependencies: ["Mail42Actions", "Mail42Kit"],
            path: "Tests/Mail42ActionsTests"
        ),
        .testTarget(
            name: "Mail42AppleMailTests",
            // The `mail42` executable is a dependency so `swift test` always builds the binary the
            // end-to-end tests run; without it they would have nothing to execute.
            dependencies: ["Mail42AppleMail", "Mail42Kit", "Mail42TestSupport", "mail42"],
            path: "Tests/Mail42AppleMailTests"
        ),
    ]
)
