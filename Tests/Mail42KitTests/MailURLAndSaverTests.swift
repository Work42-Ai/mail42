import Foundation
import Testing
@testable import Mail42Kit

@Suite struct MailURLTests {

    @Test func buildsTheMessageURLMailOpens() {
        #expect(MailURL.messageURL(messageID: "<abc@example.com>")?.absoluteString == "message://%3Cabc%40example.com%3E")
    }

    @Test func addsTheAngleBracketsWhenTheyAreMissing() {
        #expect(MailURL.messageURL(messageID: "abc@example.com")?.absoluteString == "message://%3Cabc%40example.com%3E")
        #expect(MailURL.messageURL(messageID: "  <abc@example.com>\n")?.absoluteString == "message://%3Cabc%40example.com%3E")
    }

    @Test func encodesEveryCharacterThatCouldChangeTheURL() {
        let url = MailURL.messageURL(messageID: "<a+b c%d/e?f#g&h=i@x.y>")
        #expect(url?.absoluteString == "message://%3Ca%2Bb%20c%25d%2Fe%3Ff%23g%26h%3Di%40x.y%3E")
        #expect(url?.host == nil || url?.query == nil)         // nothing leaked into a query or fragment
        #expect(url?.fragment == nil)
    }

    @Test func rejectsAnEmptyId() {
        #expect(MailURL.messageURL(messageID: "") == nil)
        #expect(MailURL.messageURL(messageID: "   ") == nil)
    }

    @Test func keepsUnicodeIdsEncoded() {
        let url = MailURL.messageURL(messageID: "<ü@例え.jp>")
        #expect(url != nil)
        #expect(url?.absoluteString.contains("%") == true)
        #expect(url?.absoluteString.unicodeScalars.allSatisfy { $0.isASCII } == true)
    }
}

@Suite struct AttachmentSaverTests {

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mail42-save-\(UUID().uuidString)", isDirectory: true)
    }

    private let bytes = Data("%PDF-1.4 fake".utf8)

    @Test func savesAFileAndCreatesTheFolder() throws {
        let dir = tempDir().appendingPathComponent("nested/deeper")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent()) }
        let url = try AttachmentSaver.save(bytes, suggestedName: "report.pdf", fallbackName: "attachment-2", into: dir)
        #expect(url.lastPathComponent == "report.pdf")
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func neverOverwritesAnExistingFile() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let original = dir.appendingPathComponent("report.pdf")
        try Data("precious".utf8).write(to: original)

        let first = try AttachmentSaver.save(bytes, suggestedName: "report.pdf", fallbackName: "x", into: dir)
        let second = try AttachmentSaver.save(bytes, suggestedName: "report.pdf", fallbackName: "x", into: dir)
        #expect(first.lastPathComponent == "report (1).pdf")
        #expect(second.lastPathComponent == "report (2).pdf")
        #expect(try Data(contentsOf: original) == Data("precious".utf8))       // untouched
    }

    @Test func numbersFilesWithoutAnExtension() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try AttachmentSaver.save(bytes, suggestedName: "README", fallbackName: "x", into: dir)
        let second = try AttachmentSaver.save(bytes, suggestedName: "README", fallbackName: "x", into: dir)
        #expect(first.lastPathComponent == "README" && second.lastPathComponent == "README (1)")
    }

    @Test func aHostileFilenameCannotEscapeTheFolder() throws {
        let dir = tempDir().appendingPathComponent("safe")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let outside = dir.deletingLastPathComponent().appendingPathComponent("escaped.txt")
        for name in ["../escaped.txt", "../../escaped.txt", "/etc/passwd", "..", "a/../../escaped.txt"] {
            let url = try AttachmentSaver.save(bytes, suggestedName: name, fallbackName: "attachment-1", into: dir)
            #expect(url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL, "\(name) -> \(url.path)")
        }
        #expect(!FileManager.default.fileExists(atPath: outside.path))
    }

    @Test(arguments: [
        ("report.pdf", "report.pdf"), ("../../etc/passwd", "passwd"), (".hidden", "_hidden"), ("a:b.txt", "a_b.txt"),
        ("tab\tand\u{7}bell.txt", "taband" + "bell.txt"), ("  spaced.txt  ", "spaced.txt"), ("dir/sub/file.txt", "file.txt"),
        ("日本語.pdf", "日本語.pdf"),
    ])
    func sanitizesNames(raw: String, expected: String) {
        #expect(AttachmentSaver.sanitizedName(raw, fallback: "fallback") == expected)
    }

    @Test(arguments: [nil, "", "   ", ".", "..", "/", "\u{1}\u{2}"] as [String?])
    func fallsBackWhenNothingUsableIsLeft(raw: String?) {
        #expect(AttachmentSaver.sanitizedName(raw, fallback: "attachment-3") == "attachment-3")
    }

    @Test func reportsAFolderItCannotCreate() {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("mail42-blocker-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: blocker.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: blocker) }
        #expect(throws: Mail42Error.self) {
            try AttachmentSaver.save(bytes, suggestedName: "a.pdf", fallbackName: "x", into: blocker.appendingPathComponent("sub"))
        }
    }
}
