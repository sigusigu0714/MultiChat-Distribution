import Foundation
import SwiftUI

private enum OBSIntegrationConfig {
    static let defaultRelayURL = "wss://example.invalid/obsremote/ws"
}
private enum SecureValueStore {
    static var values: [String: String] = [:]
    static func read(_ key: String) -> String? { values[key] }
    static func write(_ value: String, key: String) { values[key] = value }
    static func delete(_ key: String) { values[key] = nil }
}

// PRODUCTION_CONTROLLER

final class MockSocket: OBSWebSocket, @unchecked Sendable {
    var packets: [[String: Any]] = []
    var receiver: ((Result<URLSessionWebSocketTask.Message, Error>) -> Void)?
    var sendCallbacks: [(Error?) -> Void] = []
    var cancelled = false
    func resume() {}
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) { cancelled = true }
    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void) {
        if case .string(let text) = message {
            packets.append(try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any])
        }
        sendCallbacks.append(completionHandler)
    }
    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        receiver = completionHandler
    }
    func emit(_ text: String) {
        let callback = receiver
        receiver = nil
        callback?(.success(.string(text)))
    }
}
final class MockSession {
    var sockets: [MockSocket] = []
    func webSocketTask(with url: URL) -> any OBSWebSocket {
        let socket = MockSocket()
        sockets.append(socket)
        return socket
    }
}

@main
struct ControllerRegressionTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ description: String) {
            precondition(value, description)
            checks += 1
            print("PASS: " + description)
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(30)) }
        let session = MockSession()
        let remote = OBSRemoteController(makeSocket: { session.webSocketTask(with: $0) })
        remote.serverURL = "wss://example.invalid/obsremote/ws"
        remote.command("start_stream")
        check(session.sockets.isEmpty, "Disconnected commands are not sent")
        remote.connect()
        check(session.sockets.isEmpty, "Missing token prevents connection")
        remote.adminToken = "test-only-token"
        remote.serverURL = "https://example.invalid"
        remote.connect()
        check(session.sockets.isEmpty, "Non-WSS URLs are rejected")
        remote.serverURL = "wss://example.invalid/obsremote/ws"
        remote.connect()
        let first = session.sockets[0]
        check(first.packets[0]["type"] as? String == "auth", "Authentication packet is sent first")
        first.emit(#"{"type":"auth_ok","agentOnline":true}"#)
        await settle()
        check(remote.connected && remote.agentOnline, "Authentication establishes relay and agent state")
        check(first.packets.last?["action"] as? String == "refresh", "Authentication requests fresh OBS state")
        first.emit(#"{"type":"state","obsOnline":true,"streaming":false,"currentScene":"Main","scenes":["Main","BRB"],"sources":[{"name":"Camera","enabled":true}]}"#)
        await settle()
        check(remote.obsReady && remote.state.sources.count == 1, "Agent state schema decodes")
        for action in ["start_stream", "stop_stream", "set_scene", "set_source_visible", "twitch_fix", "kick_fix"] {
            remote.command(action, extra: ["sceneName": "Main", "sourceName": "Camera", "enabled": false])
            check(first.packets.last?["action"] as? String == action, action + " payload matches agent protocol")
        }
        check(first.packets.last?["enabled"] as? Bool == false, "Source visibility boolean is preserved")
        first.emit(#"{"type":"result","ok":false,"error":"Expected failure"}"#)
        await settle()
        check(remote.message == "Expected failure", "Command failure is displayed")
        first.emit(#"{"type":"agent_status","online":false}"#)
        await settle()
        check(!remote.obsReady && remote.state.sources.isEmpty, "Agent disconnection clears stale OBS state")
        let countBefore = first.packets.count
        remote.command("stop_stream")
        check(first.packets.count == countBefore, "Offline OBS cannot receive stream commands")
        first.emit(#"{"type":"agent_status","online":true}"#)
        await settle()
        check(first.packets.last?["action"] as? String == "refresh", "Agent recovery refreshes state")
        remote.connect()
        let second = session.sockets[1]
        first.receiver?(.failure(URLError(.cancelled)))
        first.sendCallbacks.first?(URLError(.cancelled))
        await settle()
        check(first.cancelled && !second.cancelled, "Old socket callbacks cannot cancel a new connection")
        second.emit(#"{"type":"auth_ok","agentOnline":true}"#)
        await settle()
        check(remote.connected, "New connection still authenticates after old callbacks")
        second.emit("not json")
        await settle()
        check(remote.connected, "Malformed packets do not crash the connection")
        remote.disconnect()
        remote.disconnect(shouldReconnect: false)
        try await Task.sleep(for: .milliseconds(3200))
        check(session.sockets.count == 2 && !remote.connected, "Explicit disconnect cancels pending reconnect")
        UserDefaults.standard.removeObject(forKey: "obsRemoteServerURL")
        print("All \(checks) OBS controller regression checks passed.")
    }
}