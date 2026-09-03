import SwiftUI
import WebKit

struct AlertWebView: UIViewRepresentable {
    let url: URL
    @Binding var reloadToken: UUID
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.isOpaque = false; web.backgroundColor = .clear; web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        context.coordinator.last = reloadToken
        web.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        return web
    }
    func updateUIView(_ web: WKWebView, context: Context) {
        if context.coordinator.last != reloadToken {
            context.coordinator.last = reloadToken
            web.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        }
    }
    final class Coordinator { var last = UUID() }
}

struct AlertOverlay: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        ZStack {
            ForEach(store.channels.filter { $0.enabled }) { channel in
                if let raw = KeychainStore.read(channel.alertURLKey), let url = URL(string: raw), !raw.isEmpty {
                    AlertWebView(url: url, reloadToken: $store.alertReloadToken)
                        .allowsHitTesting(false)
                        .opacity(store.alertsVisible ? 1 : 0)
                }
            }
        }.background(.clear)
    }
}
