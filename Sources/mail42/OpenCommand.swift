// OpenCommand.swift — `mail42 open <id>`: show a message in Mail.app.
//
// Mail registers the `message:` URL scheme, so this opens `message://%3C<Message-ID>%3E`: no Apple Events, no
// extra permission, nothing written. It is the hand-off from reading to acting (replying, archiving…), which
// mail42 itself never does. `MAIL42_OPEN_DRY_RUN=1` prints the URL instead of opening it (used by tests, which
// must not launch Mail).

import Foundation
import Mail42AppleMail
import Mail42Kit

enum OpenCommand {

    static func run(args: [String]) {
        let json = CLI.wantsJSON(args)
        let id = CLI.messageID(CLI.positionals(args).first, json: json)
        do {
            guard let record = try LiveMail.open().envelopeRecord(id: id) else {
                throw Mail42Error.notFound("message \(id)")
            }
            guard let messageID = record.row.messageID, let url = MailURL.messageURL(messageID: messageID) else {
                throw Mail42Error.noMessageID(id)
            }

            let dryRun = ProcessInfo.processInfo.environment["MAIL42_OPEN_DRY_RUN"] == "1"
            if !dryRun {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = [url.absoluteString]
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    CLI.fail(code: "open_failed", message: "couldn't open the message in Mail (open exited \(process.terminationStatus))",
                             exit: 1, json: json)
                }
            }
            if json {
                CLI.emitJSONObject(["url": url.absoluteString, "opened": !dryRun] as [String: Any])
            } else {
                print(dryRun ? url.absoluteString : "Opened message \(id) in Mail.")
            }
        } catch {
            CLI.fail(error: error, json: json)
        }
    }
}
