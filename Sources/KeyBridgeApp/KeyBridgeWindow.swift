// SPDX-License-Identifier: MIT
import AppKit
import WebKit

/// The packaged document owns presentation, never runtime or filesystem access.
@MainActor
final class KeyBridgeWindowController: NSViewController, WKNavigationDelegate, WKScriptMessageHandler {
    private let model: AppModel
    private var webView: WKWebView!
    private var ready = false
    private var pendingNavigation: String?
    init(model: AppModel) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(WeakScriptHandler(self), name: "keybridge")
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 760, height: 560), configuration: configuration)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.setValue(false, forKey: "drawsBackground")
        view = NSView(frame: webView.frame)
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor), webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor), webView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        let drag = WindowDragRegion()
        drag.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(drag)
        NSLayoutConstraint.activate([drag.topAnchor.constraint(equalTo: view.topAnchor), drag.leadingAnchor.constraint(equalTo: view.leadingAnchor), drag.widthAnchor.constraint(equalToConstant: 300), drag.heightAnchor.constraint(equalToConstant: 44)])
        model.didChange = { [weak self] value in self?.send(value) }
        model.navigate = { [weak self] destination in
            guard let self else { return }
            if self.ready { Task { _ = try? await self.webView.callAsyncJavaScript("window.KeyBridge.navigate(destination)", arguments: ["destination": destination], in: nil, contentWorld: .page) } }
            else { self.pendingNavigation = destination }
        }
        var page = Bundle.main.resourceURL?.appendingPathComponent("interface/keybridge.html")
        #if DEBUG
        if page == nil || !FileManager.default.fileExists(atPath: page!.path) {
            page = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/interface/keybridge.html")
        }
        #endif
        if let page, FileManager.default.fileExists(atPath: page.path) {
            webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        } else {
            let message = NSTextField(wrappingLabelWithString: "Не удалось открыть KeyBridge: в приложении отсутствует интерфейс. Установите полную сборку KeyBridge.")
            message.frame = NSRect(x: 24, y: 220, width: 712, height: 80)
            view.addSubview(message)
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        send(model.payload)
        if let destination = pendingNavigation { pendingNavigation = nil; model.navigate?(destination) }
    }
    private func send(_ payload: [String: Any]) {
        guard ready else { return }
        Task { _ = try? await webView.callAsyncJavaScript("window.KeyBridge.update(snapshot)", arguments: ["snapshot": payload], in: nil, contentWorld: .page) }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.name == "keybridge",
              message.frameInfo.request.url?.isFileURL == true,
              let request = message.body as? [String: Any] else { return }
        model.receive(request)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.navigationType == .linkActivated {
            model.openExternal(url); decisionHandler(.cancel)
        } else if url.isFileURL || url.absoluteString == "about:blank" { decisionHandler(.allow) }
        else { decisionHandler(.cancel) }
    }
}

private final class WindowDragRegion: NSView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? { nil }
}
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
