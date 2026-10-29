// MailboxCommand.swift — `mail42 mailbox list [--json]`: every account and its mailboxes, with counts.
// The counts are Apple Mail's own, read live.

import Foundation
import Mail42AppleMail
import Mail42Kit

enum MailboxCommand {

    static func run(args: [String]) {
        let json = CLI.wantsJSON(args)
        guard CLI.positionals(args).first == "list" else {
            CLI.usageError("usage: mailbox list [--json]", json: json)
        }
        do {
            let tree = try LiveMail.open().accountsWithMailboxes()
            if json {
                CLI.emitJSONObject(tree.map { entry in
                    [
                        "account": [
                            "id": entry.account.id, "name": entry.account.name,
                            "email": entry.account.email as Any? ?? NSNull(), "kind": entry.account.kind,
                        ],
                        "mailboxes": entry.mailboxes.map { m in
                            ["id": m.id, "name": m.name, "role": m.role, "total": m.total, "unread": m.unread] as [String: Any]
                        },
                    ] as [String: Any]
                })
                return
            }
            if tree.isEmpty {
                print("Apple Mail has no mailboxes yet. Add an account in Mail.")
                return
            }
            for entry in tree {
                print("\(entry.account.name)  (\(entry.account.kind))")
                for m in entry.mailboxes {
                    let unread = m.unread > 0 ? "\(m.unread) unread · " : ""
                    print("  " + Presentation.fit(String(m.id), 6) + Presentation.fit(m.name, 30)
                          + Presentation.fit(m.role, 9) + "\(unread)\(m.total) messages")
                }
                print("")
            }
        } catch {
            CLI.fail(error: error, json: json)
        }
    }
}
