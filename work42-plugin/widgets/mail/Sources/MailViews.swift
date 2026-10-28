// MailViews.swift — the tile: a message list on the left, the reader on the right, and the setup states.

import AppKit
import SwiftUI
import Work42PluginKit
import Work42UI

struct MailBody: View {
    let model: MailModel
    let services: SessionServices

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .notInstalled:
                MailPlaceholder(
                    symbol: "terminal", title: "mail42 isn\u{2019}t installed",
                    text: "Ask the agent in a session to set up mail42: it installs the tool and walks you through Full Disk Access.")
            case .fdaDenied:
                MailAccessView(model: model)
            case .noAccounts where model.progress != nil:
                // The index is empty only because the first sync is still running.
                MailLoadingView(progress: model.progress)
            case .noAccounts:
                VStack(spacing: DT.s8) {
                    MailPlaceholder(
                        symbol: "tray", title: "No Mail accounts found",
                        text: "Add an account in Apple Mail, or run a sync if you just did.")
                    HStack {
                        Button("Sync now") { Task { await model.syncNow() } }.glassSubtleCapsule(tint: DT.systemAccent)
                        Button("Check again") { Task { await model.bootstrap() } }.glassPlainCapsule()
                    }
                }
            case .failed(let message):
                VStack(spacing: DT.s8) {
                    MailPlaceholder(symbol: "exclamationmark.triangle", title: "Couldn\u{2019}t read your mail", text: message)
                    Button("Try again") { Task { await model.bootstrap() } }.glassPlainCapsule()
                }
            case .ready:
                MailSplit(model: model, services: services)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { model.start(services: services) }
        .onDisappear { model.stop() }
        // A switch flipped in System Settings shows up as soon as the user is back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.recheckIfBlocked()
        }
    }
}

/// "Loading your mail…": shown while the first sync fills the index. Determinate once the total is known.
struct MailLoadingView: View {
    let progress: MailSyncProgress?
    var compact = false

    var body: some View {
        VStack(spacing: DT.s12) {
            Image(systemName: "envelope.fill")
                .font(.system(size: compact ? 18 : 24))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.pulse)
                .frame(width: compact ? 38 : 50, height: compact ? 38 : 50)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DT.chipFill))
            Text("Loading your mail…").font(.system(size: DT.f12, weight: .semibold))
            if let fraction = progress?.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: compact ? 180 : 260)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(MailLoadingText.detail(progress))
                .font(.system(size: DT.f10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !compact {
                Text("The first sync copies the last 90 days into a local index. After that, syncing takes seconds.")
                    .font(.system(size: DT.f9))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 300)
            }
        }
        .padding(DT.s20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A thin strip above the list while more mail is still arriving.
struct MailSyncStrip: View {
    let progress: MailSyncProgress

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Syncing · " + MailLoadingText.detail(progress))
                    .font(.system(size: DT.f10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DT.s12)
            .padding(.vertical, 4)
            if let fraction = progress.fraction {
                ProgressView(value: fraction).progressViewStyle(.linear).controlSize(.mini)
            }
        }
        .background(DT.chipFill)
    }
}

/// The words for a progress: "3,500 of 5,366 messages · about 1 min left".
enum MailLoadingText {
    static func detail(_ progress: MailSyncProgress?) -> String {
        guard let progress else { return "Starting…" }
        guard let total = progress.total else { return "Reading Apple Mail…" }
        guard total > 0 else { return "Checking for changes…" }
        var text = "\(progress.processed.formatted()) of \(total.formatted()) messages"
        if let seconds = progress.secondsLeft() { text += " · " + timeLeft(seconds) }
        return text
    }

    static func timeLeft(_ seconds: Int) -> String {
        if seconds < 45 { return "less than a minute left" }
        let minutes = Int((Double(seconds) / 60).rounded())
        return minutes <= 1 ? "about 1 min left" : "about \(minutes) min left"
    }
}

/// The Full Disk Access empty state.
private struct MailAccessView: View {
    let model: MailModel

    var body: some View {
        VStack(spacing: DT.s8) {
            MailPlaceholder(
                symbol: "lock.shield", title: "Allow mail42 to read Mail",
                text: "Apple Mail keeps your messages in a protected folder. Turn on mail42 under Privacy & Security \u{203A} Full Disk Access. It only reads; it never changes your mail.")
            HStack {
                Button("Open Settings") { Task { await model.openFullDiskAccessSettings() } }
                    .glassSubtleCapsule(tint: DT.systemAccent)
                Button("Check again") { Task { await model.bootstrap() } }.glassPlainCapsule()
            }
        }
    }
}

private struct MailSplit: View {
    let model: MailModel
    let services: SessionServices

    var body: some View {
        VStack(spacing: 0) {
            if let progress = model.progress, !model.envelopes.isEmpty {
                MailSyncStrip(progress: progress)
            }
            if let notice = model.notice {
                Text(notice)
                    .font(.system(size: DT.f10))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(DT.chipFill)
            }
            HStack(spacing: 0) {
                MailListPane(model: model)
                    .frame(minWidth: 230, idealWidth: 290, maxWidth: 340)
                Divider().opacity(0.5)
                MailReaderPane(model: model, services: services)
            }
        }
    }
}

// MARK: - List

private struct MailListPane: View {
    let model: MailModel
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Search mail  (from:  is:unread  date:2w..)", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: DT.f11))
                    .onSubmit { push() }
                if !text.isEmpty {
                    Button {
                        text = ""
                        push()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DT.s8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DT.chipFill))
            .padding(DT.s8)
            .onChange(of: text) { _, _ in push() }

            Divider().opacity(0.4)

            if model.envelopes.isEmpty, model.progress != nil {
                MailLoadingView(progress: model.progress, compact: true)
            } else if model.envelopes.isEmpty {
                MailPlaceholder(
                    symbol: "tray",
                    title: model.query.isEmpty ? "Nothing here" : "No matches",
                    text: model.query.isEmpty ? "No messages in this view yet." : "Nothing matches that search.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.envelopes) { envelope in
                            MailRow(envelope: envelope, selected: envelope.id == model.selectedID)
                                .contentShape(Rectangle())
                                .onTapGesture { model.select(envelope.id) }
                                .onAppear { model.loadMoreIfNeeded(current: envelope) }
                            Divider().opacity(0.25)
                        }
                    }
                }
            }
        }
    }

    private func push() {
        guard model.query != text else { return }
        model.query = text
        model.filtersChanged()
    }
}

private struct MailRow: View {
    let envelope: MailEnvelope
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(envelope.isRead ? Color.clear : Color.accentColor)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(envelope.from.display)
                        .font(.system(size: DT.f11, weight: envelope.isRead ? .regular : .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if envelope.isFlagged { Image(systemName: "flag.fill").font(.system(size: 9)).foregroundStyle(.orange) }
                    if envelope.hasAttachments { Image(systemName: "paperclip").font(.system(size: 9)).foregroundStyle(.secondary) }
                    Text(Self.shortDate(envelope.date)).font(.system(size: DT.f9)).foregroundStyle(.secondary)
                }
                Text(envelope.subject.isEmpty ? "(no subject)" : envelope.subject)
                    .font(.system(size: DT.f10, weight: envelope.isRead ? .regular : .medium))
                    .lineLimit(1)
                if let snippet = envelope.snippet, !snippet.isEmpty {
                    Text(snippet).font(.system(size: DT.f9)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.horizontal, DT.s8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.16) : Color.clear)
    }

    /// Today: the time. This year: day and month. Older: with the year.
    static func shortDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}
