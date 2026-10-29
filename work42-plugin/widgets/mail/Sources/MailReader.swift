// MailReader.swift — the right-hand pane: a conversation as a stack of messages, the open one expanded (header,
// attachment cards, the message in Work42's theme) and the others folded to one line each.
//
// The body is the sanitised HTML `mail42 message read --html --out` wrote, put in Work42's theme (MailBodyTheme) and
// shown by the SDK's BrowserSurface with its chrome hidden. The surface owns highlight-to-comment; the resolver below
// only labels the comment so an agent can find the message again.

import AppKit
import SwiftUI
import Work42PluginKit
import Work42UI

struct MailReaderPane: View {
    let model: MailModel
    let services: SessionServices

    var body: some View {
        Group {
            if model.missingMessage {
                MailPlaceholder(
                    symbol: "tray", title: "This message is no longer in Mail",
                    text: "It may have been deleted, or it is in an account that isn\u{2019}t set up on this Mac.")
            } else if let open = model.expandedEnvelope {
                MailThread(model: model, services: services, open: open)
            } else {
                MailPlaceholder(symbol: "envelope.open", title: "Select a message", text: "Pick one on the left to read it here.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - The conversation

private struct MailThread: View {
    let model: MailModel
    let services: SessionServices
    let open: MailEnvelope

    var body: some View {
        let messages = model.thread.isEmpty ? [open] : model.thread
        let index = messages.firstIndex { $0.id == open.id } ?? 0
        let earlier = Array(messages[..<index])
        let later = Array(messages[(index + 1)...])

        VStack(spacing: 0) {
            if messages.count > 1 || model.isOutsideView {
                HStack(spacing: DT.s8) {
                    Text(messages.count > 1 ? "\(messages.count) messages" : "1 message")
                        .font(.system(size: DT.f11)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if model.isOutsideView {
                        Label("In \(open.mailbox.name) \u{00B7} \(open.account.name)", systemImage: "tray")
                            .font(.system(size: DT.f11)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, DT.s20)
                .padding(.vertical, DT.s8)
            }
            if !earlier.isEmpty { collapsed(earlier) }
            MailOpenMessage(model: model, services: services, envelope: open)
                .frame(maxHeight: .infinity)
            if !later.isEmpty { collapsed(later) }
        }
    }

    /// Folded messages, scrolling when there are many so the open one keeps its room.
    private func collapsed(_ messages: [MailEnvelope]) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(messages) { message in
                    MailCollapsedRow(model: model, envelope: message)
                    Divider().opacity(0.3)
                }
            }
        }
        .frame(maxHeight: 136)
        .fixedSize(horizontal: false, vertical: messages.count <= 3)
    }
}

/// An earlier (or later) message of the conversation, as one line. Clicking opens it.
private struct MailCollapsedRow: View {
    let model: MailModel
    let envelope: MailEnvelope

    var body: some View {
        Button { model.expand(envelope.id) } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(envelope.isRead ? Color.clear : DT.systemAccent)
                    .frame(width: 7, height: 7)
                MailAvatar(person: envelope.from, size: 26, isMe: model.isMine(envelope))
                Text(model.isMine(envelope) ? "You" : envelope.from.display)
                    .font(.system(size: DT.f12, weight: .medium))
                    .lineLimit(1)
                if model.isMine(envelope) {
                    Text("Sent")
                        .font(.system(size: DT.f9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(DT.chipFill))
                }
                Text(envelope.snippet ?? envelope.subject)
                    .font(.system(size: DT.f11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(MailDates.short(envelope.date)).font(.system(size: DT.f11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, DT.s20)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - The open message

private struct MailOpenMessage: View {
    let model: MailModel
    let services: SessionServices
    let envelope: MailEnvelope

    var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.4)
            MailMessageHeader(model: model, envelope: envelope)
            if !model.attachments.isEmpty {
                MailAttachmentCards(model: model, attachments: model.attachments)
            }
            Divider().opacity(0.4)
            MailBodyView(model: model, services: services)
        }
    }
}

private struct MailMessageHeader: View {
    let model: MailModel
    let envelope: MailEnvelope

    var body: some View {
        VStack(alignment: .leading, spacing: DT.s12) {
            HStack(alignment: .top, spacing: DT.s12) {
                MailAvatar(person: envelope.from, size: 40, isMe: model.isMine(envelope))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: DT.s8) {
                        Text(model.isMine(envelope) ? "You" : envelope.from.display)
                            .font(.system(size: DT.f13, weight: .semibold))
                            .textSelection(.enabled)
                        if let addr = envelope.from.addr, addr != envelope.from.display {
                            Text(addr).font(.system(size: DT.f11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: DT.s8)
                        Label("\(envelope.mailbox.name) \u{00B7} \(envelope.account.name)", systemImage: "tray")
                            .font(.system(size: DT.f11)).foregroundStyle(.secondary).lineLimit(1)
                        Text(MailDates.full.string(from: envelope.date))
                            .font(.system(size: DT.f11)).foregroundStyle(.secondary)
                    }
                    Text(envelope.subject.isEmpty ? "(no subject)" : envelope.subject)
                        .font(.system(size: DT.f15, weight: .semibold))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .firstTextBaseline, spacing: DT.s8) {
                        recipients
                        Spacer(minLength: 0)
                        Button(model.showDetails ? "Hide" : "Details") { model.showDetails.toggle() }
                            .buttonStyle(.plain)
                            .font(.system(size: DT.f11, weight: .medium))
                            .foregroundStyle(DT.systemAccent)
                    }
                    if model.showDetails { details }
                }
            }
        }
        .padding(.horizontal, DT.s20)
        .padding(.vertical, DT.s12)
    }

    /// `To: Danny, Cc: Anthony, Trev` on one line.
    private var recipients: some View {
        var parts: [String] = []
        if !envelope.to.isEmpty { parts.append("To: " + envelope.to.map(\.display).joined(separator: ", ")) }
        if !envelope.cc.isEmpty { parts.append("Cc: " + envelope.cc.map(\.display).joined(separator: ", ")) }
        return Text(parts.joined(separator: "   "))
            .font(.system(size: DT.f11)).foregroundStyle(.secondary).lineLimit(1)
    }

    /// Every address, and the full date.
    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("From", envelope.from.full)
            if !envelope.to.isEmpty { row("To", envelope.to.map(\.full).joined(separator: ", ")) }
            if !envelope.cc.isEmpty { row("Cc", envelope.cc.map(\.full).joined(separator: ", ")) }
            row("Date", MailDates.full.string(from: envelope.date))
        }
        .padding(DT.s8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DT.chipFill))
        .textSelection(.enabled)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DT.s8) {
            Text(label).font(.system(size: DT.f11)).foregroundStyle(.tertiary).frame(width: 36, alignment: .trailing)
            Text(value).font(.system(size: DT.f11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Attachments

private struct MailAttachmentCards: View {
    let model: MailModel
    let attachments: [MailAttachment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DT.s8) {
                ForEach(attachments) { attachment in
                    MailAttachmentCard(model: model, attachment: attachment)
                }
            }
            .padding(.horizontal, DT.s20)
            .padding(.bottom, DT.s12)
        }
    }
}

private struct MailAttachmentCard: View {
    let model: MailModel
    let attachment: MailAttachment

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol.name)
                .font(.system(size: 22))
                .foregroundStyle(symbol.color)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename.isEmpty ? "Attachment" : attachment.filename)
                    .font(.system(size: DT.f12, weight: .medium))
                    .lineLimit(1)
                Text(detail).font(.system(size: DT.f11)).foregroundStyle(.secondary).lineLimit(1)
            }
            MailIconButton(symbol: "eye", help: "Quick Look") { Task { await model.quickLook(attachment) } }
            MailIconButton(symbol: "arrow.down.circle", help: "Save to Downloads") { Task { await model.saveAttachment(attachment) } }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DT.chipFill))
    }

    private var detail: String {
        let size = attachment.size > 0 ? ByteCountFormatter.string(fromByteCount: attachment.size, countStyle: .file) : nil
        return [size, kind].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    private var ext: String { (attachment.filename as NSString).pathExtension.lowercased() }

    private var kind: String? {
        switch ext {
        case "pdf": return "PDF"
        case "png", "jpg", "jpeg", "gif", "heic", "webp": return "Image"
        case "xls", "xlsx", "csv", "numbers": return "Spreadsheet"
        case "doc", "docx", "pages", "rtf", "txt": return "Document"
        case "ppt", "pptx", "key": return "Presentation"
        case "zip", "gz", "tar", "7z": return "Archive"
        case "ics": return "Calendar event"
        default: return ext.isEmpty ? nil : ext.uppercased()
        }
    }

    private var symbol: (name: String, color: Color) {
        switch ext {
        case "pdf": return ("doc.richtext.fill", .red)
        case "png", "jpg", "jpeg", "gif", "heic", "webp": return ("photo.fill", .purple)
        case "xls", "xlsx", "csv", "numbers": return ("tablecells.fill", .green)
        case "doc", "docx", "pages", "rtf", "txt": return ("doc.text.fill", .blue)
        case "ppt", "pptx", "key": return ("rectangle.on.rectangle.angled.fill", .orange)
        case "zip", "gz", "tar", "7z": return ("doc.zipper", .gray)
        case "ics": return ("calendar", .red)
        default: return ("doc.fill", .secondary)
        }
    }
}

// MARK: - The message

private struct MailBodyView: View {
    let model: MailModel
    let services: SessionServices

    var body: some View {
        switch model.reader {
        case .none:
            Color.clear
        case .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready(let id, let url, let key):
            MailWebBody(model: model, services: services, id: id, url: url, key: key)
        case .unavailable:
            MailPlaceholder(
                symbol: "arrow.down.circle", title: "This message isn\u{2019}t downloaded",
                text: "Apple Mail hasn\u{2019}t fetched its body yet. Open it in Mail to download it.")
        case .needsAccess:
            MailPlaceholder(
                symbol: "lock.shield", title: "mail42 can\u{2019}t read this message",
                text: "Full Disk Access isn\u{2019}t granted to mail42.")
        case .failed(_, let message):
            VStack(spacing: DT.s8) {
                MailPlaceholder(symbol: "exclamationmark.triangle", title: "Couldn\u{2019}t open the message", text: message)
                Button("Try again") { model.retryReader() }.glassPlainCapsule()
            }
        }
    }
}

private struct MailWebBody: View {
    let model: MailModel
    let services: SessionServices
    let id: Int64
    let url: URL
    let key: String

    var body: some View {
        BrowserSurface(
            spec: BrowserSurfaceSpec(url: url, dataStoreKey: "mail42-reader", title: "Mail42", icon: "envelope"),
            cacheKey: key,
            services: services,
            selectionResolver: { [weak model] _ in
                guard let envelope = model?.expandedEnvelope else { return nil }
                let subject = envelope.subject.isEmpty ? "(no subject)" : envelope.subject
                let link = envelope.link ?? "mail42://message/\(envelope.id)"
                return ResolvedAnnotation(sourceLabel: "Mail42 \u{00B7} \(subject) \u{00B7} \(envelope.from.display) (\(link))")
            }
        )
        .browserChromeHostOwned(true)
        .id(key)
    }
}

// MARK: - Small shared pieces

struct MailPlaceholder: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: DT.s8) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DT.chipFill))
            Text(title).font(.system(size: DT.f12, weight: .semibold))
            Text(text)
                .font(.system(size: DT.f11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
        }
        .padding(DT.s20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
