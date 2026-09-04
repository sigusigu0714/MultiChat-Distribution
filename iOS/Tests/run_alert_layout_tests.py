from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / "iOS/MultiChatViewer/WebChatView.swift").read_text(encoding="utf-8")
layout = source[source.index("struct AlertCanvasLayout {"):source.index("final class AlertCanvasView:")]
validator = source[source.index("func validAlertWidgetURL("):source.index("struct AlertOverlay:")]

tests = r"""
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
    test.write_text("import Foundation\nimport CoreGraphics\n" + layout + validator + tests, encoding="utf-8")
    binary = Path(directory) / "Tests"
    subprocess.run(["swiftc", str(test), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
