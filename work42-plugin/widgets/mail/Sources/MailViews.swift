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
                MailSkeleton()
            case .notInstalled:
                MailPlaceholder(
                    symbol: "terminal", title: "mail42 isn\u{2019}t installed",
                    text: "Ask the agent in a session to set up mail42: it installs the tool and walks you through Full Disk Access.")
            case .needsAccess:
                MailAccessView(model: model)
            case .noMail:
                MailPlaceholder(
                    symbol: "tray", title: "No Mail accounts found",
                    text: "Add an account in Apple Mail and it shows up here by itself.")
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
            model.recheckNow()
        }
    }
}

// MARK: - Loading skeleton

/// The tile's shape while the first read runs: grey rows where messages will be, a quiet shimmer, no spinner.
struct MailSkeleton: View {
    @State private var dim = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DT.chipFill)
                    .frame(height: 28).padding(DT.s8)
                Divider().opacity(0.4)
                ForEach(0..<8, id: \.self) { index in
                    HStack(alignment: .top, spacing: 6) {
                        Circle().fill(DT.chipFill).frame(width: 7, height: 7).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 5) {
                            bar(width: 90 + CGFloat(index % 3) * 30, height: 9)
                            bar(width: 170 + CGFloat(index % 4) * 20, height: 8)
                            bar(width: 130, height: 7)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, DT.s8).padding(.vertical, 8)
                    Divider().opacity(0.25)
                }
                Spacer(minLength: 0)
            }
            .frame(minWidth: 230, idealWidth: 290, maxWidth: 340)
            Divider().opacity(0.5)
            VStack(spacing: DT.s8) {
                Image(systemName: "envelope.open").font(.system(size: 22)).foregroundStyle(.tertiary)
                Text("Reading your mail\u{2026}").font(.system(size: DT.f11)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .opacity(dim ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
        .onAppear { dim = true }
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous).fill(DT.chipFill).frame(width: width, height: height)
    }
}

// MARK: - Full Disk Access, guided

/// The first-run setup: three numbered steps, and the tile moves on by itself once access is granted.
private struct MailAccessView: View {
    let model: MailModel

    var body: some View {
        VStack(spacing: DT.s12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 24))
                .foregroundStyle(Color.accentColor)
                .frame(width: 50, height: 50)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DT.chipFill))
            Text("Let mail42 read your Mail").font(.system(size: DT.f12, weight: .semibold))
            Text("Apple Mail keeps messages in a protected folder. mail42 only reads them, and keeps no copy.")
                .font(.system(size: DT.f10)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 320)
            VStack(alignment: .leading, spacing: DT.s8) {
                step(1, "Open Privacy & Security \u{203A} Full Disk Access") {
                    Button("Open Settings") { Task { await model.openFullDiskAccessSettings() } }
                        .glassSubtleCapsule(tint: DT.systemAccent)
                }
                step(2, "Turn on mail42. If it isn\u{2019}t listed, press + and choose mail42 in your .work42 folder.") { EmptyView() }
                step(3, "Come back here. This continues by itself.") {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Waiting for access\u{2026}").font(.system(size: DT.f10)).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: 360, alignment: .leading)
        }
        .padding(DT.s20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func step<Extra: View>(_ number: Int, _ text: String, @ViewBuilder extra: () -> Extra) -> some View {
        HStack(alignment: .top, spacing: DT.s8) {
            Text("\(number)")
                .font(.system(size: DT.f10, weight: .semibold))
                .frame(width: 18, height: 18)
                .background(Circle().fill(DT.chipFill))
            VStack(alignment: .leading, spacing: 6) {
                Text(text).font(.system(size: DT.f11)).fixedSize(horizontal: false, vertical: true)
                extra()
            }
        }
    }
}

// MARK: - Split

private struct MailSplit: View {
    let model: MailModel
    let services: SessionServices

    var body: some View {
        VStack(spacing: 0) {
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
                if model.isRefreshing { ProgressView().controlSize(.mini) }
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

            if model.envelopes.isEmpty, model.isRefreshing {
                MailSkeletonRows()
            } else if model.envelopes.isEmpty {
                MailPlaceholder(
                    symbol: "tray",
                    title: model.query.isEmpty ? "Nothing here" : "No matches",
                    text: model.query.isEmpty ? "No messages in this view." : "Nothing matches that search.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.envelopes) { envelope in
                            MailRow(envelope: envelope, selected: envelope.id == model.selectedID)
                                .equatable()
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

/// Grey rows shown in the list while a new view loads and the old one has nothing to keep on screen.
private struct MailSkeletonRows: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<6, id: \.self) { index in
                VStack(alignment: .leading, spacing: 5) {
                    RoundedRectangle(cornerRadius: 3).fill(DT.chipFill).frame(width: 90 + CGFloat(index % 3) * 30, height: 9)
                    RoundedRectangle(cornerRadius: 3).fill(DT.chipFill).frame(width: 170, height: 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DT.s12).padding(.vertical, 9)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct MailRow: View, Equatable {
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
                    Text(MailDates.short(envelope.date)).font(.system(size: DT.f9)).foregroundStyle(.secondary)
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
}

/// Date formatters are expensive to build, so each is made once.
enum MailDates {
    private static let time: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f
    }()
    private static let dayMonth: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("d MMM"); return f
    }()
    private static let dayMonthYear: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("d MMM y"); return f
    }()
    static let full: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    /// Today: the time. This year: day and month. Older: with the year.
    static func short(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return time.string(from: date) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) { return dayMonth.string(from: date) }
        return dayMonthYear.string(from: date)
    }
}
