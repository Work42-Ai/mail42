// EmlxLocator.swift — where Apple Mail keeps a message's .emlx file.
//
// The layout and the hash-directory rule come from che-apple-mail-mcp's EmlxParser (MIT; see
// THIRD_PARTY_NOTICES.md), verified there against 256,428 real files. Adapted so the mail root is a parameter
// (it can be tested, and mail42 reads from one resolved root) and the mailbox path uses the non-lossy
// `pathComponents`, so an encoded `/` inside a mailbox name stays one directory.
//
//   <mailRoot>/<account-uuid>/<mailbox>.mbox[/<child>.mbox…]/<store-uuid>/Data/<hash>/Messages/<ROWID>.emlx
//
// `<hash>` is the decimal digits of ROWID / 1000, written right to left and joined with `/`: nothing for
// ROWID < 1000, `3` for 3 000…3 999, `3/2/1` for 123 456.

import Foundation
import Mail42Kit

public enum EmlxLocator {

    /// The `<hash>` path (possibly empty) for a ROWID.
    public static func hashDirectory(rowId: Int64) -> String {
        var n = rowId / 1000
        if n <= 0 { return "" }
        var digits: [String] = []
        while n > 0 {
            digits.append(String(n % 10))
            n /= 10
        }
        return digits.joined(separator: "/")
    }

    /// The `.emlx` (or `.partial.emlx`) file for a message, or nil when it isn't on disk: an Exchange account,
    /// or a message whose body Mail never downloaded. Use `isPartial(_:)` on the result.
    public static func emlxURL(rowid: Int64, mailboxURL: String, mailRoot: URL) -> URL? {
        guard let mailbox = MailboxURL.decode(mailboxURL), !mailbox.pathComponents.isEmpty else { return nil }

        var mailboxDir = mailRoot.appendingPathComponent(mailbox.accountUUID, isDirectory: true)
        for component in mailbox.pathComponents {
            mailboxDir.appendPathComponent("\(component).mbox", isDirectory: true)
        }
        // The path comes from Apple's database; make sure it can't climb out of the mail root.
        guard mailboxDir.standardizedFileURL.path.hasPrefix(mailRoot.standardizedFileURL.path + "/") else { return nil }

        let fm = FileManager.default
        let hash = hashDirectory(rowId: rowid)
        for store in storeDirectories(in: mailboxDir) {
            let data = store.appendingPathComponent("Data", isDirectory: true)
            let hashed = hash.isEmpty ? data : data.appendingPathComponent(hash, isDirectory: true)
            let messages = hashed.appendingPathComponent("Messages", isDirectory: true)
            for suffix in ["emlx", "partial.emlx"] {
                let candidate = messages.appendingPathComponent("\(rowid).\(suffix)")
                if fm.fileExists(atPath: candidate.path) { return candidate }
            }
            // The rule above has held for every real file checked, but Apple could change it: fall back to a
            // bounded search so a layout change degrades to "slower", not "body missing".
            if let found = boundedSearch(dataDirectory: data, rowid: rowid) { return found }
        }
        return nil
    }

    /// True for a `.partial.emlx`: Mail synced the headers but has not (fully) downloaded the body.
    public static func isPartial(_ emlx: URL) -> Bool {
        emlx.lastPathComponent.hasSuffix(".partial.emlx")
    }

    /// Mail's external attachment cache for a message:
    /// `<hash>/Attachments/<ROWID>/<part-id>/<filename>`, a sibling of the `Messages` folder.
    public static func attachmentsDirectory(forEmlx emlx: URL) -> URL {
        let rowid = emlx.lastPathComponent.prefix { $0.isNumber }
        return emlx.deletingLastPathComponent()      // …/Messages
            .deletingLastPathComponent()             // …/<hash>
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent(String(rowid), isDirectory: true)
    }

    // MARK: - Private

    /// The store folders (UUID-named) inside a `.mbox` directory.
    private static func storeDirectories(in mailboxDir: URL) -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: mailboxDir.path) else { return [] }
        return names
            .filter(isStoreUUID)
            .sorted()
            .map { mailboxDir.appendingPathComponent($0, isDirectory: true) }
    }

    private static func isStoreUUID(_ name: String) -> Bool {
        name.count == 36 && name.split(separator: "-").count == 5 && name.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    /// Looks for `Messages/<rowid>.emlx` in the single-digit hash folders under `Data`, at most 5 levels deep
    /// and 2 000 folders in total.
    private static func boundedSearch(dataDirectory: URL, rowid: Int64) -> URL? {
        let fm = FileManager.default
        var queue: [(url: URL, depth: Int)] = [(dataDirectory, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 2000 {
            let (dir, depth) = queue.removeFirst()
            visited += 1
            let messages = dir.appendingPathComponent("Messages", isDirectory: true)
            for suffix in ["emlx", "partial.emlx"] {
                let candidate = messages.appendingPathComponent("\(rowid).\(suffix)")
                if fm.fileExists(atPath: candidate.path) { return candidate }
            }
            guard depth < 5, let children = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in children.sorted() where name.count == 1 && name.first?.isNumber == true {
                queue.append((dir.appendingPathComponent(name, isDirectory: true), depth + 1))
            }
        }
        return nil
    }
}
