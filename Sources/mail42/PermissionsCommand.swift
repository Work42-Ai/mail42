// PermissionsCommand.swift — `mail42 permissions [--json]` and `mail42 permissions open`.
//
// Full Disk Access is the one macOS permission mail42 needs. There is no API to request it: the user turns it
// on in System Settings. `permissions` reports whether it is in effect (exit 0 when granted); `permissions open`
// jumps to the right System Settings pane.

import Foundation
import Mail42Actions
import Mail42AppleMail
import Mail42Kit

enum PermissionsCommand {

    /// The Privacy & Security → Full Disk Access pane.
    static let settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

    private struct Report: Encodable {
        let fullDiskAccess: String
        let mailRoot: String?

        // Always write `mailRoot`, as null when unknown, so agents can rely on the key being there.
        enum CodingKeys: String, CodingKey { case fullDiskAccess, mailRoot }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(fullDiskAccess, forKey: .fullDiskAccess)
            try container.encode(mailRoot, forKey: .mailRoot)
        }
    }

    static func run(args: [String]) {
        switch CLI.firstPositional(args) {
        case nil:
            check(args: args)
        case "open":
            openSettings()
        case "automation":
            automation(args: args)
        case let other?:
            CLI.fail(code: "usage", message: "unknown permissions subcommand `\(other)` (try `permissions` or `permissions open`)",
                     exit: 2, json: CLI.wantsJSON(args))
        }
    }

    private static func check(args: [String]) {
        // Re-launch as mail42's own permission principal, so the answer is about the Full Disk Access grant of
        // mail42.app, not of the Terminal or Work42 that started it.
        Mail42Daemon.reexecIfNeeded(arguments: ["permissions"] + args)

        let state = AppleMailAccess.fullDiskAccess()
        let root = Mail42Paths.appleMailRoot()?.path

        if CLI.wantsJSON(args) {
            CLI.emitJSON(Report(fullDiskAccess: state.rawValue, mailRoot: root))
        } else {
            switch state {
            case .granted:
                print("Full Disk Access: granted")
                if let root { print("Apple Mail data: \(root)") }
            case .denied:
                print("Full Disk Access: denied")
                print("Run `mail42 permissions open`, turn on mail42, then run this again.")
            case .noMailData:
                print("Full Disk Access: unknown (no Apple Mail data found in ~/Library/Mail)")
                print("Mail may not be set up on this Mac.")
            }
        }
        exit(state == .granted ? 0 : 1)
    }

    /// `permissions automation`: whether mail42 may control Mail (needed by mark, move, archive, delete, junk and
    /// drafts). The first run makes macOS ask; answer Allow. Exit 0 when allowed.
    private static func automation(args: [String]) {
        let json = CLI.wantsJSON(args)
        Mail42Daemon.reexecIfNeeded(arguments: ["permissions"] + args)
        // `--check` only reports the state (it never shows the prompt); otherwise macOS asks if it hasn't been asked.
        let askUser = !args.contains("--check")
        let state = AutomationPermission.state(askUser: askUser)
        if args.contains("--state") || args.contains("--check") {
            let name: String
            switch state {
            case .granted: name = "granted"
            case .denied: name = "denied"
            case .notDetermined: name = "not_determined"
            case .mailNotRunning: name = "mail_not_running"
            case .other(let code): name = "status_\(code)"
            }
            if json { CLI.emitJSONObject(["automation": name] as [String: Any]) } else { print("Automation: \(name)") }
            exit(state == .granted ? 0 : 1)
        }
        do {
            let accounts = try MailActions().probe()
            if json {
                CLI.emitJSONObject(["automation": "granted", "mail_accounts": accounts] as [String: Any])
            } else {
                print("Automation: granted (Mail answered; it has \(accounts) accounts)")
            }
        } catch Mail42Error.automationDenied {
            if json { CLI.emitJSONObject(["automation": "denied"] as [String: Any]) } else {
                print("Automation: denied")
                print("Open System Settings › Privacy & Security › Automation, turn on Mail under mail42, then run this again.")
            }
            exit(1)
        } catch Mail42Error.mailTimeout {
            if json { CLI.emitJSONObject(["automation": "no_answer"] as [String: Any]) } else {
                print("Automation: Mail didn't answer in two minutes. If macOS is asking whether mail42 may control Mail, answer Allow; then run this again.")
            }
            exit(1)
        } catch {
            CLI.fail(error: error, json: json)
        }
    }

    private static func openSettings() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [settingsURL]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            CLI.fail("mail42: couldn't open System Settings: \(error.localizedDescription)", code: 1)
        }
        guard process.terminationStatus == 0 else {
            CLI.fail("mail42: couldn't open System Settings (open exited \(process.terminationStatus))", code: 1)
        }
        print("Opened System Settings → Privacy & Security → Full Disk Access.")
        print("Turn on mail42 (press + and choose ~/.work42/mail42.app if it isn't listed), then run `mail42 permissions`.")
    }
}
