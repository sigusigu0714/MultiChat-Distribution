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
    private var fitContent = false
    private var contentRect: CGRect?
    private var lastURL: URL?
    private var lastReloadToken: UUID?
    private var queueSource: UUID?
    func configureQueue(_ enabled: Bool) {
        guard enabled, queueSource == nil else { return }
        let id = UUID(); queueSource = id
        let controller = web.configuration.userContentController
        controller.add(AlertQueueBridge(source: id), name: "mcAlertBridge")
        if let path = Bundle.main.url(forResource: "alert-queue", withExtension: "js"),
           let script = try? String(contentsOf: path, encoding: .utf8) {
            controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        AlertPlaybackQueue.shared.register(id, web: web) { [weak self] visible in self?.alpha = visible ? 1 : 0 }
    }

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
        configureContentFit(host == "streamelements.com" || host.hasSuffix(".streamelements.com"))
        setNeedsLayout()
        layoutIfNeeded()
        web.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    func configureContentFit(_ enabled: Bool) {
        fitContent = enabled; contentRect = nil
        canvasSize = enabled ? CGSize(width: 1920, height: 1080) : AlertCanvasLayout.standard
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let focus = contentRect ?? CGRect(origin: .zero, size: canvasSize)
        let fitted = AlertCanvasLayout.fittedFrame(canvas: focus.size, container: bounds.size)
        guard fitted.width > 0 else { return }
        web.transform = .identity
        web.bounds = CGRect(origin: .zero, size: canvasSize)
        let scale = fitted.width / focus.width
        web.center = CGPoint(x: bounds.midX + (canvasSize.width / 2 - focus.midX) * scale,
                             y: bounds.midY + (canvasSize.height / 2 - focus.midY) * scale)
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
        canvasSize = next
        if fitContent {
            if let left = size["left"], let top = size["top"], let right = size["right"], let bottom = size["bottom"],
               [left, top, right, bottom].allSatisfy({ $0.isFinite }), right > left, bottom > top {
                let rect = CGRect(x: left, y: top, width: right-left, height: bottom-top).insetBy(dx: -24, dy: -24)
                let clipped = rect.intersection(CGRect(origin: .zero, size: canvasSize))
                contentRect = clipped.width > 1 && clipped.height > 1 ? clipped : nil
            } else { contentRect = nil }
        }
        setNeedsLayout()
    }

    func stop() {
        if let id = queueSource {
            queueSource = nil
            web.configuration.userContentController.removeScriptMessageHandler(forName: "mcAlertBridge")
            let oldWeb = web
            AlertPlaybackQueue.shared.unregister(id) { oldWeb?.stopLoading(); oldWeb?.loadHTMLString("", baseURL: nil) }
            return
        }
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
        const host = location.hostname.toLowerCase();
        const focus = host === 'streamelements.com' || host.endsWith('.streamelements.com') || location.protocol === 'about:';
        const measurement = focus ? (() => {
          const root = document.documentElement, body = document.body;
          const result = {width:Math.max(innerWidth,root.scrollWidth,body?body.scrollWidth:0),
            height:Math.max(innerHeight,root.scrollHeight,body?body.scrollHeight:0),viewportWidth:innerWidth};
          let box = null, visited = 0;
          const add = (r,ox,oy,sx,sy) => {
            const l=ox+r.left*sx,t=oy+r.top*sy,rr=ox+r.right*sx,b=oy+r.bottom*sy;
            if (![l,t,rr,b].every(Number.isFinite) || rr-l<1 || b-t<1 || rr<0 || b<0 || l>8192 || t>8192) return;
            if (!box) box={left:l,top:t,right:rr,bottom:b};
            else {box.left=Math.min(box.left,l);box.top=Math.min(box.top,t);box.right=Math.max(box.right,rr);box.bottom=Math.max(box.bottom,b);}
          };
          const scan = (doc,ox,oy,sx,sy,depth) => {
            const win=doc.defaultView;if(!doc.body || !win || depth>3) return;
            const cache=new WeakMap();
            const visible=el => {
              if(!el || el.nodeType!==1) return true;
              if(cache.has(el)) return cache.get(el);
              const s=win.getComputedStyle(el);
              const ok=s.display!=='none' && s.visibility!=='hidden' && Number(s.opacity)>.02 && visible(el.parentElement);
              cache.set(el,ok);return ok;
            };
            const walker=doc.createTreeWalker(doc.body,NodeFilter.SHOW_ELEMENT|NodeFilter.SHOW_TEXT);
            let node;
            while((node=walker.nextNode()) && ++visited<=3000) {
              if(node.nodeType===3) {
                const p=node.parentElement;
                if(!p || /^(SCRIPT|STYLE|NOSCRIPT|OPTION)$/.test(p.tagName) || !node.textContent.trim() || !visible(p))continue;
                const range=doc.createRange();range.selectNodeContents(node);
                for(const r of range.getClientRects())add(r,ox,oy,sx,sy);
              } else if(visible(node)) {
                const r=node.getBoundingClientRect();if(r.width<1 || r.height<1)continue;
                if(node.tagName==='IFRAME') {
                  try {
                    const child=node.contentDocument;
                    if(child && child.body && node.contentWindow.innerWidth>0) {
                      scan(child,ox+r.left*sx,oy+r.top*sy,sx*r.width/node.contentWindow.innerWidth,sy*r.height/node.contentWindow.innerHeight,depth+1);
                      continue;
                    }
                  }catch(_){}
                  // Cross-origin frames cannot be inspected; preserve their full rectangle.
                  add(r,ox,oy,sx,sy);continue;
                }
                const style=win.getComputedStyle(node);
                const image=/^(IMG|VIDEO|CANVAS|SVG)$/.test(node.tagName.toUpperCase());
                const background=style.backgroundImage!=='none' ||
                  (style.backgroundColor!=='transparent' && !/rgba\([^)]*,\s*0\s*\)/.test(style.backgroundColor));
                if(image || background)add(r,ox,oy,sx,sy);
              }
            }
          };
          scan(document,0,0,1,1,0);
          if(box) Object.assign(result,box);
          return result;
        })() : {width, height};
        const key = JSON.stringify(measurement);
        if (key === previous) return;
        previous = key;
        window.webkit.messageHandlers.alertCanvasSize.postMessage(measurement);
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
      setInterval(schedule, 400);
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
    var sequential = false
    func makeUIView(context: Context) -> AlertCanvasView {
        let view = AlertCanvasView()
        view.configureQueue(sequential)
        view.load(url: url, reloadToken: reloadToken)
        return view
    }
    func updateUIView(_ view: AlertCanvasView, context: Context) {
        view.load(url: url, reloadToken: reloadToken)
    }
    static func dismantleUIView(_ view: AlertCanvasView, coordinator: ()) { view.stop() }
}

func validAlertWidgetURL(_ raw: String) -> URL? {
    guard !raw.isEmpty, !raw.contains(where: { $0.isWhitespace }),
          let parts = URLComponents(string: raw), parts.scheme == "https",
          let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
          let url = parts.url else { return nil }
    return url
}

struct AlertOverlay: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        ZStack {
            ForEach(0..<5, id: \.self) { index in
                if let url = validAlertWidgetURL(store.standaloneWidgetURLs[index]) {
                    AlertWebView(url: url, reloadToken: $store.alertReloadToken, sequential: store.sequentialAlerts)
                        .id("\(store.alertReloadToken)-\(store.sequentialAlerts)-\(index)")
                        .allowsHitTesting(false)
                        .opacity(store.alertsVisible ? 1 : 0)
                }
            }
            ForEach(store.channels.filter { $0.enabled }) { channel in
                if let raw = KeychainStore.read(channel.alertURLKey), let url = URL(string: raw), !raw.isEmpty {
                    AlertWebView(url: url, reloadToken: $store.alertReloadToken, sequential: store.sequentialAlerts)
                        .id("\(store.alertReloadToken)-\(store.sequentialAlerts)-\(channel.id)")
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
struct AlertFocusFixture: UIViewRepresentable {
    func makeUIView(context: Context) -> AlertCanvasView {
        let view = AlertCanvasView(); view.configureContentFit(true)
        view.web.loadHTMLString(#"""
        <!doctype html><html><head><style>
        html,body {margin:0;background:transparent;width:1920px;height:1080px;}
        #alert {position:absolute;left:70px;top:440px;width:500px;height:210px;background:#163955;color:white;border:4px solid #25dfa6;box-sizing:border-box;}
        .media {width:140px;height:120px;margin:12px auto;background:#f5a34c;border-radius:28px;}
        p {font:24px sans-serif;margin:0;text-align:center;}
        </style></head><body><div id="alert"><div class="media"></div><p>ALERT CONTENT</p></div></body></html>
        """#, baseURL:nil)
        return view
    }
    func updateUIView(_ view: AlertCanvasView, context: Context) {}
    static func dismantleUIView(_ view: AlertCanvasView, coordinator: ()) { view.stop() }
}
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
