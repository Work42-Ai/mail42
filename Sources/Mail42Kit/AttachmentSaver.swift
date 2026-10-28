// AttachmentSaver.swift — copies an attachment's bytes into a folder without ever overwriting a file.
//
// The filename comes from an email, so it is untrusted: only its last path component is used, control
// characters and separators are removed, and a leading dot is replaced (no hidden files, no `../x`). If the
// name is already taken the copy is called `report (1).pdf`, `report (2).pdf`, …

import Foundation

public enum AttachmentSaver {

    /// A safe single-component filename, or `fallback` when nothing usable is left.
    public static func sanitizedName(_ raw: String?, fallback: String) -> String {
        guard let raw else { return fallback }
        var name = (raw as NSString).lastPathComponent
        name = String(String.UnicodeScalarView(name.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))
        name = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix(".") { name = "_" + name.dropFirst() }      // never a hidden file
        // Nothing but dots and underscores left (`.`, `..`, `/`): no real name, use the fallback.
        return (name.isEmpty || name.allSatisfy { $0 == "." || $0 == "_" }) ? fallback : name
    }

    /// Writes `data` into `directory` (created if needed) and returns the file it wrote.
    @discardableResult
    public static func save(_ data: Data, suggestedName: String?, fallbackName: String, into directory: URL) throws -> URL {
        let name = sanitizedName(suggestedName, fallback: fallbackName)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw Mail42Error.writeFailed("\(directory.path): \(error.localizedDescription)")
        }

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for attempt in 0..<10_000 {
            let candidate = attempt == 0
                ? name
                : (ext.isEmpty ? "\(base) (\(attempt))" : "\(base) (\(attempt)).\(ext)")
            let url = directory.appendingPathComponent(candidate)
            do {
                // `.withoutOverwriting` fails if the file exists, atomically: no race with another writer.
                try data.write(to: url, options: .withoutOverwriting)
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            } catch {
                throw Mail42Error.writeFailed("\(url.path): \(error.localizedDescription)")
            }
        }
        throw Mail42Error.writeFailed("too many files named \(name) in \(directory.path)")
    }
}
