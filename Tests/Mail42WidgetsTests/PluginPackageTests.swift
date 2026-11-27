// PluginPackageTests.swift — the plugin as a package (WOR-900): no CLI and no daemon behind it any more. These read the manifest, the
// widget's declaration, the skill and the extension's sources from the repository, and run the model's choices that cannot be a
// compile error: which transport a Mac gets, and what a tile with nothing to read mail with says.

import Foundation
import Testing
import Work42PluginKit
@testable import Mail42MailWidget

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let pluginFolder = repository.appendingPathComponent("work42-plugin", isDirectory: true)
private let sourcesFolder = pluginFolder.appendingPathComponent("extension/Sources", isDirectory: true)

private func text(_ relativePath: String) throws -> String {
    try String(contentsOf: pluginFolder.appendingPathComponent(relativePath), encoding: .utf8)
}

/// Every `.swift` file of the extension, with its text.
private func extensionSources() throws -> [(name: String, text: String)] {
    let names = try FileManager.default.contentsOfDirectory(atPath: sourcesFolder.path).filter { $0.hasSuffix(".swift") }.sorted()
    return try names.map { ($0, try String(contentsOf: sourcesFolder.appendingPathComponent($0), encoding: .utf8)) }
}

/// The top-level keys of a manifest (`name:`, `permissions:` …), without a YAML parser: the manifest is a flat file.
private func topLevelKeys(_ manifest: String) -> Set<String> {
    Set(manifest.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line -> String? in
        guard let first = line.first, first.isLetter, let colon = line.firstIndex(of: ":") else { return nil }
        return String(line[..<colon])
    })
}

/// The `permissions:` entries as (name, target).
private func permissions(_ manifest: String) -> [(name: String, target: String?)] {
    var found: [(name: String, target: String?)] = []
    var inside = false
    for line in manifest.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.first?.isLetter == true { inside = line.hasPrefix("permissions:"); continue }
        guard inside else { continue }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- name:") {
            found.append((trimmed.dropFirst("- name:".count).trimmingCharacters(in: .whitespaces), nil))
        } else if trimmed.hasPrefix("target:"), !found.isEmpty {
            found[found.count - 1].target = trimmed.dropFirst("target:".count).trimmingCharacters(in: .whitespaces)
        }
    }
    return found
}

// MARK: - A session's services (the model only hands them to the direct transport)

private struct PackageComposer: WidgetComposerService {
    nonisolated func insert(text: String) async throws {}
    nonisolated func attach(sourceLabel: String, excerpt: String, body: String) async throws {}
    nonisolated func clearCommentableSelection() async throws {}
}

private struct PackageShell: WidgetShellService {
    nonisolated func run(command: String) async throws -> WidgetShellResult { WidgetShellResult(stdout: "", stderr: "", exitCode: 0) }
}

private struct PackageIntents: WidgetIntentsService {
    nonisolated func execute(id: String, params: [String: WidgetJSONValue]) async throws {}
}

private struct PackageStorage: WidgetStorageService {
    nonisolated func get(namespace: String, key: String) async throws -> WidgetJSONValue? { nil }
    nonisolated func list(namespace: String) async throws -> [String: WidgetJSONValue] { [:] }
    nonisolated func set(key: String, value: WidgetJSONValue) async throws {}
    nonisolated func delete(key: String) async throws {}
}

private struct PackagePill: WidgetPillService {
    nonisolated func present(widgetId: String, sessionId: String) async throws {}
    nonisolated func dismiss(widgetId: String) async throws {}
    nonisolated func isPresented(widgetId: String) async throws -> Bool { false }
}

@Suite("The plugin package: no CLI, no daemon (WOR-900)")
@MainActor
struct PluginPackageTests {

    // MARK: plugin.yaml

    @Test("plugin.yaml declares what is true now: SDK 3.5.0, Full Disk Access and Automation for Mail, no app group, no global skills")
    func manifest() throws {
        let manifest = try text("plugin.yaml")
        let keys = topLevelKeys(manifest)
        #expect(!keys.contains("global_skills"))
        #expect(!keys.contains("app_groups"))
        #expect(keys.isSuperset(of: ["name", "version", "description", "sdk_version", "runtime", "extension_bundle_id", "permissions"]))
        #expect(manifest.contains("sdk_version: 3.5.0"))
        #expect(manifest.contains("runtime: extension"))

        let declared = permissions(manifest)
        #expect(declared.contains { $0.name == "full-disk-access" && $0.target == nil })
        #expect(declared.contains { $0.name == "automation" && $0.target == "com.apple.mail" })
        #expect(Set(declared.map(\.name)).count == declared.count, "each permission once")
        #expect(manifest.contains("~/.work42/mail42"))
        #expect(!manifest.contains("mail42-setup") && !manifest.contains("mail42-cli"))
        #expect(!manifest.contains("github.com/Work42-Ai/mail42"), "the description must not send people to the CLI")
    }

    @Test("`run-commands` is declared exactly when the extension still starts a command (Quick Look's qlmanage), and for nothing else")
    func runCommandsMatchesShellUse() throws {
        let declared = permissions(try text("plugin.yaml")).map(\.name).contains("run-commands")
        let shellCalls = ["shell.start(", "shell.run(", "services?.shell", "services.shell"]
        var users: [String] = []
        for source in try extensionSources() where shellCalls.contains(where: source.text.contains) { users.append(source.name) }
        #expect(declared == !users.isEmpty, "run-commands declared: \(declared); files that run a command: \(users)")
        #expect(users.allSatisfy { $0 == "MailModel.swift" }, "only the Quick Look preview runs a command: \(users)")
        let model = try #require(try extensionSources().first { $0.name == "MailModel.swift" }?.text)
        #expect(!users.isEmpty ? model.contains("qlmanage -p") : true)
    }

    // MARK: The widget, its MCP and its skill

    @Test("widgets/mail/widget.yaml declares the `mail` MCP (served by the extension) and the `mail` skill")
    func widgetDeclaration() throws {
        let widget = try text("widgets/mail/widget.yaml")
        #expect(widget.contains("id: mail\n"))
        #expect(widget.contains("mcps:"))
        #expect(widget.contains("  - id: mail\n"))
        #expect(widget.contains("source: extension"))
        #expect(widget.contains("skills: [mail]"))
    }

    @Test("skills/mail/SKILL.md exists, is named `mail`, and mentions every tool the `mail` MCP declares")
    func skillCoversEveryTool() throws {
        let skill = try text("skills/mail/SKILL.md")
        #expect(skill.hasPrefix("---\nname: mail\ndescription: "))
        let toolIDs = MailTools.mcp(sessions: .shared).tools.map(\.id)
        #expect(toolIDs.count >= 15)
        for id in toolIDs { #expect(skill.contains("`\(id)`"), "the skill never mentions the tool \(id)") }
        for needed in ["mail42://", "from:", "is:unread", "date:2w..", "in:", "not", "body:", "~/.work42/mail42/attachments",
                       "Full Disk Access", "Automation", "delete_message", "junk_message", "read_thread"] {
            #expect(skill.contains(needed), "the skill should say `\(needed)`")
        }
        #expect(skill.lowercased().contains("ask before"))
    }

    @Test("the old skills are gone and nothing in the plugin sends an agent to the CLI or to mail42-setup")
    func noCLISkills() throws {
        let skills = try FileManager.default.contentsOfDirectory(atPath: pluginFolder.appendingPathComponent("skills").path).sorted()
        #expect(skills == ["mail"])
        for file in ["skills/mail/SKILL.md", "widgets/mail/SKILL.md", "widgets/mail/widget.yaml", "plugin.yaml"] {
            let body = try text(file)
            for banned in ["mail42-setup", "mail42-cli", "command -v mail42", "mail42 envelope", "mail42 message", "mail42 permissions"] {
                #expect(!body.contains(banned), "\(file) still says `\(banned)`")
            }
        }
    }

    // MARK: Sources

    @Test("no extension source still mentions the daemon, its client, the shell transport or a command check")
    func sourcesAreFreeOfTheCLIPlumbing() throws {
        let banned = ["mail42 serve", "startDaemon", "MailServeClient", "MailShellTransport", "MailFallbackTransport", "command -v",
                      "notInstalled", "not_installed"]
        let sources = try extensionSources()
        #expect(sources.count > 20)
        for source in sources {
            for word in banned { #expect(!source.text.contains(word), "\(source.name) still contains `\(word)`") }
        }
        for gone in ["MailServeClient.swift", "MailFallbackTransport.swift"] {
            #expect(!FileManager.default.fileExists(atPath: sourcesFolder.appendingPathComponent(gone).path))
        }
    }

    // MARK: The model

    #if os(macOS)
    @Test("on the Mac a tile with services reads in this process, and one with none has an unavailable transport that says Work 42")
    func macTransportChoice() async throws {
        let services = SessionServices(
            composer: PackageComposer(), shell: PackageShell(), intents: PackageIntents(), storage: PackageStorage(), pill: PackagePill(),
            sessionId: "package")
        #expect(MailModel.defaultTransport(services: services) is MailCtlDirectTransport)

        let none = MailModel.defaultTransport(services: nil)
        #expect(none is MailUnavailableTransport)
        do {
            _ = try await none.run(["mailbox", "list", "--json"])
            Issue.record("an unavailable transport must fail")
        } catch let failure as MailFailure {
            #expect(failure.code == MailUnavailableTransport.code)
            #expect(failure.message.contains("Work 42"))
        }
    }
    #endif

    @Test("a model with nothing to read mail with says so on the tile (failed, naming Work 42) and does not wait for access")
    func unavailableState() async {
        let model = MailModel(makeTransport: { _ in MailUnavailableTransport() })
        await model.bootstrap()
        guard case .failed(let message) = model.state else { Issue.record("expected .failed, got \(model.state)"); return }
        #expect(message.contains("Work 42"))
        #expect(!message.lowercased().contains("install"))
    }

    @Test("a `permissions` answer of denied shows the setup, noMailData shows no mail, and a failure shows its reason (never 'not installed')")
    func accessStates() async {
        let denied = MailModel(makeTransport: { _ in PermissionsTransport(state: "denied") })
        await denied.bootstrap()
        #expect(denied.state == .needsAccess)

        let empty = MailModel(makeTransport: { _ in PermissionsTransport(state: "noMailData") })
        await empty.bootstrap()
        #expect(empty.state == .noMail)

        let reason = MailModel(makeTransport: { _ in
            FailingTransport(MailFailure(code: "mac_unreachable", message: "Your Mac didn\u{2019}t answer."))
        })
        await reason.bootstrap()
        #expect(reason.state == .failed("Your Mac didn\u{2019}t answer."))
    }
}

/// A transport whose `permissions` answer is `state` (exit 1, as a refusal is).
private nonisolated struct PermissionsTransport: MailTransport {
    let state: String
    func run(_ arguments: [String]) async throws -> MailCLIResult {
        MailCLIResult(status: 1, stdout: Data("{\"fullDiskAccess\":\"\(state)\"}".utf8), stderr: "")
    }
    func changes() -> AsyncStream<String> { AsyncStream { $0.finish() } }
    func close() {}
}
