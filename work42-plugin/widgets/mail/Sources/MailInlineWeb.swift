// MailInlineWeb.swift — one message body as a web view that is exactly as tall as its content, so a whole conversation
// can be one page that scrolls (the bodies sit inside the thread's own scroll view instead of each scrolling alone).
//
// It reports its content height, hands the mouse wheel to the surrounding scroll view, opens links in the user's
// browser (a mail must never navigate itself away), and reports the selected text so it can become a comment.

import AppKit
import SwiftUI
import WebKit

/// A web view that never scrolls by itself: the wheel goes to whatever scroll view holds it.
private final class MailPassthroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
}

struct MailInlineWebView: NSViewRepresentable {
    let url: URL
    let onHeight: (CGFloat) -> Void
    let onSelection: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        coordinator.onHeight = onHeight
        coordinator.onSelection = onSelection
        let controller = WKUserContentController()
        controller.add(coordinator, name: Coordinator.handlerName)
        controller.addUserScript(WKUserScript(source: Coordinator.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let web = MailPassthroughWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = coordinator
        web.setValue(false, forKey: "drawsBackground")
        web.load(URLRequest(url: url))
        coordinator.loaded = url
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onHeight = onHeight
        coordinator.onSelection = onSelection
        if coordinator.loaded != url {
            coordinator.loaded = url
            web.load(URLRequest(url: url))
        }
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.handlerName)
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        static let handlerName = "mail42"

        var loaded: URL?
        var onHeight: (CGFloat) -> Void = { _ in }
        var onSelection: (String) -> Void = { _ in }

        /// Height: the body's own height (not the window's, which would never shrink). Selection: what is selected,
        /// a moment after it stops changing.
        static let script = #"""
        (function () {
          var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.mail42;
          if (!handler) return;
          function report() { handler.postMessage({ h: Math.ceil(document.body ? document.body.scrollHeight : 0) }); }
          report();
          window.addEventListener('load', report);
          if (window.ResizeObserver) new ResizeObserver(report).observe(document.body);
          var timer;
          document.addEventListener('selectionchange', function () {
            clearTimeout(timer);
            timer = setTimeout(function () {
              var s = window.getSelection();
              handler.postMessage({ s: s ? s.toString() : '' });
            }, 250);
          });
        })();
        """#

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if let height = body["h"] as? NSNumber { onHeight(CGFloat(truncating: height)) }
            if let text = body["s"] as? String { onSelection(text) }
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                return .cancel
            }
            return .allow
        }
    }
}

/// One message body at its natural height; it fades in once it has been measured.
struct MailInlineBody: View {
    let url: URL
    let onSelection: (String) -> Void
    @State private var height: CGFloat = 60
    @State private var measured = false

    var body: some View {
        MailInlineWebView(
            url: url,
            onHeight: { value in
                guard abs(value - height) > 1 else { return }
                height = max(value, 24)
                measured = true
            },
            onSelection: onSelection)
            .frame(height: height)
            .opacity(measured ? 1 : 0)
            .animation(.easeInOut(duration: 0.22), value: measured)
    }
}
