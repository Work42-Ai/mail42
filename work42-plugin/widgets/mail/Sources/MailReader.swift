// MailReader.swift — the right-hand pane: a conversation read as ONE page that scrolls. Every message is an accordion
// section (click its line to open it, click its top line again to fold it); scrolling to the bottom of the last open
// message opens the next one in order, so a long thread reads straight through. With nothing selected, a quiet empty
// state. (Back and search live in the tile's header, so there is a single bar.)
//
// Each body is the sanitised HTML `mail42 message read --html --out` wrote, put in Work42's theme (MailBodyTheme) and
// shown by `MailInlineWebView`, a web view as tall as its content, so the bodies scroll with the page.

import AppKit
import SwiftUI
import Work42PluginKit
import Work42UI

/// Kept for the aligned bars of the setup states; the tile has one header now.
let mailBarHeight: CGFloat = 58

struct MailReaderPane: View {
    let model: MailModel
    let services: SessionServices

    var body: some View {
        Group {
            if model.missingMessage {
                MailPlaceholder(
                    symbol: "tray", title: "This message is no longer in Mail",
                    text: "It may have been deleted, or it is in an account that isn\u{2019}t set up on this Mac.")
            } else if model.selectedEnvelope != nil {
                // A different conversation fades in; Back fades it out.
                MailThread(model: model, services: services)
                    .id(model.selectedEnvelope?.id)
                    .transition(.opacity)
            } else {
                MailEmptyReader(model: model)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.25), value: model.selectedEnvelope?.id)
        .animation(.easeInOut(duration: 0.25), value: model.missingMessage)
    }
}

// MARK: - Nothing selected

private struct MailEmptyReader: View {
    let model: MailModel

    var body: some View {
        VStack(spacing: DT.s12) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(DT.systemAccent.opacity(0.12))
                Image(systemName: "envelope.open.fill")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(DT.systemAccent)
            }
            .frame(width: 84, height: 84)
            Text("No message selected").font(.system(size: DT.f15, weight: .semibold))
            Text(summary)
                .font(.system(size: DT.f12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: DT.s12) {
                hint("\u{2191} \u{2193}", "move")
                hint("\u{2318}N", "new message")
                hint("\u{238B}", "back")
            }
            .padding(.top, DT.s8)
        }
        .padding(DT.s20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var summary: String {
        let unread = model.unreadInView
        if model.envelopes.isEmpty { return "Nothing in \(model.title) yet." }
        return unread > 0
            ? "\(unread.formatted()) unread in \(model.title).\nPick a conversation on the left to read it here."
            : "You\u{2019}re all caught up in \(model.title).\nPick a conversation on the left to read it here."
    }

    private func hint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Text(keys)
                .font(.system(size: DT.f10, weight: .medium, design: .rounded))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DT.chipFill))
            Text(label).font(.system(size: DT.f11)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - The conversation

/// Where the page is scrolled to, as far as "has it reached the bottom" is concerned.
private struct MailScrollEdge: Equatable {
    let nearBottom: Bool
    /// The page height in steps, so growth (a body measured, a message opened) is noticed too.
    let steps: Int
}

/// Every message of the conversation, oldest first, in one scroll view.
private struct MailThread: View {
    let model: MailModel
    let services: SessionServices
    @State private var nearBottom = false
    @State private var lastOpened = Date.distantPast

    private var messages: [MailEnvelope] {
        model.thread.isEmpty ? (model.selectedEnvelope.map { [$0] } ?? []) : model.thread
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(messages) { message in
                        MailThreadSection(model: model, services: services, envelope: message)
                            .id(message.id)
                        Divider().opacity(0.3)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: model.openIDs)
            }
            .onScrollGeometryChange(for: MailScrollEdge.self) { geometry in
                let bottom = geometry.contentOffset.y + geometry.containerSize.height
                return MailScrollEdge(
                    nearBottom: geometry.contentSize.height - bottom < 140,
                    steps: Int(geometry.contentSize.height / 24))
            } action: { _, edge in
                nearBottom = edge.nearBottom
                openNextIfReached()
            }
            .onChange(of: model.thread.count) { _, _ in
                // The whole conversation arrived: show the message that was picked at the top, the earlier ones above it.
                guard let id = model.selectedID else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(80))
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .top) }
                }
            }
        }
    }

    /// Reached the bottom of the last open message: open the next one, in order.
    private func openNextIfReached() {
        guard nearBottom,
              let last = messages.lastIndex(where: { model.openIDs.contains($0.id) }),
              last + 1 < messages.count
        else { return }
        if (model.bodies[messages[last].id] ?? .loading) == .loading { return }    // still arriving: wait for it
        let wait = 0.7 - Date().timeIntervalSince(lastOpened)
        if wait > 0 {
            Task {
                try? await Task.sleep(for: .seconds(wait))
                openNextIfReached()
            }
            return
        }
        lastOpened = Date()
        withAnimation(.easeInOut(duration: 0.25)) { model.open(messages[last + 1].id) }
    }
}

/// One message: a line when folded, its header, attachments and body when open.
private struct MailThreadSection: View {
    let model: MailModel
    let services: SessionServices
    let envelope: MailEnvelope

    var body: some View {
        VStack(spacing: 0) {
            if model.openIDs.contains(envelope.id) {
                MailMessageHeader(model: model, envelope: envelope)
                    .transition(.opacity)
                MailMessageContent(model: model, services: services, envelope: envelope)
                    .transition(.opacity)
            } else {
                MailCollapsedRow(model: model, envelope: envelope)
                    .transition(.opacity)
            }
        }
    }
}

/// A message of the conversation as one line. Clicking opens it.
private struct MailCollapsedRow: View {
    let model: MailModel
    let envelope: MailEnvelope

    var body: some View {
        Button { withAnimation(.easeInOut(duration: 0.25)) { model.toggle(envelope.id) } } label: {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.system(size: DT.f10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
                    .modifier(MailHoverNudge())
                Circle()
                    .fill(envelope.isRead ? Color.clear : DT.systemAccent)
                    .frame(width: 7, height: 7)
                MailAvatar(person: envelope.from, size: 26, isMe: model.isMine(envelope), mine: model.me)
                Text(model.senderName(envelope))
                    .font(.system(size: DT.f12, weight: .medium))
                    .lineLimit(1)
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

private struct MailMessageHeader: View {
    let model: MailModel
    let envelope: MailEnvelope

    var body: some View {
        HStack(alignment: .top, spacing: DT.s12) {
            MailAvatar(person: envelope.from, size: 40, isMe: model.isMine(envelope), mine: model.me)
            VStack(alignment: .leading, spacing: 4) {
                // The top line folds the message again.
                HStack(spacing: DT.s8) {
                    Text(model.senderName(envelope))
                        .font(.system(size: DT.f13, weight: .semibold))
                        .textSelection(.enabled)
                    if !model.isMine(envelope), let addr = envelope.from.addr, addr != envelope.from.display {
                        Text(addr).font(.system(size: DT.f11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: DT.s8)
                    Label("\(envelope.mailbox.name) \u{00B7} \(envelope.account.name)", systemImage: "tray")
                        .font(.system(size: DT.f11)).foregroundStyle(.secondary).lineLimit(1)
                    Text(MailDates.full.string(from: envelope.date))
                        .font(.system(size: DT.f11)).foregroundStyle(.secondary)
                    Image(systemName: "chevron.up")
                        .font(.system(size: DT.f10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeInOut(duration: 0.25)) { model.toggle(envelope.id) } }
                .help("Fold this message")

                Text(envelope.subject.isEmpty ? "(no subject)" : envelope.subject)
                    .font(.system(size: DT.f15, weight: .semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline, spacing: DT.s8) {
                    recipients
                    Spacer(minLength: 0)
                    Button(model.detailsID == envelope.id ? "Hide" : "Details") {
                        model.detailsID = model.detailsID == envelope.id ? nil : envelope.id
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: DT.f11, weight: .medium))
                    .foregroundStyle(DT.systemAccent)
                }
                if model.detailsID == envelope.id { details }
            }
        }
        .padding(.horizontal, DT.s20)
        .padding(.vertical, DT.s12)
    }

    /// `To: Danny, Cc: Anthony, Trev` on one line; the user's own address shows as their Work42 name.
    private var recipients: some View {
        var parts: [String] = []
        if !envelope.to.isEmpty { parts.append("To: " + envelope.to.map { model.name(of: $0, in: envelope) }.joined(separator: ", ")) }
        if !envelope.cc.isEmpty { parts.append("Cc: " + envelope.cc.map { model.name(of: $0, in: envelope) }.joined(separator: ", ")) }
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

/// An open message's attachments and body.
private struct MailMessageContent: View {
    let model: MailModel
    let services: SessionServices
    let envelope: MailEnvelope

    var body: some View {
        VStack(spacing: 0) {
            if let attachments = model.attachmentsByID[envelope.id], !attachments.isEmpty {
                MailAttachmentCards(model: model, messageID: envelope.id, attachments: attachments)
            }
            Divider().opacity(0.4)
            switch model.bodies[envelope.id] ?? .loading {
            case .loading:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, DT.s20)
            case .ready(let url):
                MailInlineBody(url: url, onSelection: { text in comment(on: text) })
            case .unavailable:
                note("This message isn\u{2019}t downloaded", "Apple Mail hasn\u{2019}t fetched its body yet. Open it in Mail to download it.")
            case .needsAccess:
                note("mail42 can\u{2019}t read this message", "Full Disk Access isn\u{2019}t granted to mail42.")
            case .failed(let message):
                VStack(spacing: DT.s8) {
                    note("Couldn\u{2019}t open the message", message)
                    Button("Try again") { model.retryBody(envelope.id) }.glassPlainCapsule()
                }
            }
        }
    }

    private func note(_ title: String, _ text: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.system(size: DT.f12, weight: .semibold))
            Text(text).font(.system(size: DT.f11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(DT.s20)
        .frame(maxWidth: .infinity)
    }

    /// Highlighted text becomes a commentable selection (dictate a comment, and it lands in the composer), labelled
    /// with the message so an agent can find it again.
    private func comment(on text: String) {
        let composer = services.composer
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Task { try? await composer.clearCommentableSelection() }
            return
        }
        let subject = envelope.subject.isEmpty ? "(no subject)" : envelope.subject
        let link = envelope.link ?? "mail42://message/\(envelope.id)"
        let label = "Mail42 \u{00B7} \(subject) \u{00B7} \(envelope.from.display) (\(link))"
        Task { try? await composer.presentCommentableSelection(sourceLabel: label, excerpt: text) }
    }
}

// MARK: - Attachments

private struct MailAttachmentCards: View {
    let model: MailModel
    let messageID: Int64
    let attachments: [MailAttachment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DT.s8) {
                ForEach(attachments) { attachment in
                    MailAttachmentCard(model: model, messageID: messageID, attachment: attachment)
                }
            }
            .padding(.horizontal, DT.s20)
            .padding(.bottom, DT.s12)
        }
    }
}

private struct MailAttachmentCard: View {
    let model: MailModel
    let messageID: Int64
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
            MailIconButton(symbol: "eye", help: "Quick Look") { Task { await model.quickLook(attachment, in: messageID) } }
            MailIconButton(symbol: "arrow.down.circle", help: "Save to Downloads") {
                Task { await model.saveAttachment(attachment, in: messageID) }
            }
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
