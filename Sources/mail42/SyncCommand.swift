// SyncCommand.swift — `mail42 sync [--full] [--json]`.
//
// Copies new, changed and removed mail from Apple Mail into ~/.work42/mail42/mail.db. The Work42 mail widget's
// background agent runs this every two minutes; agents can run it too. Exit 1 when mail42 can't read Apple Mail
// (Full Disk Access not granted, unsupported index), 2 for other errors.

import Foundation
import Mail42AppleMail
import Mail42Kit

enum SyncCommand {

    static func run(args: [String]) {
        // Re-launch as mail42's own permission principal first, so the Full Disk Access check is about
        // mail42.app and not whatever started it.
        Mail42Daemon.reexecIfNeeded(arguments: ["sync"] + args)

        let json = CLI.wantsJSON(args)
        do {
            let result = try MailSync().run(full: args.contains("--full"))
            if json {
                CLI.emitJSON(result)
            } else {
                print("Synced: +\(result.added) ~\(result.updated) -\(result.removed) in \(result.ms)ms")
            }
        } catch {
            CLI.fail(error: error, json: json)
        }
    }
}
