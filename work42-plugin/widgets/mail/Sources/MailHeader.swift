// MailHeader.swift — the widget header, drawn like Meet42's calendar header: the view's title and counts on the left,
// the message actions on the right (Work42 itself adds its ⋯ and × after them). Plus the menu those actions share
// with a row's right-click, and the keyboard shortcuts.
//
// Every action goes through `MailModel.perform`, which asks Apple Mail through the `mail42` CLI. Reply, Forward and New
// open Mail's own compose window: the person presses Send there.

import SwiftUI
import Work42PluginKit
import Work42UI

/// The list's width. The header is split at the same x, so the divider under the list runs up through the header.
let mailListWidth: CGFloat = 340
/// How much further in the header's content starts than the tile body's (Work42 draws the header with its own inset).
let mailHeaderInset: CGFloat = 12

struct MailHeader: View {
    let model: MailModel

    var body: some View {
        let hasMessage = model.selectedEnvelope != nil
        HStack(spacing: 0) {
            // Left of the divider: the search, always.
            MailSearchField(model: model)
                .padding(.trailing, DT.s12)
                .frame(width: mailListWidth - mailHeaderInset, height: 28, alignment: .leading)
                // The divider is drawn over the header's height without taking any: a divider that asks for height
                // makes the whole header as tall as the tile.
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1, height: 44)
                }
            // Right of the divider: Back (an arrow, while a message is open) and the message actions.
            HStack(spacing: DT.s8) {
                if hasMessage {
                    MailIconButton(symbol: "chevron.left", help: "Back to the list  \u{238B}") { model.deselect() }
                        .transition(.opacity)
                }
                Spacer(minLength: DT.s8)
                actions(hasMessage)
            }
            .padding(.leading, DT.s12)
            .frame(height: 28)
        }
        .frame(height: 28)
        .lineLimit(1)
        .animation(.easeInOut(duration: 0.2), value: hasMessage)
    }

    private func actions(_ hasMessage: Bool) -> some View {
        HStack(spacing: DT.s8) {
            HStack(spacing: 2) {
                MailIconButton(symbol: "arrowshape.turn.up.left", help: "Reply  \u{2318}R", enabled: hasMessage) { act(.reply) }
                MailIconButton(symbol: "arrowshape.turn.up.right", help: "Forward  \u{21E7}\u{2318}F", enabled: hasMessage) { act(.forward) }
                MailIconButton(symbol: "archivebox", help: "Archive  \u{2303}\u{2318}A", enabled: hasMessage) { act(.archive) }
                MailIconButton(symbol: "trash", help: "Delete  \u{2318}\u{232B}", enabled: hasMessage) { act(.delete) }
                Menu {
                    MailActionMenu(model: model, target: nil)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: DT.f12, weight: .medium))
                        .frame(width: 28, height: 26)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(!hasMessage)
                .opacity(hasMessage ? 1 : 0.35)
                .help("More actions")
            }
        }
    }

    private func act(_ action: MailModel.MailAction) { Task { await model.perform(action) } }
}

/// "Search INBOX by name, email or subject": searches the view you are in, headers only (see `MailModel.search`).
struct MailSearchField: View {
    let model: MailModel

    var body: some View {
        let text = Binding<String>(
            get: { model.query },
            set: { value in
                guard model.query != value else { return }
                model.query = value
                model.filtersChanged()
            })
        HStack(spacing: DT.s8) {
            Image(systemName: "magnifyingglass").font(.system(size: DT.f12)).foregroundStyle(.secondary)
            TextField("Search \(model.title) by name, email or subject", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: DT.f12))
            if model.isRefreshing && !model.query.isEmpty { ProgressView().controlSize(.mini) }
            if !model.query.isEmpty {
                Button { text.wrappedValue = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DT.s12)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(DT.chipFill))
    }
}

/// A small icon button with a hover highlight, disabled when there is no message to act on.
struct MailIconButton: View {
    let symbol: String
    let help: String
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: DT.f12, weight: .medium))
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: DT.rButton, style: .continuous)
                    .fill(hovering && enabled ? DT.chipFill : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// The More menu, and a row's right-click menu (`target` is the row; nil means the open message).
struct MailActionMenu: View {
    let model: MailModel
    let target: MailEnvelope?

    private var envelope: MailEnvelope? { target ?? model.selectedEnvelope }

    var body: some View {
        Button { act(.reply) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
        Button { act(.replyAll) } label: { Label("Reply All", systemImage: "arrowshape.turn.up.left.2") }
        Button { act(.forward) } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
        Divider()
        Button { act(.archive) } label: { Label("Archive", systemImage: "archivebox") }
        Button { act(.delete) } label: { Label("Delete", systemImage: "trash") }
        Button { act(.junk) } label: { Label("Move to Junk", systemImage: "xmark.bin") }
        Divider()
        Button { act(.markRead(!(envelope?.isRead ?? false))) } label: {
            Label((envelope?.isRead ?? false) ? "Mark as Unread" : "Mark as Read", systemImage: "envelope.badge")
        }
        Menu {
            ForEach(MailModel.flagColors, id: \.self) { color in
                Button(color.capitalized) { act(.flag(color)) }
            }
            if envelope?.isFlagged == true {
                Divider()
                Button("Clear Flag") { act(.flag(nil)) }
            }
        } label: { Label("Flag", systemImage: "flag") }
        Menu {
            ForEach(model.moveTargets) { box in
                Button(box.name) { act(.move(box.id)) }
            }
        } label: { Label("Move to", systemImage: "folder") }
        Divider()
        Button { act(.copyLink) } label: { Label("Copy Link to Message", systemImage: "link") }
        Button { act(.openInMail) } label: { Label("Open in Mail", systemImage: "arrow.up.forward.app") }
    }

    private func act(_ action: MailModel.MailAction) {
        Task {
            if let target { model.select(target.id) }               // a right-click acts on the row it was made on
            await model.perform(action)
        }
    }
}

/// Mail's keyboard shortcuts, as invisible buttons in the tile. (Delete on its own is handled by the list, so that
/// typing in the search field can never delete a message.)
struct MailShortcuts: View {
    let model: MailModel

    var body: some View {
        ZStack {
            shortcut("r", [.command], .reply)
            shortcut("r", [.command, .shift], .replyAll)
            shortcut("f", [.command, .shift], .forward)
            shortcut("a", [.command, .control], .archive)
            shortcut(.delete, [.command], .delete)
            shortcut("j", [.command, .shift], .junk)
            shortcut("l", [.command, .shift], .flag(selectedIsFlagged ? nil : "orange"))
            shortcut("u", [.command, .shift], .markRead(!(model.selectedEnvelope?.isRead ?? false)))
            shortcut("o", [.command], .openInMail)
            shortcut("n", [.command], .newMessage)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
    }

    private var selectedIsFlagged: Bool { model.selectedEnvelope?.isFlagged ?? false }

    private func shortcut(_ key: KeyEquivalent, _ modifiers: EventModifiers, _ action: MailModel.MailAction) -> some View {
        Button("") { Task { await model.perform(action) } }
            .keyboardShortcut(key, modifiers: modifiers)
    }
}
