// AccountDirectory.swift — the names and addresses of the user's mail accounts.
//
// Apple Mail's Envelope Index only knows an account by a UUID (`imap://<uuid>/INBOX`). The name and address live in
// the system Accounts database (`~/Library/Accounts/Accounts4.sqlite`): a Mail account row (identified by that
// UUID) has no address of its own, but its PARENT account does (`yansarorodriguezpaez@gmail.com`, described as
// "Google"), which is exactly what Mail's sidebar shows. Like the Envelope Index, the database is only ever read
// through a private copy, and any problem (no file, no access, a schema that changed) just means "no names": the
// caller falls back to the UUID rather than failing.

import Foundation
import Mail42Kit

public enum AccountDirectory {

    public struct Info: Equatable, Sendable {
        /// The account's display name as Mail shows it ("Google", "yan@web42.ai", "On My Mac").
        public let name: String?
        /// The account's address, when it has one.
        public let email: String?

        public init(name: String?, email: String?) {
            self.name = name
            self.email = email
        }
    }

    /// Account UUID → name and address. Empty when the database can't be read.
    public static func load(database: URL) -> [String: Info] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: database.path) else { return [:] }
        let directory = fm.temporaryDirectory.appendingPathComponent("mail42-accounts-\(getpid())-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { return [:] }
        defer { try? fm.removeItem(at: directory) }

        do {
            let copy = directory.appendingPathComponent("Accounts4.sqlite")
            try fm.copyItem(at: database, to: copy)
            let wal = URL(fileURLWithPath: database.path + "-wal")
            if fm.fileExists(atPath: wal.path) {
                try fm.copyItem(at: wal, to: URL(fileURLWithPath: copy.path + "-wal"))
            }
            let connection = try SQLiteConnection(path: copy.path, readOnly: true)
            defer { connection.close() }

            var result: [String: Info] = [:]
            try connection.query(
                """
                SELECT a.ZIDENTIFIER, a.ZUSERNAME, a.ZACCOUNTDESCRIPTION, p.ZUSERNAME, p.ZACCOUNTDESCRIPTION
                FROM ZACCOUNT a LEFT JOIN ZACCOUNT p ON p.Z_PK = a.ZPARENTACCOUNT
                WHERE a.ZIDENTIFIER IS NOT NULL
                """
            ) { row in
                guard let uuid = row.text(0) else { return }
                let email = [row.text(1), row.text(3)].compactMap { $0 }.first { $0.contains("@") }
                let name = [row.text(2), row.text(4)].compactMap { $0 }.first { !$0.isEmpty } ?? email
                result[uuid.uppercased()] = Info(name: name, email: email)
            }
            return result
        } catch {
            return [:]
        }
    }
}
