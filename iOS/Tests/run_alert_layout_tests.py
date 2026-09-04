from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / "iOS/MultiChatViewer/WebChatView.swift").read_text(encoding="utf-8")
layout = source[source.index("struct AlertCanvasLayout {"):source.index("final class AlertCanvasView:")]
validator = source[source.index("func validAlertWidgetURL("):source.index("struct AlertOverlay:")]

store_source = (root / "iOS/MultiChatViewer/ContentView.swift").read_text(encoding="utf-8")
slots = store_source[store_source.index('    @Published private(set) var doneruWidgetURL'):store_source.index('    @Published var serverURL')].replace('@Published ', '')
slots = """
final class KeychainStore {
    static var values: [String:String] = [:]
    static func read(_ key:String) -> String? { values[key] }
    static func write(_ key:String,value:String) { values[key] = value }
    static func delete(_ key:String) { values.removeValue(forKey:key) }
}
final class WidgetStoreTest {
    var alertsVisible = false
    var alertReloadToken = UUID()
""" + slots + "}\n"

tests = r"""
KeychainStore.write("doneru-widget-url",value:"https://example.invalid/existing")
let widgets = WidgetStoreTest()
precondition(widgets.standaloneWidgetURLs.count == 5)
precondition(widgets.standaloneWidgetURLs[0] == "https://example.invalid/existing")
for index in 0..<5 { precondition(widgets.saveStandaloneWidget(index, "https://example.invalid/widget-\(index)")) }
precondition(WidgetStoreTest().standaloneWidgetURLs == widgets.standaloneWidgetURLs)
precondition(!widgets.saveStandaloneWidget(5,"https://example.invalid/out-of-range"))
precondition(!widgets.saveStandaloneWidget(2,"http://example.invalid/unsafe"))
precondition(widgets.standaloneWidgetURLs[2] == "https://example.invalid/widget-2")
precondition(widgets.saveStandaloneWidget(2,""))
precondition(widgets.standaloneWidgetURLs.filter { !$0.isEmpty }.count == 4)
precondition(KeychainStore.read("standalone-widget-2") == nil)
print("PASS: five widget slots, existing URL migration, persistence, validation and independent deletion")
precondition(validAlertWidgetURL("https://example.com/alert-box?key=test-only") != nil)
for raw in ["", "http://example.com", "file:///tmp/test", "https://name:password@example.com", "https://example.com/with space"] {
    precondition(validAlertWidgetURL(raw) == nil)
}

let canvases = [CGSize(width: 800, height: 600), CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920), CGSize(width: 4096, height: 600)]
let screens = [CGSize(width: 304, height: 460), CGSize(width: 377, height: 700), CGSize(width: 700, height: 300), CGSize(width: 414, height: 780)]
for canvas in canvases {
    for screen in screens {
        let frame = AlertCanvasLayout.fittedFrame(canvas: canvas, container: screen)
        precondition(frame.minX >= -0.001 && frame.minY >= -0.001)
        precondition(frame.maxX <= screen.width + 0.001 && frame.maxY <= screen.height + 0.001)
        precondition(abs(frame.width / frame.height - canvas.width / canvas.height) < 0.0001)
        precondition(abs(frame.midX - screen.width / 2) < 0.001)
        precondition(abs(frame.midY - screen.height / 2) < 0.001)
    }
}
precondition(AlertCanvasLayout.fittedFrame(canvas: .zero, container: screens[0]) == .zero)
precondition(AlertCanvasLayout.fittedFrame(canvas: canvases[0], container: .zero) == .zero)
print("PASS: 16 canvas/screen combinations preserve aspect ratio and all edges; zero-size layout is safe")
"""
with tempfile.TemporaryDirectory() as directory:
    test = Path(directory) / "main.swift"
    test.write_text("import Foundation\nimport CoreGraphics\n" + layout + validator + slots + tests, encoding="utf-8")
    binary = Path(directory) / "Tests"
    subprocess.run(["swiftc", str(test), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
