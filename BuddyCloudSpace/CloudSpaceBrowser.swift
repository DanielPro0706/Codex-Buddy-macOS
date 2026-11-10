import Observation
import SwiftUI
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
@Observable
final class CloudSpaceBrowser: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var errorMessage: String?
    @ObservationIgnored private var gatewayURL: URL?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    func configure(address: String) {
        let url = try? CloudSpaceConfiguration.gatewayURL(from: address)
        guard url != gatewayURL else { return }
        gatewayURL = url
        webView.stopLoading()
        errorMessage = nil
        canGoBack = false
        canGoForward = false
        guard let url else {
            isLoading = false
            webView.loadHTMLString("", baseURL: nil)
            return
        }
        isLoading = true
        webView.load(URLRequest(url: url))
    }

    func reload() {
        guard let gatewayURL else { return }
        errorMessage = nil
        isLoading = true
        if webView.url == nil || webView.url?.scheme == "about" {
            webView.load(URLRequest(url: gatewayURL))
        } else {
            webView.reload()
        }
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        errorMessage = nil
        updateHistory()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        updateHistory()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        navigationFailed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        navigationFailed(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isLoading = false
        errorMessage = "网页进程已停止，请重新载入 gateway。"
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else {
            return .cancel
        }
        if url.absoluteString == "about:blank" {
            return .allow
        }
        guard let validated = try? CloudSpaceConfiguration.gatewayURL(from: url.absoluteString) else {
            // The gateway can use query parameters while browsing; credentials in
            // URLs and non-web schemes are still rejected below.
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  components?.user == nil, components?.password == nil else {
                return .cancel
            }
            return handleWebNavigation(url, targetIsNewWindow: navigationAction.targetFrame == nil)
        }
        return handleWebNavigation(validated, targetIsNewWindow: navigationAction.targetFrame == nil)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame,
           let response = navigationResponse.response as? HTTPURLResponse,
           response.statusCode >= 400 {
            isLoading = false
            if response.statusCode == 401 || response.statusCode == 403 {
                errorMessage = "gateway 拒绝了访问（HTTP \(response.statusCode)）。请确认 Tailscale 已连接且当前身份有权限，或在浏览器中完成认证。"
            } else {
                errorMessage = "gateway 返回 HTTP \(response.statusCode)，请稍后重试。"
            }
            return .cancel
        }
        if !navigationResponse.canShowMIMEType, let url = navigationResponse.response.url {
            openInBrowser(url)
            isLoading = false
            return .cancel
        }
        return .allow
    }

    private func handleWebNavigation(
        _ url: URL,
        targetIsNewWindow: Bool
    ) -> WKNavigationActionPolicy {
        guard let gatewayURL else {
            return .cancel
        }
        let sameOrigin = url.scheme?.lowercased() == gatewayURL.scheme?.lowercased()
            && url.host?.lowercased() == gatewayURL.host?.lowercased()
            && effectivePort(url) == effectivePort(gatewayURL)
        guard sameOrigin else {
            openInBrowser(url)
            return .cancel
        }
        if targetIsNewWindow {
            webView.load(URLRequest(url: url))
            return .cancel
        } else {
            return .allow
        }
    }

    private func effectivePort(_ url: URL) -> Int {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }

    private func navigationFailed(_ error: any Error) {
        let nsError = error as NSError
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }
        isLoading = false
        errorMessage = "无法载入 gateway：\(error.localizedDescription)\n请检查服务器地址、网络和 Tailscale 连接。"
        updateHistory()
    }

    private func updateHistory() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    private func openInBrowser(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}

#if os(macOS)
struct CloudSpaceBrowserView: NSViewRepresentable {
    let browser: CloudSpaceBrowser
    func makeNSView(context: Context) -> WKWebView { browser.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
struct CloudSpaceBrowserView: UIViewRepresentable {
    let browser: CloudSpaceBrowser
    func makeUIView(context: Context) -> WKWebView { browser.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif
