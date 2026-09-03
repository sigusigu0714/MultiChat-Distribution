from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'iOS/MultiChatViewer/OBSRemoteView.swift').read_text()
start = source.index('struct DistributionProfile:')
end = source.index('struct DistributionSetupView:')
tests = r"""
func accept(_ json: String) throws { _ = try DistributionProfile.read(Data(json.utf8)) }
func reject(_ json: String) {
    do { try accept(json); fatalError("Unsafe profile was accepted") } catch {}
}
try accept(#"{"serverURL":"https://chat.example.com"}"#)
try accept(#"{"serverURL":"https://chat.example.com","obsRelayURL":"wss://relay.example.com/obsremote/ws","twitchClientID":"exampleclient","twitchRedirectURI":"https://chat.example.com/oauth/callback"}"#)
reject(#"{"serverURL":"http://chat.example.com"}"#)
reject(#"{"serverURL":"https://user:password@chat.example.com"}"#)
reject(#"{"serverURL":"https://chat.example.com?token=secret"}"#)
reject(#"{"serverURL":"https://chat.example.com","adminToken":"secret"}"#)
reject(#"{"serverURL":"https://chat.example.com","twitchClientID":"exampleclient"}"#)
reject(#"{"serverURL":"https://chat.example.com","obsRelayURL":"ws://relay.example.com"}"#)
reject(String(repeating: " ", count: 20_000))
print("PASS: distribution profile validation and credential rejection")
"""
with tempfile.TemporaryDirectory() as directory:
    test = Path(directory) / 'main.swift'
    test.write_text('import Foundation\n' + source[start:end] + tests)
    binary = Path(directory) / 'Tests'
    subprocess.run(['swiftc', str(test), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
