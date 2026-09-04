import SwiftUI
import WebKit

// Keep the browser at widget dimensions and fit the entire canvas into the phone.
// Resizing the phone must not crop a desktop-sized overlay or reload its audio.
struct AlertCanvasLayout {
    static let standard = CGSize(width: 800, height: 600)
    static func fittedFrame(canvas: CGSize, container: CGSize) -> CGRect {
        guard canvas.width > 0, canvas.height > 0,
              container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / canvas.width, container.height / canvas.height)
        let size = CGSize(width: canvas.width * scale, height: canvas.height * scale)
        return CGRect(x: (container.width - size.width) / 2,
                      y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}

final class AlertCanvasView: UIView, WKScriptMessageHandler {
    private(set) var web: WKWebView!
    private(set) var canvasSize = AlertCanvasLayout.standard
    private var lastURL: URL?
    private var lastReloadToken: UUID?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        // The isolated world exposes only dimensions, never page content or URLs.
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.measurementScript, injectionTime: .atDocumentEnd,
            forMainFrameOnly: true, in: .defaultClient))
        web = WKWebView(frame: .zero, configuration: configuration)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.accessibilityIdentifier = "alert-widget"
        addSubview(web)
        // A weak proxy avoids a web view -> handler -> view retain cycle.
        configuration.userContentController.add(WeakAlertSizeHandler(self), contentWorld: .defaultClient, name: "alertCanvasSize")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func load(url: URL, reloadToken: UUID) {
        guard lastURL != url || lastReloadToken != reloadToken else { return }
        lastURL = url
        lastReloadToken = reloadToken
        let host = url.host?.lowercased() ?? ""
        canvasSize = (host == "streamelements.com" || host.hasSuffix(".streamelements.com"))
            ? CGSize(width: 1920, height: 1080) : AlertCanvasLayout.standard
        setNeedsLayout()
        layoutIfNeeded()
        web.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let fitted = AlertCanvasLayout.fittedFrame(canvas: canvasSize, container: bounds.size)
        guard fitted.width > 0 else { return }
        web.transform = .identity
        web.bounds = CGRect(origin: .zero, size: canvasSize)
        web.center = CGPoint(x: bounds.midX, y: bounds.midY)
        let scale = fitted.width / canvasSize.width
        web.transform = CGAffineTransform(scaleX: scale, y: scale)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let size = message.body as? [String: Double],
              let width = size["width"], let height = size["height"],
              width.isFinite, height.isFinite, width > 0, height > 0 else { return }
        // Grow only within this page, avoiding scale jumps during alert animations.
        let next = CGSize(width: max(canvasSize.width, min(CGFloat(width), 8192)),
                          height: max(canvasSize.height, min(CGFloat(height), 8192)))
        guard next.width > canvasSize.width + 1 || next.height > canvasSize.height + 1 else { return }
        canvasSize = next
        setNeedsLayout()
    }

    func stop() {
        web.stopLoading()
        web.configuration.userContentController.removeScriptMessageHandler(forName: "alertCanvasSize", contentWorld: .defaultClient)
        web.loadHTMLString("", baseURL: nil)
    }

    private static let measurementScript = #"""
    (() => {
      const viewport = document.querySelector('meta[name="viewport"]') || document.createElement('meta');
      viewport.name = 'viewport';
      viewport.content = 'width=device-width, initial-scale=1';
      if (!viewport.parentNode) document.head.appendChild(viewport);
      let scheduled = false;
      let previous = '';
      const measure = () => {
        scheduled = false;
        const root = document.documentElement, body = document.body;
        const width = Math.max(innerWidth, root.scrollWidth, body ? body.scrollWidth : 0);
        const height = Math.max(innerHeight, root.scrollHeight, body ? body.scrollHeight : 0);
        const key = `${width}:${height}`;
        if (key === previous) return;
        previous = key;
        window.webkit.messageHandlers.alertCanvasSize.postMessage({width, height});
      };
      const schedule = () => {
        if (!scheduled) { scheduled = true; requestAnimationFrame(measure); }
      };
      new ResizeObserver(schedule).observe(document.documentElement);
      if (document.body) new ResizeObserver(schedule).observe(document.body);
      new MutationObserver(schedule).observe(document.documentElement, {childList:true, subtree:true, attributes:true});
      window.addEventListener('resize', schedule);
      document.addEventListener('load', schedule, true);
      if (document.fonts) document.fonts.ready.then(schedule);
      schedule();
    })();
    """#
}

private final class WeakAlertSizeHandler: NSObject, WKScriptMessageHandler {
    weak var target: AlertCanvasView?
    init(_ target: AlertCanvasView) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

struct AlertWebView: UIViewRepresentable {
    let url: URL
    @Binding var reloadToken: UUID
    func makeUIView(context: Context) -> AlertCanvasView {
        let view = AlertCanvasView()
        view.load(url: url, reloadToken: reloadToken)
        return view
    }
    func updateUIView(_ view: AlertCanvasView, context: Context) {
        view.load(url: url, reloadToken: reloadToken)
    }
    static func dismantleUIView(_ view: AlertCanvasView, coordinator: ()) { view.stop() }
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
        }
        .padding(8)
        .background(.clear)
    }
}

#if DEBUG
struct AlertLayoutFixture: UIViewRepresentable {
    func makeUIView(context: Context) -> AlertCanvasView {
        let view = AlertCanvasView()
        view.web.loadHTMLString(#"""
        <!doctype html><html><head><style>
        html,body {margin:0;background:transparent;}
        #canvas {position:relative;width:1920px;height:1080px;background:#153854;color:white;box-sizing:border-box;border:12px solid #31dfba;}
        span {position:absolute;font:52px sans-serif;padding:16px;}
        .left{left:0}.right{right:0}.top{top:0}.bottom{bottom:0}
        </style></head><body><div id="canvas">
        <span class="top left">TOP LEFT</span><span class="top right">TOP RIGHT</span>
        <span class="bottom left">BOTTOM LEFT</span><span class="bottom right">BOTTOM RIGHT</span>
        </div></body></html>
        """#, baseURL: nil)
        return view
    }
    func updateUIView(_ view: AlertCanvasView, context: Context) {}
    static func dismantleUIView(_ view: AlertCanvasView, coordinator: ()) { view.stop() }
}
#endif
