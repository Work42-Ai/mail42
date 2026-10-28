// MailReader.swift — the right-hand pane: the message header, attachment chips and the rendered body.
//
// The body is the sanitised HTML `mail42 message read --html --out` wrote into the session's artifacts folder,
// shown by the SDK's BrowserSurface (JS-free content, remote images allowed, links through Open Link) with its
// chrome hidden. The surface owns highlight-to-comment; the resolver below only labels the comment so an agent
// can find the message again.

import AppKit
import SwiftUI
import Work42PluginKit
import Work42UI

struct MailReaderPane: View {
    let model: MailModel
    let services: SessionServices

    var body: some View {
        Group {
            if let envelope = model.selectedEnvelope {
                VStack(spacing: 0) {
                    MailMessageHeader(envelope: envelope, attachments: model.attachments, model: model)
                    Divider().opacity(0.4)
                    MailBodyView(model: model, services: services)
                }
            } else {
                MailPlaceholder(symbol: "envelope.open", title: "Select a message", text: "Pick one on the left to read it here.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MailMessageHeader: View {
    let envelope: MailEnvelope
    let attachments: [MailAttachment]
    let model: MailModel

    var body: some View {
        VStack(alignment: .leading, spacing: DT.s8) {
            Text(envelope.subject.isEmpty ? "(no subject)" : envelope.subject)
                .font(.system(size: DT.f14, weight: .semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: DT.s8) {
                MailAvatar(person: envelope.from)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(envelope.from.display).font(.system(size: DT.f12, weight: .semibold))
                        if let addr = envelope.from.addr, addr != envelope.from.display {
                            Text(addr).font(.system(size: DT.f10)).foregroundStyle(.secondary)
                        }
                    }
                    if !envelope.to.isEmpty {
                        Text("To: " + envelope.to.map(\.display).joined(separator: ", "))
                            .font(.system(size: DT.f10)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if !envelope.cc.isEmpty {
                        Text("Cc: " + envelope.cc.map(\.display).joined(separator: ", "))
                            .font(.system(size: DT.f10)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: DT.s8)
                Text(envelope.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: DT.f10)).foregroundStyle(.secondary)
            }
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachments) { attachment in
                            Button {
                                Task { await model.saveAttachment(attachment) }
                            } label: {
                                Label(attachment.filename, systemImage: "paperclip")
                                    .font(.system(size: DT.f10))
                                    .lineLimit(1)
                            }
                            .glassPlainCapsule()
                            .help("Save \(attachment.filename) to Downloads")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, DT.s12)
        .padding(.vertical, DT.s8)
    }
}

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
                text: "Apple Mail hasn\u{2019}t fetched its body yet. Open it in Mail to download it, then Sync.")
        case .fdaDenied:
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
            spec: BrowserSurfaceSpec(url: url, dataStoreKey: "mail42-reader", title: "Mail", icon: "envelope"),
            cacheKey: key,
            services: services,
            selectionResolver: { [weak model] selection in
                guard let envelope = model?.selectedEnvelope else { return nil }
                let subject = envelope.subject.isEmpty ? "(no subject)" : envelope.subject
                return ResolvedAnnotation(
                    sourceLabel: "Mail \u{00B7} \(subject) \u{00B7} \(envelope.from.display) (mail42 id \(envelope.id))")
            }
        )
        .browserChromeHostOwned(true)
        .id(key)
    }
}

// MARK: - Small shared pieces

struct MailAvatar: View {
    let person: MailPerson
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.18))
            Text(person.initials)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        }
        .frame(width: size, height: size)
    }
}

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
                .font(.system(size: DT.f10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300)
        }
        .padding(DT.s20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
