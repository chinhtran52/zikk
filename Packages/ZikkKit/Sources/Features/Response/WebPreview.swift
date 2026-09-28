import SwiftUI
import WebKit
import AppKit

/// Renders response data (HTML, images, PDF, text) in a non-persistent web view.
/// Links to other documents open in the default browser.
struct WebPreview: NSViewRepresentable {
    let data: Data
    let mimeType: String
    let baseURL: URL?
    var allowsJavaScript = true

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = allowsJavaScript
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != data else { return }
        context.coordinator.loaded = data
        view.load(data, mimeType: mimeType, characterEncodingName: "utf-8", baseURL: baseURL ?? URL(string: "about:blank")!)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: Data?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else { return .allow }
            // In-page anchors stay in the view; everything else opens externally.
            if url.fragment != nil, url.absoluteString.hasPrefix("about:") || url.scheme == nil { return .allow }
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
            return .cancel
        }
    }
}
