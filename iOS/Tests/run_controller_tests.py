from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / "iOS/MultiChatViewer/OBSRemoteView.swift").read_text()
start = source.index("struct OBSRemoteState:")
end = source.index("@MainActor\nfinal class TwitchCommentController")
controller = source[start:end]
harness = (root / "iOS/Tests/OBSControllerTests.swift").read_text()
with tempfile.TemporaryDirectory() as directory:
    test = Path(directory) / "Tests.swift"
    binary = Path(directory) / "Tests"
    test.write_text(harness.replace("// PRODUCTION_CONTROLLER", controller))
    subprocess.run(["swiftc", "-parse-as-library", "-swift-version", "5", str(test), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)