import Foundation
import WebKit
import Combine
import SwiftUI

/// Opaque document IDs only. Notification contents remain inside their WebViews.
final class AlertPlaybackQueue: ObservableObject {
    static let shared = AlertPlaybackQueue()
    struct Ticket: Equatable { let source: UUID; let sequence: Int64 }
    final class Player {
        weak var web: WKWebView?
        let show: (Bool) -> Void
        var last: Int64 = 0
        init(web: WKWebView, show: @escaping (Bool) -> Void) { self.web = web; self.show = show }
    }
    @Published private(set) var status = "順番再生：接続待ち"
    private var players: [UUID: Player] = [:]
    private var waiting: [Ticket] = []
    private var active: Ticket?
    private var stopping = false
    private var failed = false
    private var hasPassThrough = false

    func register(_ id: UUID, web: WKWebView, show: @escaping (Bool) -> Void) {
        failed = false
        players[id] = Player(web: web, show: show)
        show(false)
        web.setAllMediaPlaybackSuspended(true, completionHandler: {})
    }
    func receive(_ raw: String, source: UUID) {
        guard !failed, raw.utf8.count <= 256, let player = players[source],
              let data = raw.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return }
        let sequence = (event["sequence"] as? NSNumber)?.int64Value ?? 0
        switch type {
        case "ready": report()
        case "unsupported": passThrough(source)
        case "fault": fault()
        case "stalled":
            if active == Ticket(source: source, sequence: sequence) { status = "通知の終了待ちが長くなっています。停止した場合は設定から再読み込みしてください。" }
        case "request":
            guard sequence > player.last, sequence <= 9_007_199_254_740_991 else { return }
            if waiting.count >= 256 {
                player.web?.evaluateJavaScript("window.__mcAlertQueue?.retry(\(sequence))", completionHandler: nil)
                return
            }
            player.last = sequence
            waiting.append(Ticket(source: source, sequence: sequence)); drain()
            player.web?.evaluateJavaScript("window.__mcAlertQueue?.accepted(\(sequence))", completionHandler: nil)
        case "done":
            guard active == Ticket(source: source, sequence: sequence), !stopping else { return }
            stopping = true
            player.show(false)
            player.web?.setAllMediaPlaybackSuspended(true) { [weak self] in
                guard let self, self.active == Ticket(source: source, sequence: sequence) else { return }
                self.active = nil; self.stopping = false; self.drain()
            }
        default: break
        }
    }
    private func passThrough(_ id: UUID) {
        waiting.removeAll { $0.source == id }
        guard let player = players.removeValue(forKey: id), active?.source != id else { return }
        hasPassThrough = true
        player.web?.setAllMediaPlaybackSuspended(false) { player.show(true) }
        report()
    }
    func unregister(_ id: UUID, after: @escaping () -> Void) {
        waiting.removeAll { $0.source == id }
        guard let player = players.removeValue(forKey: id) else { after(); return }
        player.show(false)
        if active?.source == id { stopping = true }
        guard let web = player.web else { after(); return }
        web.setAllMediaPlaybackSuspended(true) { [weak self] in
            if self?.active?.source == id { self?.active = nil; self?.stopping = false }
            after(); self?.drain()
        }
    }
    private func drain() {
        guard !failed else { return }
        if active == nil && !waiting.isEmpty {
            let next = waiting.removeFirst()
            guard let player = players[next.source], let web = player.web else { fault(); return }
            active = next
            web.setAllMediaPlaybackSuspended(false) { [weak self, weak web] in
                guard let self, !self.failed, self.active == next, !self.stopping else { return }
                player.show(true)
                web?.evaluateJavaScript("window.__mcAlertQueue?.grant(\(next.sequence))") { _, error in
                    if error != nil { self.fault() }
                }
            }
        }
        report()
    }
    private func report() {
        if !failed { status = hasPassThrough ? "順番再生：一部は通常表示・その他は順番再生（待ち \(waiting.count) 件）" : "順番再生：\(active == nil ? "待機中" : "再生中")・待ち \(waiting.count) 件" }
    }
    private func fault() {
        failed = true
        status = "順番再生を停止しました。未対応の形式または終了を確認できません。再読み込み、または順番再生をオフにしてください。"
        waiting.removeAll()
        players.values.forEach { player in
            player.show(false)
            player.web?.setAllMediaPlaybackSuspended(true, completionHandler: {})
        }
    }
}

struct AlertQueueStatusView: View {
    @ObservedObject private var queue = AlertPlaybackQueue.shared
    var body: some View { Text(queue.status).font(.caption) }
}

final class AlertQueueBridge: NSObject, WKScriptMessageHandler {
    let source: UUID
    init(source: UUID) { self.source = source }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let raw = message.body as? String else { return }
        AlertPlaybackQueue.shared.receive(raw, source: source)
    }
}
