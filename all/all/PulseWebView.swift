//
//  PulseWebView.swift
//  all (bridge-connect)
//
//  WKWebView vers Pulse (custom-connect). L'app iOS n'a pas de pages à elle :
//  elle pointe la WebView sur le front Angular de Pulse.
//

import SwiftUI
import WebKit

/// Enveloppe SwiftUI d'un `WKWebView` chargeant Pulse.
///
/// Le data store persistant (`.default()`) conserve les **cookies de session Pulse**
/// entre lancements — l'auth de session vit dans la WebView (CADRAGE §9). Pulse est
/// joignable via Tailscale (certificat TLS valide via `tailscale serve`/`cert`),
/// donc pas d'exception ATS à prévoir.
///
/// La navigation est instrumentée (`Coordinator`) pour **remonter l'état de
/// chargement et les erreurs** : sans ça, un échec (ATS, TLS, HTTP 4xx/5xx, host
/// injoignable) laisse une page blanche muette, impossible à diagnostiquer.
struct PulseWebView: UIViewRepresentable {
    let url: URL
    /// Déclencheur de rechargement : incrémenter cette valeur relance `load(url)`.
    var reloadToken: Int = 0
    var onEvent: (LoadEvent) -> Void = { _ in }

    enum LoadEvent {
        case started
        case finished
        case failed(String)
        case httpStatus(Int)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onEvent: onEvent) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // persistant : conserve les cookies de session
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.lastReloadToken = reloadToken
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onEvent = onEvent
        // Rechargement explicite demandé depuis l'UI.
        if reloadToken != context.coordinator.lastReloadToken {
            context.coordinator.lastReloadToken = reloadToken
            webView.load(URLRequest(url: url))
            return
        }
        // Première présentation : rien n'a encore été chargé.
        if webView.url == nil {
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var onEvent: (LoadEvent) -> Void
        var lastReloadToken = 0

        init(onEvent: @escaping (LoadEvent) -> Void) { self.onEvent = onEvent }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            onEvent(.started)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onEvent(.finished)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onEvent(.failed(error.localizedDescription))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onEvent(.failed(error.localizedDescription))
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if let http = navigationResponse.response as? HTTPURLResponse, http.statusCode >= 400 {
                onEvent(.httpStatus(http.statusCode))
            }
            decisionHandler(.allow)
        }
    }
}
