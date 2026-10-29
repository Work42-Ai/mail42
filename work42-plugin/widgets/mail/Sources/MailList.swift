// MailList.swift — the list pane: a search field, then conversations under date headers (Today, Yesterday, a
// weekday, a month). One row per conversation: its newest message, who wrote in it, and how many messages it has.
// Right-click gives the same menu as the header's More button; ↑ ↓ move between rows and Delete deletes the open one.

import AppKit
import SwiftUI
import Work42PluginKit
import Work42UI

struct MailListPane: View {
    let model: MailModel
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DT.s8) {
                Image(systemName: "magnifyingglass").font(.system(size: DT.f12)).foregroundStyle(.secondary)
                TextField("Search mail  (from:  is:unread  date:2w..)", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: DT.f13))
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
            .padding(.horizontal, DT.s12)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DT.chipFill))
            .padding(DT.s12)
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
                MailRows(model: model)
            }
        }
    }

    private func push() {
        guard model.query != text else { return }
        model.query = text
        model.filtersChanged()
    }
}

/// The rows, grouped under date headers.
private struct MailRows: View {
    let model: MailModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(MailGrouping.sections(model.envelopes)) { section in
                    Section {
                        ForEach(section.envelopes) { envelope in
                            MailRow(envelope: envelope, selected: envelope.id == model.selectedID)
                                .equatable()
                                .contentShape(Rectangle())
                                .onTapGesture { model.select(envelope.id) }
                                .contextMenu { MailActionMenu(model: model, target: envelope) }
                                .onAppear { model.loadMoreIfNeeded(current: envelope) }
                            Divider().opacity(0.25)
                        }
                    } header: {
                        Text(section.title.uppercased())
                            .font(.system(size: DT.f10, weight: .semibold))
                            .tracking(0.4)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, DT.s12)
                            .padding(.top, DT.s12)
                            .padding(.bottom, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.ultraThinMaterial)
                    }
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { model.moveSelection(by: -1); return .handled }
        .onKeyPress(.downArrow) { model.moveSelection(by: 1); return .handled }
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            guard model.selectedEnvelope != nil else { return .ignored }
            Task { await model.perform(.delete) }
            return .handled
        }
    }
}

/// Grey rows shown in the list while a new view loads and the old one has nothing to keep on screen.
struct MailSkeletonRows: View {
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

struct MailRow: View, Equatable {
    let envelope: MailEnvelope
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(envelope.isRead ? Color.clear : DT.systemAccent)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(envelope.heading)
                        .font(.system(size: DT.f13, weight: envelope.isRead ? .regular : .semibold))
                        .lineLimit(1)
                    if let count = envelope.conversationCount, count > 1 {
                        Text("\(count)")
                            .font(.system(size: DT.f9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(DT.chipFill))
                    }
                    Spacer(minLength: 4)
                    if envelope.isFlagged { Image(systemName: "flag.fill").font(.system(size: DT.f9)).foregroundStyle(.orange) }
                    if envelope.hasAttachments { Image(systemName: "paperclip").font(.system(size: DT.f9)).foregroundStyle(.secondary) }
                    Text(MailDates.short(envelope.date)).font(.system(size: DT.f11)).foregroundStyle(.secondary)
                }
                Text(envelope.subject.isEmpty ? "(no subject)" : envelope.subject)
                    .font(.system(size: DT.f12, weight: envelope.isRead ? .regular : .medium))
                    .lineLimit(1)
                if let snippet = envelope.snippet, !snippet.isEmpty {
                    Text(snippet).font(.system(size: DT.f11)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.horizontal, DT.s12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? DT.systemAccent.opacity(0.16) : Color.clear)
    }
}

// MARK: - Date groups

struct MailSection: Identifiable {
    let title: String
    let envelopes: [MailEnvelope]
    var id: String { title }
}

enum MailGrouping {
    /// Today, Yesterday, a weekday for the rest of the last week, then "October 2026". The list is newest first, so
    /// each group is one run of rows.
    static func sections(_ envelopes: [MailEnvelope], now: Date = Date()) -> [MailSection] {
        var result: [MailSection] = []
        for envelope in envelopes {
            let title = MailDates.groupTitle(envelope.date, now: now)
            if let last = result.last, last.title == title {
                result[result.count - 1] = MailSection(title: title, envelopes: last.envelopes + [envelope])
            } else {
                result.append(MailSection(title: title, envelopes: [envelope]))
            }
        }
        return result
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
    private static let weekday: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEEE"); return f
    }()
    private static let monthYear: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMMM y"); return f
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

    static func groupTitle(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 99
        if days >= 0, days < 7 { return weekday.string(from: date) }
        return monthYear.string(from: date)
    }
}
