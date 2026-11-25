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

//
// The Mail widget (work42-plugin/extension/Sources) is ALSO built here, as the `Mail42Widgets` library the Work42
// iPad app links (macOS 15, iOS 26). The plugin's extension compiles on its own from that folder against the app's SDK
// frameworks, so it stays the single source of the widget: it is one SwiftPM target (`Mail42MailWidget`) built from the
// same files, minus `Extension.swift` (the extension's `@main`, which needs ExtensionKit), and `Sources/Mail42Widgets`
// maps a widget id to its view.

import Foundation
import PackageDescription

// The public SDK is two independent packages. `WORK42_SDK_PATH` selects another checkout; otherwise the sibling
// `work42-sdk` next to this repository is used. A standalone clone, or a release build of the CLI, has no SDK checkout:
// then only the CLI targets exist and nothing new is resolved.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let work42SDKRoot = ProcessInfo.processInfo.environment["WORK42_SDK_PATH"]
    .flatMap { $0.isEmpty ? nil : $0 }
    ?? "\(packageRoot)/../work42-sdk"
let hasSDK = FileManager.default.fileExists(atPath: "\(work42SDKRoot)/Work42PluginKit/Package.swift")
    && FileManager.default.fileExists(atPath: "\(work42SDKRoot)/Work42UI/Package.swift")

// Exactly what `work42 plugin build` passes swiftc, so a widget means the same thing in both builds.
let widgetSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .defaultIsolation(MainActor.self),
]

let sdkDependencies: [Target.Dependency] = [
    .product(name: "Work42UI", package: "Work42UI"),
    .product(name: "Work42PluginKit", package: "Work42PluginKit"),
]

var products: [Product] = [
    .library(name: "Mail42Kit", targets: ["Mail42Kit"]),
    .library(name: "Mail42AppleMail", targets: ["Mail42AppleMail"]),
    .library(name: "Mail42Actions", targets: ["Mail42Actions"]),
    .executable(name: "mail42", targets: ["mail42"]),
]

var dependencies: [Package.Dependency] = []

var targets: [Target] = [
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

if hasSDK {
    products.append(.library(name: "Mail42Widgets", targets: ["Mail42Widgets"]))
    dependencies += [
        .package(name: "Work42UI", path: "\(work42SDKRoot)/Work42UI"),
        .package(name: "Work42PluginKit", path: "\(work42SDKRoot)/Work42PluginKit"),
    ]
    targets.append(.target(
        name: "Mail42MailWidget",
        dependencies: sdkDependencies,
        path: "work42-plugin/extension/Sources",
        exclude: ["Extension.swift"],
        swiftSettings: widgetSettings
    ))
    // Mail42Widgets: widget id -> root view, the one entry point the iPad app (and anything else that hosts the widget
    // without the plugin loader) calls.
    targets.append(.target(
        name: "Mail42Widgets",
        dependencies: sdkDependencies + [.target(name: "Mail42MailWidget")],
        path: "Sources/Mail42Widgets",
        swiftSettings: widgetSettings
    ))
    targets.append(.testTarget(
        name: "Mail42WidgetsTests",
        dependencies: ["Mail42Widgets", .target(name: "Mail42MailWidget")] + sdkDependencies,
        path: "Tests/Mail42WidgetsTests",
        swiftSettings: widgetSettings
    ))
}

let package = Package(
    name: "mail42",
    platforms: [.macOS(.v15), .iOS(.v26)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
