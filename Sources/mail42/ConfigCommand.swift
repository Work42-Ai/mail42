// ConfigCommand.swift — `mail42 config get [window_days]` and `mail42 config set window_days <N>`.
//
// The only setting today is how many days of mail to index (default 90, 0 = all). It lives in mail.db's
// sync_state and takes effect at the next sync. This verb doesn't read Apple Mail, so it needs no permission.

import Foundation
import Mail42Kit

enum ConfigCommand {

    private static let knownKeys = ["window_days"]

    static func run(args: [String]) {
        let json = CLI.wantsJSON(args)
        let words = CLI.positionals(args)
        guard let action = words.first else { usage("missing action", json: json) }

        let store: MailStore
        do { store = try MailStore() } catch { CLI.fail(error: error, json: json) }

        switch action {
        case "get":
            let key = words.dropFirst().first
            if let key, !knownKeys.contains(key) { usage("unknown setting `\(key)`", json: json) }
            do {
                let days = try store.windowDays()
                if json {
                    CLI.emitJSON(["window_days": days])
                } else if key != nil {
                    print(days)
                } else {
                    print("window_days=\(days)")
                }
            } catch {
                CLI.fail(error: error, json: json)
            }

        case "set":
            guard words.count >= 3 else { usage("usage: config set window_days <N>", json: json) }
            guard words[1] == "window_days" else { usage("unknown setting `\(words[1])`", json: json) }
            guard let days = Int(words[2]), days >= 0 else {
                usage("window_days must be a whole number of days, 0 or more (0 = all mail)", json: json)
            }
            do {
                try store.setState(MailStore.StateKey.windowDays, String(days))
                if json {
                    CLI.emitJSON(["window_days": days])
                } else {
                    print("window_days set to \(days) (\(days == 0 ? "all mail" : "\(days) days")); it applies at the next sync")
                }
            } catch {
                CLI.fail(error: error, json: json)
            }

        default:
            usage("unknown action `\(action)` (try `config get` or `config set`)", json: json)
        }
    }

    private static func usage(_ message: String, json: Bool) -> Never {
        CLI.fail(code: "usage", message: message, exit: 2, json: json)
    }
}
