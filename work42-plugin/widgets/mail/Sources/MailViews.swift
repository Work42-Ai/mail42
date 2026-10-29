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
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 380)
                Divider().opacity(0.5)
                MailReaderPane(model: model, services: services)
            }
        }
        .background { MailShortcuts(model: model) }
    }
}
