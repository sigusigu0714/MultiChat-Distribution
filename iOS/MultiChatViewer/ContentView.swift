import SwiftUI
import Security
import AVFoundation
import AuthenticationServices
import UserNotifications
import NaturalLanguage
import Translation

@MainActor
final class AppStore: ObservableObject {
    @Published var channels: [ChannelConfig] = [] { didSet { saveChannels() } }
    @Published var events: [UnifiedEvent] = []

    @Published var serverURL =
        UserDefaults.standard.string(forKey: "serverURL")
        ?? ""

    @Published var status = "未接続"

    @Published var appearanceMode =
        UserDefaults.standard.string(forKey: "appearanceMode") ?? "system" {
            didSet { UserDefaults.standard.set(appearanceMode, forKey: "appearanceMode") }
        }

    @Published var keepScreenAwakeForAlerts =
        UserDefaults.standard.object(forKey: "keepScreenAwakeForAlerts") as? Bool ?? true {
            didSet {
                UserDefaults.standard.set(keepScreenAwakeForAlerts, forKey: "keepScreenAwakeForAlerts")
                updateIdleTimer()
            }
        }

    @Published var alertsVisible =
        UserDefaults.standard.object(forKey: "alertsVisible") as? Bool ?? true {
            didSet { UserDefaults.standard.set(alertsVisible, forKey: "alertsVisible") }
        }

    @Published var ttsEnabled =
        UserDefaults.standard.object(forKey: "ttsEnabled") as? Bool ?? false {
            didSet { UserDefaults.standard.set(ttsEnabled, forKey: "ttsEnabled") }
        }

    @Published var ttsReadNames =
        UserDefaults.standard.object(forKey: "ttsReadNames") as? Bool ?? true {
            didSet { UserDefaults.standard.set(ttsReadNames, forKey: "ttsReadNames") }
        }

    @Published var ttsReadAlerts =
        UserDefaults.standard.object(forKey: "ttsReadAlerts") as? Bool ?? true {
            didSet { UserDefaults.standard.set(ttsReadAlerts, forKey: "ttsReadAlerts") }
        }

    @Published var ttsRate =
        UserDefaults.standard.object(forKey: "ttsRate") as? Double ?? 0.50 {
            didSet { UserDefaults.standard.set(ttsRate, forKey: "ttsRate") }
        }

    @Published var ttsIgnoredUsers: [String] =
        UserDefaults.standard.stringArray(forKey: "ttsIgnoredUsers") ?? [] {
            didSet { UserDefaults.standard.set(ttsIgnoredUsers, forKey: "ttsIgnoredUsers") }
        }

    @Published var commentFontSize =
        UserDefaults.standard.object(forKey: "commentFontSize") as? Double ?? 17 {
            didSet { UserDefaults.standard.set(commentFontSize, forKey: "commentFontSize") }
        }

    @Published var commentDensity =
        UserDefaults.standard.string(forKey: "commentDensity") ?? "standard" {
            didSet { UserDefaults.standard.set(commentDensity, forKey: "commentDensity") }
        }

    @Published var autoTranslateEnabled =
        UserDefaults.standard.object(forKey: "autoTranslateEnabled") as? Bool ?? false {
            didSet { UserDefaults.standard.set(autoTranslateEnabled, forKey: "autoTranslateEnabled") }
        }

    @Published var translationOriginalVisible =
        UserDefaults.standard.object(forKey: "translationOriginalVisible") as? Bool ?? true {
            didSet { UserDefaults.standard.set(translationOriginalVisible, forKey: "translationOriginalVisible") }
        }

    @Published var twitchIntegratedDedupe =
        UserDefaults.standard.object(forKey: "twitchIntegratedDedupe") as? Bool ?? true {
            didSet { UserDefaults.standard.set(twitchIntegratedDedupe, forKey: "twitchIntegratedDedupe") }
        }

    @Published var duplicateWindow =
        UserDefaults.standard.object(forKey: "duplicateWindow") as? Double ?? 2.5 {
            didSet { UserDefaults.standard.set(duplicateWindow, forKey: "duplicateWindow") }
        }

    @Published var hiddenDuplicateCount = 0
    @Published var alertReloadToken = UUID()
    @Published var selectedFilter: Platform? = nil
    @Published var showConnectSheet = false
    @Published var oauthMessage: String?
    @Published var isAuthorizing = false
    @Published var kickSending = false
    @Published var kickSendStatus = "KICK未送信"

    private var socket: URLSessionWebSocketTask?
    private var reconnect: Task<Void, Never>?
    private let speaker = AVSpeechSynthesizer()
    private var recentFingerprints: [String: Date] = [:]
    private var seenSourceMessageIDs = Set<String>()
    private var authSession: ASWebAuthenticationSession?
    private let authPresenter = AuthPresentationContextProvider()

    init() {
        loadChannels()
        updateIdleTimer()

        try? AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: .spokenAudio,
            options: [.duckOthers]
        )
        try? AVAudioSession.sharedInstance().setActive(true)

        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in }
    }

    var preferredColorScheme: ColorScheme? {
        switch appearanceMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = keepScreenAwakeForAlerts
    }

    private func loadChannels() {
        if let data = UserDefaults.standard.data(forKey: "channels"),
           let saved = try? JSONDecoder().decode([ChannelConfig].self, from: data) {
            channels = saved
        }
    }

    private func saveChannels() {
        if let data = try? JSONEncoder().encode(channels) {
            UserDefaults.standard.set(data, forKey: "channels")
        }
    }

    func saveServerURL() {
        UserDefaults.standard.set(serverURL, forKey: "serverURL")
    }

    var configuredServerURL: URL? {
        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil else { return nil }
        return url
    }

    func connect() {
        disconnect()
        guard configuredServerURL != nil else {
            status = "設定からご自身のHTTPSサーバーURLを入力してください"
            return
        }

        guard let baseURL = configuredServerURL,
              var components = URLComponents(
                url: baseURL,
                resolvingAgainstBaseURL: false
              ) else {
            status = "URLエラー"
            return
        }

        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/ws"

        guard let url = components.url else {
            status = "URLエラー"
            return
        }

        status = "接続中…"

        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        task.resume()
        receiveLoop()
    }

    func disconnect() {
        reconnect?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        status = "未接続"
    }

    private func receiveLoop() {
        socket?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }

                switch result {
                case .success(let message):
                    self.status = "接続済み"

                    let data: Data?
                    switch message {
                    case .string(let string):
                        data = string.data(using: .utf8)
                    case .data(let raw):
                        data = raw
                    @unknown default:
                        data = nil
                    }

                    if let data,
                       let event = try? JSONDecoder.iso8601.decode(
                        UnifiedEvent.self,
                        from: data
                       ),
                       !self.events.contains(where: { $0.id == event.id }) {

                        if self.shouldDisplay(event) {
                            self.events.append(event)

                            if self.events.count > 1000 {
                                self.events.removeFirst(
                                    self.events.count - 1000
                                )
                            }

                            self.speak(event)
                            self.notifyIfNeeded(event)
                        } else {
                            self.hiddenDuplicateCount += 1
                        }
                    }

                    self.receiveLoop()

                case .failure:
                    self.status = "再接続中…"
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func scheduleReconnect() {
        reconnect?.cancel()

        reconnect = Task {
            try? await Task.sleep(for: .seconds(3))

            if !Task.isCancelled {
                connect()
            }
        }
    }

    func oauthURL(platform: Platform) -> URL? {
        guard configuredServerURL != nil else { return nil }
        guard var components = URLComponents(string: serverURL) else {
            return nil
        }

        components.path =
            "/oauth/\(platform.rawValue.lowercased())/start"

        components.queryItems = [
            URLQueryItem(
                name: "return_to",
                value: "multichat://oauth-complete"
            )
        ]

        return components.url
    }

    func startOAuth(_ platform: Platform) {
        guard let url = oauthURL(platform: platform) else {
            oauthMessage = "サーバーURLを確認してください"
            return
        }

        isAuthorizing = true

        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: "multichat"
        ) { [weak self] callback, error in
            Task { @MainActor in
                guard let self else { return }

                self.isAuthorizing = false

                if let callback {
                    self.handleDeepLink(callback)
                } else if let error,
                          (error as? ASWebAuthenticationSessionError)?.code
                          != .canceledLogin {
                    self.oauthMessage =
                        "ログインに失敗しました: \(error.localizedDescription)"
                }
            }
        }

        session.prefersEphemeralWebBrowserSession = false
        session.presentationContextProvider = authPresenter
        authSession = session
        session.start()
    }

    func sendKickComment(
        _ message: String,
        accountID: String
    ) async {
        let clean = message.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !clean.isEmpty, clean.count <= 500 else {
            kickSendStatus = "コメントは1〜500文字で入力してください"
            return
        }

        guard !accountID.isEmpty,
              var components = URLComponents(string: serverURL) else {
            kickSendStatus = "KICK連携アカウントとサーバーURLを確認してください"
            return
        }

        components.path = "/api/kick/chat"

        guard let url = components.url else {
            kickSendStatus = "サーバーURLが不正です"
            return
        }

        kickSending = true
        defer { kickSending = false }

        do {
            guard let sendKey = KeychainStore.read("kick_send_key_\(accountID)"),
                  !sendKey.isEmpty else {
                kickSendStatus = "KICKをアプリから再連携してください"
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(sendKey, forHTTPHeaderField: "X-Account-Send-Key")
            request.httpBody = try JSONSerialization.data(
                withJSONObject: [
                    "accountId": accountID,
                    "content": clean
                ]
            )

            let (data, response) = try await URLSession.shared.data(for: request)
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                kickSendStatus = object?["message"] as? String ?? "KICK送信に失敗しました"
                return
            }

            kickSendStatus = "KICKへ送信しました"
        } catch {
            kickSendStatus = "KICK送信失敗: \(error.localizedDescription)"
        }
    }

    func syncAccountsFromServer() async {
        guard configuredServerURL != nil else { return }
        guard var components = URLComponents(string: serverURL) else { return }
        components.path = "/api/accounts"
        guard let url = components.url else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)

            struct ServerAccount: Decodable {
                let id: String
                let platform: String
                let displayName: String
                let channelIdentifier: String
            }

            let accounts = try JSONDecoder().decode(
                [ServerAccount].self,
                from: data
            )

            for account in accounts.prefix(10) {
                let platform: Platform

                if account.platform == "youtube" {
                    platform = .youtube
                } else if account.platform == "kick" {
                    platform = .kick
                } else {
                    platform = .twitch
                }

                if !channels.contains(
                    where: { $0.serverAccountID == account.id }
                ),
                   channels.count < 10 {
                    channels.append(
                        ChannelConfig(
                            name: account.displayName,
                            platform: platform,
                            channelIdentifier: account.channelIdentifier,
                            serverAccountID: account.id
                        )
                    )
                }
            }
        } catch {
        }

        await syncTwitchWatchChannels()
        await syncYouTubeWatchChannels()
    }

    func syncTwitchWatchChannels() async {
        guard var components = URLComponents(string: serverURL) else { return }
        components.path = "/api/twitch/watch-channels"
        guard let url = components.url else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)

            struct Watch: Decodable {
                let id: String
                let login: String
                let displayName: String
                let externalUserId: String
            }

            let watches = try JSONDecoder().decode([Watch].self, from: data)

            for watch in watches {
                if !channels.contains(
                    where: {
                        $0.serverWatchID == watch.id ||
                        (
                            $0.platform == .twitch &&
                            $0.channelIdentifier.lowercased()
                            == watch.login.lowercased()
                        )
                    }
                ),
                   channels.count < 10 {
                    var channel = ChannelConfig(
                        name: watch.displayName,
                        platform: .twitch,
                        channelIdentifier: watch.login
                    )
                    channel.serverWatchID = watch.id
                    channel.serverWatchPlatform = .twitch
                    channels.append(channel)
                }
            }
        } catch {
        }
    }

    func addTwitchWatchChannel(_ rawLogin: String) async -> Bool {
        let login = rawLogin
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "")

        guard !login.isEmpty else {
            oauthMessage = "Twitchチャンネル名を入力してください"
            return false
        }

        guard channels.count < 10 else {
            oauthMessage = "最大10チャンネルです"
            return false
        }

        guard var components = URLComponents(string: serverURL) else {
            return false
        }

        components.path = "/api/twitch/watch-channels"

        guard let url = components.url else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["login": login]
        )

        do {
            let (data, response) = try await URLSession.shared.data(
                for: request
            )

            guard let http = response as? HTTPURLResponse else {
                return false
            }

            if !(200..<300).contains(http.statusCode) {
                let object =
                    (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any]

                oauthMessage =
                    object?["message"] as? String
                    ?? "チャンネル追加に失敗しました"

                return false
            }

            struct Watch: Decodable {
                let id: String
                let login: String
                let displayName: String
                let externalUserId: String
            }

            let watch = try JSONDecoder().decode(Watch.self, from: data)

            if !channels.contains(
                where: {
                    $0.platform == .twitch &&
                    $0.channelIdentifier.lowercased()
                    == watch.login.lowercased()
                }
            ) {
                var channel = ChannelConfig(
                    name: watch.displayName,
                    platform: .twitch,
                    channelIdentifier: watch.login
                )
                channel.serverWatchID = watch.id
                channel.serverWatchPlatform = .twitch
                channels.append(channel)
            }

            oauthMessage =
                "\(watch.displayName) を監視チャンネルに追加しました"

            return true

        } catch {
            oauthMessage =
                "チャンネル追加に失敗しました: \(error.localizedDescription)"
            return false
        }
    }

    func syncYouTubeWatchChannels() async {
        guard var components = URLComponents(string: serverURL) else { return }
        components.path = "/api/youtube/watch-channels"
        guard let url = components.url else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)

            struct Watch: Decodable {
                let id: String
                let channelIdentifier: String
                let displayName: String
                let externalUserId: String
            }

            let watches = try JSONDecoder().decode([Watch].self, from: data)

            for watch in watches {
                if !channels.contains(
                    where: {
                        $0.serverWatchID == watch.id ||
                        (
                            $0.platform == .youtube &&
                            $0.channelIdentifier == watch.channelIdentifier
                        )
                    }
                ),
                   channels.count < 10 {
                    var channel = ChannelConfig(
                        name: watch.displayName,
                        platform: .youtube,
                        channelIdentifier: watch.channelIdentifier
                    )
                    channel.serverWatchID = watch.id
                    channel.serverWatchPlatform = .youtube
                    channels.append(channel)
                }
            }
        } catch {
        }
    }

    func addYouTubeWatchChannel(_ raw: String) async -> Bool {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !input.isEmpty else {
            oauthMessage =
                "YouTubeの@ハンドルまたはチャンネルURLを入力してください"
            return false
        }

        guard channels.count < 10 else {
            oauthMessage = "最大10チャンネルです"
            return false
        }

        guard var components = URLComponents(string: serverURL) else {
            return false
        }

        components.path = "/api/youtube/watch-channels"

        guard let url = components.url else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["channel": input]
        )

        do {
            let (data, response) = try await URLSession.shared.data(
                for: request
            )

            guard let http = response as? HTTPURLResponse else {
                return false
            }

            if !(200..<300).contains(http.statusCode) {
                let object =
                    (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any]

                oauthMessage =
                    object?["message"] as? String
                    ?? "YouTubeチャンネル追加に失敗しました"

                return false
            }

            struct Watch: Decodable {
                let id: String
                let channelIdentifier: String
                let displayName: String
                let externalUserId: String
            }

            let watch = try JSONDecoder().decode(Watch.self, from: data)

            if !channels.contains(
                where: {
                    $0.platform == .youtube &&
                    $0.channelIdentifier == watch.channelIdentifier
                }
            ) {
                var channel = ChannelConfig(
                    name: watch.displayName,
                    platform: .youtube,
                    channelIdentifier: watch.channelIdentifier
                )
                channel.serverWatchID = watch.id
                channel.serverWatchPlatform = .youtube
                channels.append(channel)
            }

            oauthMessage =
                "\(watch.displayName) をYouTube監視チャンネルに追加しました"

            return true

        } catch {
            oauthMessage =
                "YouTubeチャンネル追加に失敗しました: \(error.localizedDescription)"
            return false
        }
    }

    func handleDeepLink(_ url: URL) {
        guard url.scheme == "multichat" else { return }

        let query =
            URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )?.queryItems ?? []

        let platformString =
            query.first(where: { $0.name == "platform" })?.value
            ?? "アカウント"

        let name =
            query.first(where: { $0.name == "name" })?.value
            ?? platformString

        let identifier =
            query.first(where: { $0.name == "channel" })?.value
            ?? ""

        let accountID =
            query.first(where: { $0.name == "account_id" })?.value

        let sendKey =
            query.first(where: { $0.name == "send_key" })?.value

        let lower = platformString.lowercased()

        let platform: Platform

        if lower.contains("youtube") {
            platform = .youtube
        } else if lower.contains("kick") {
            platform = .kick
        } else {
            platform = .twitch
        }

        if platform == .kick,
           let accountID,
           let sendKey,
           !sendKey.isEmpty {
            KeychainStore.write(
                "kick_send_key_\(accountID)",
                value: sendKey
            )
        }

        if let index = channels.firstIndex(
            where: {
                $0.platform == platform &&
                $0.channelIdentifier == identifier
            }
        ) {
            channels[index].serverAccountID = accountID
        } else if channels.count < 10 {
            channels.append(
                ChannelConfig(
                    name: name,
                    platform: platform,
                    channelIdentifier: identifier,
                    serverAccountID: accountID
                )
            )
        }

        oauthMessage = "\(name) を連携しました"
        connect()
    }

    func removeChannel(at offsets: IndexSet) {
        let targets = offsets.map { channels[$0] }

        for channel in targets {
            KeychainStore.delete(channel.alertURLKey)

            if channel.platform == .kick,
               let accountID = channel.serverAccountID {
                KeychainStore.delete("kick_send_key_\(accountID)")
            }

            if let watchID = channel.serverWatchID {
                Task {
                    guard var components =
                            URLComponents(string: serverURL) else {
                        return
                    }

                    let platform =
                        channel.serverWatchPlatform
                        ?? channel.platform

                    components.path =
                        platform == .youtube
                        ? "/api/youtube/watch-channels/\(watchID)"
                        : "/api/twitch/watch-channels/\(watchID)"

                    guard let url = components.url else {
                        return
                    }

                    var request = URLRequest(url: url)
                    request.httpMethod = "DELETE"

                    _ = try? await URLSession.shared.data(for: request)
                }

            } else if let accountID = channel.serverAccountID {
                Task {
                    guard var components =
                            URLComponents(string: serverURL) else {
                        return
                    }

                    components.path = "/api/accounts/\(accountID)"

                    guard let url = components.url else {
                        return
                    }

                    var request = URLRequest(url: url)
                    request.httpMethod = "DELETE"

                    _ = try? await URLSession.shared.data(for: request)
                }
            }
        }

        channels.remove(atOffsets: offsets)
    }

    private func shouldDisplay(_ event: UnifiedEvent) -> Bool {
        if event.kind == .system {
            return false
        }

        if let sourceID = event.sourceMessageID,
           !sourceID.isEmpty {
            let scoped =
                "\(event.platform.rawValue)|\(sourceID)"

            if seenSourceMessageIDs.contains(scoped) {
                return false
            }

            seenSourceMessageIDs.insert(scoped)

            if seenSourceMessageIDs.count > 5000 {
                seenSourceMessageIDs.removeAll(
                    keepingCapacity: true
                )
            }
        }

        guard twitchIntegratedDedupe,
              event.platform == .twitch,
              event.kind == .chat else {
            return true
        }

        let user =
            normalizeForDedupe(event.userName)

        let message =
            normalizeForDedupe(event.message)

        guard !message.isEmpty else {
            return true
        }

        let fingerprint =
            "twitch|\(user)|\(message)"

        let now =
            event.timestamp

        recentFingerprints =
            recentFingerprints.filter {
                now.timeIntervalSince($0.value)
                <= max(
                    duplicateWindow * 4,
                    10
                )
            }

        if let last = recentFingerprints[fingerprint],
           abs(now.timeIntervalSince(last))
           <= duplicateWindow {
            return false
        }

        recentFingerprints[fingerprint] = now

        return true
    }

    private func normalizeForDedupe(_ value: String) -> String {
        value
            .folding(
                options: [
                    .caseInsensitive,
                    .diacriticInsensitive,
                    .widthInsensitive
                ],
                locale: .current
            )
            .replacingOccurrences(
                of: "\\s+",
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )
    }

    private func notifyIfNeeded(_ event: UnifiedEvent) {
        guard event.isAlert else { return }

        let content =
            UNMutableNotificationContent()

        content.title =
            "\(event.platform.rawValue) / \(event.channelName)"

        content.body = [
            event.userName,
            event.amountText,
            event.message
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: " ・ ")

        content.sound = .default

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: event.id,
                content: content,
                trigger: nil
            )
        )
    }

    func testAlert() {
        alertReloadToken = UUID()
    }

    func stopSpeech() {
        speaker.stopSpeaking(at: .immediate)
    }

    func testSpeech() {
        speakText("読み上げテストです")
    }

    private func speak(_ event: UnifiedEvent) {
        guard ttsEnabled,
              event.kind != .system,
              (ttsReadAlerts || !event.isAlert) else {
            return
        }

        let normalizedName =
            event.userName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

        let ignored =
            ttsIgnoredUsers.contains {
                $0
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                == normalizedName
            }

        guard !ignored else {
            return
        }

        var text = ""

        if event.isAlert {
            let amount =
                event.amountText.map { "、\($0)" }
                ?? ""

            text =
                "\(event.userName)さんから\(eventLabel(event.kind))\(amount)。\(event.message)"
        } else {
            text =
                ttsReadNames
                ? "\(event.userName)さん、\(event.message)"
                : event.message
        }

        text = sanitize(text)

        if text.count > 180 {
            text =
                String(text.prefix(180))
                + "、以下省略"
        }

        speakText(text)
    }

    private func speakText(_ text: String) {
        guard !text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty else {
            return
        }

        let utterance =
            AVSpeechUtterance(
                string: text
            )

        utterance.voice =
            AVSpeechSynthesisVoice(
                language: "ja-JP"
            )

        utterance.rate =
            Float(ttsRate)

        utterance.volume = 1.0

        speaker.speak(utterance)
    }

    private func sanitize(_ string: String) -> String {
        string
            .replacingOccurrences(
                of: "https?://\\S+",
                with: "URL",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "(.)\\1{5,}",
                with: "$1$1$1",
                options: .regularExpression
            )
    }

    private func eventLabel(_ kind: EventKind) -> String {
        switch kind {
        case .bits:
            return "ビッツ"
        case .subscription:
            return "サブスク"
        case .giftSubscription:
            return "ギフトサブ"
        case .donation:
            return "投げ銭"
        case .superChat:
            return "スーパーチャット"
        case .membership:
            return "メンバーシップ"
        case .follow:
            return "フォロー"
        case .raid:
            return "レイド"
        default:
            return "通知"
        }
    }
}

final class AuthPresentationContextProvider:
    NSObject,
    ASWebAuthenticationPresentationContextProviding {

    func presentationAnchor(
        for session: ASWebAuthenticationSession
    ) -> ASPresentationAnchor {
        UIApplication.shared
            .connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        ?? ASPresentationAnchor()
    }
}

extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

struct ContentView: View {
    @EnvironmentObject var store: AppStore
    @State private var showSettings = false
    @State private var showOBSRemote = false
    @State private var showCommentComposer = false

    var filtered: [UnifiedEvent] {
        store.events
            .filter {
                store.selectedFilter == nil
                || $0.platform == store.selectedFilter!
            }
            .sorted {
                $0.timestamp < $1.timestamp
            }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Button {
                            store.showConnectSheet = true
                        } label: {
                            Label(
                                "アカウント追加",
                                systemImage: "person.badge.plus"
                            )
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            store.ttsEnabled.toggle()

                            if !store.ttsEnabled {
                                store.stopSpeech()
                            }
                        } label: {
                            Image(
                                systemName:
                                    store.ttsEnabled
                                    ? "waveform.circle.fill"
                                    : "waveform.circle"
                            )
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("読み上げ")

                        Button {
                            store.alertsVisible.toggle()
                        } label: {
                            Image(
                                systemName:
                                    store.alertsVisible
                                    ? "bell.fill"
                                    : "bell.slash"
                            )
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("アラート")

                        Spacer()

                        Circle()
                            .fill(
                                store.status == "接続済み"
                                ? Color.green
                                : Color.orange
                            )
                            .frame(width: 9, height: 9)
                    }
                    .padding(10)

                    HStack {
                        Menu(
                            store.selectedFilter?.rawValue
                            ?? "すべて"
                        ) {
                            Button("すべて") {
                                store.selectedFilter = nil
                            }

                            ForEach(Platform.allCases) { platform in
                                Button(platform.rawValue) {
                                    store.selectedFilter = platform
                                }
                            }
                        }

                        Spacer()

                        Text(
                            "\(store.channels.count)/10 アカウント"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)

                    Divider()

                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(
                                spacing: rowSpacing
                            ) {
                                ForEach(filtered) { event in
                                    EventRow(ev: event)
                                        .id(event.id)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                        }
                        .onChange(of: filtered.last?.id) { _, id in
                            if let id {
                                withAnimation {
                                    proxy.scrollTo(
                                        id,
                                        anchor: .bottom
                                    )
                                }
                            }
                        }
                    }
                }

                AlertOverlay()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            .sheet(isPresented: $showOBSRemote) { OBSControlView() }
            .sheet(isPresented: $showCommentComposer) { TwitchCommentView() }
            .navigationTitle("MultiChat")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("送信") { showCommentComposer = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("OBS") { showOBSRemote = true }
                }
                ToolbarItem(
                    placement: .topBarTrailing
                ) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(
                            systemName: "gearshape.fill"
                        )
                    }
                }
            }
            .sheet(
                isPresented: $store.showConnectSheet
            ) {
                ConnectAccountView()
            }
            .sheet(
                isPresented: $showSettings
            ) {
                SimpleSettingsView()
            }
            .alert(
                "連携完了",
                isPresented:
                    Binding(
                        get: {
                            store.oauthMessage != nil
                        },
                        set: {
                            if !$0 {
                                store.oauthMessage = nil
                            }
                        }
                    )
            ) {
                Button(
                    "OK",
                    role: .cancel
                ) {
                }
            } message: {
                Text(
                    store.oauthMessage ?? ""
                )
            }
            .onOpenURL {
                store.handleDeepLink($0)
            }
            .task {
                store.connect()
                await store.syncAccountsFromServer()
            }
        }
    }

    private var rowSpacing: CGFloat {
        switch store.commentDensity {
        case "compact":
            return 1
        case "comfortable":
            return 10
        default:
            return 5
        }
    }
}

struct ConnectAccountView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    @State private var twitchChannel = ""
    @State private var youtubeChannel = ""
    @State private var addingTwitch = false
    @State private var addingYouTube = false

    var body: some View {
        NavigationStack {
            List {
                Section(
                    "他のTwitchチャンネル"
                ) {
                    TextField(
                        "チャンネル名（例: twitchdev）",
                        text: $twitchChannel
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    Button {
                        addingTwitch = true

                        Task {
                            let success =
                                await store.addTwitchWatchChannel(
                                    twitchChannel
                                )

                            addingTwitch = false

                            if success {
                                twitchChannel = ""
                                dismiss()
                            }
                        }
                    } label: {
                        Label(
                            addingTwitch
                            ? "追加中…"
                            : "チャンネル名で追加",
                            systemImage: "plus.circle.fill"
                        )
                    }
                    .disabled(
                        twitchChannel
                            .trimmingCharacters(
                                in: .whitespacesAndNewlines
                            )
                            .isEmpty
                        || addingTwitch
                        || store.channels.count >= 10
                    )
                }

                Section(
                    "他のYouTubeチャンネル"
                ) {
                    TextField(
                        "@ハンドル または チャンネルURL",
                        text: $youtubeChannel
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                    Button {
                        addingYouTube = true

                        Task {
                            let success =
                                await store.addYouTubeWatchChannel(
                                    youtubeChannel
                                )

                            addingYouTube = false

                            if success {
                                youtubeChannel = ""
                                dismiss()
                            }
                        }
                    } label: {
                        Label(
                            addingYouTube
                            ? "追加中…"
                            : "YouTubeチャンネルを追加",
                            systemImage: "plus.circle.fill"
                        )
                    }
                    .disabled(
                        youtubeChannel
                            .trimmingCharacters(
                                in: .whitespacesAndNewlines
                            )
                            .isEmpty
                        || addingYouTube
                        || store.channels.count >= 10
                    )
                }

                Section {
                    ForEach(
                        Platform.allCases
                    ) { platform in
                        Button {
                            store.startOAuth(
                                platform
                            )
                        } label: {
                            HStack(spacing: 14) {
                                Image(
                                    systemName:
                                        platform.symbol
                                )
                                .foregroundStyle(
                                    platform.color
                                )
                                .font(.title2)

                                VStack(
                                    alignment: .leading
                                ) {
                                    Text(
                                        "\(platform.rawValue)でログイン"
                                    )
                                    .fontWeight(.semibold)

                                    Text(
                                        platform == .twitch
                                        ? "Twitch IRC用のchat:read権限も許可"
                                        : "公式ログイン画面で許可するだけ"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Image(
                                    systemName: "chevron.right"
                                )
                                .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                        }
                        .disabled(
                            store.channels.count >= 10
                            || store.isAuthorizing
                        )
                    }
                } header: {
                    Text(
                        "自分のアカウントを連携"
                    )
                } footer: {
                    Text(
                        "最大10チャンネル。TwitchとYouTubeは複数チャンネルを監視できます。KICKは自分用OAuth連携です。"
                    )
                }
            }
            .navigationTitle("チャンネル追加")
            .toolbar {
                ToolbarItem(
                    placement: .cancellationAction
                ) {
                    Button("閉じる") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct EventRow: View {
    @EnvironmentObject var store: AppStore
    let ev: UnifiedEvent

    var body: some View {
        Group {
            if ev.isPaidEvent {
                paidEventCard
            } else {
                normalEvent
            }
        }
    }

    private var normalEvent: some View {
        HStack(
            alignment: .top,
            spacing: horizontalSpacing
        ) {
            Image(
                systemName: ev.platform.symbol
            )
            .foregroundStyle(
                ev.platform.color
            )
            .frame(width: 22)

            avatarView(
                size: avatarSize
            )

            VStack(
                alignment: .leading,
                spacing: verticalSpacing
            ) {
                HStack {
                    Text(
                        ev.channelName
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Spacer()

                    if ev.isAlert {
                        Text(
                            eventLabel
                        )
                        .font(.caption.bold())
                        .foregroundStyle(
                            ev.platform.color
                        )
                    }
                }

                HStack(spacing: 5) {
                    Text(
                        ev.userName
                    )
                    .font(
                        .system(
                            size: store.commentFontSize,
                            weight: .semibold
                        )
                    )

                    ForEach(
                        ev.badges.prefix(5)
                    ) { badge in
                        BadgeView(
                            badge: badge
                        )
                    }
                }

                MessageContentView(
                    message: ev.message,
                    emotes: ev.emotes,
                    fontSize: store.commentFontSize
                )
            }
        }
        .padding(
            .vertical,
            verticalPadding
        )
        .padding(
            .horizontal,
            4
        )
    }

    private var paidEventCard: some View {
        VStack(
            alignment: .leading,
            spacing: 9
        ) {
            HStack(spacing: 7) {
                Image(
                    systemName: ev.platform.symbol
                )
                .foregroundStyle(
                    ev.platform.color
                )

                Text(
                    ev.platform.rawValue
                )
                .font(.caption.bold())

                Text(
                    eventLabel
                )
                .font(.caption.bold())

                Spacer()

                if let amount =
                    ev.amountText {
                    Text(amount)
                        .font(
                            .headline.bold()
                        )
                }
            }

            HStack(
                alignment: .top,
                spacing: 9
            ) {
                avatarView(
                    size: 38
                )

                VStack(
                    alignment: .leading,
                    spacing: 5
                ) {
                    HStack(spacing: 5) {
                        Text(
                            ev.userName
                        )
                        .font(
                            .system(
                                size:
                                    store.commentFontSize,
                                weight: .bold
                            )
                        )

                        ForEach(
                            ev.badges.prefix(5)
                        ) { badge in
                            BadgeView(
                                badge: badge
                            )
                        }
                    }

                    MessageContentView(
                        message: ev.message,
                        emotes: ev.emotes,
                        fontSize: store.commentFontSize
                    )
                }

                Spacer()
            }

            Text(
                ev.channelName
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(13)
        .background(
            ev.platform.color
                .opacity(0.13)
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: 14
            )
            .stroke(
                ev.platform.color
                    .opacity(0.5),
                lineWidth: 1
            )
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: 14
            )
        )
    }

    @ViewBuilder
    private func avatarView(
        size: CGFloat
    ) -> some View {
        if let string = ev.userAvatarURL,
           let url = URL(string: string) {
            AsyncImage(
                url: url
            ) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()

                default:
                    Circle()
                        .fill(
                            Color.secondary
                                .opacity(0.18)
                        )
                }
            }
            .frame(
                width: size,
                height: size
            )
            .clipShape(Circle())
        }
    }

    private var verticalPadding:
        CGFloat {
        switch store.commentDensity {
        case "compact":
            return 2
        case "comfortable":
            return 9
        default:
            return 5
        }
    }

    private var verticalSpacing:
        CGFloat {
        switch store.commentDensity {
        case "compact":
            return 1
        case "comfortable":
            return 7
        default:
            return 4
        }
    }

    private var horizontalSpacing:
        CGFloat {
        store.commentDensity == "compact"
        ? 6
        : 9
    }

    private var avatarSize:
        CGFloat {
        switch store.commentDensity {
        case "compact":
            return 22
        case "comfortable":
            return 32
        default:
            return 27
        }
    }

    private var eventLabel:
        String {
        switch ev.kind {
        case .bits:
            return "BITS"
        case .subscription:
            return "SUB"
        case .giftSubscription:
            return "GIFT"
        case .donation:
            return "TIP"
        case .superChat:
            return "SUPER CHAT"
        case .membership:
            return "MEMBER"
        case .follow:
            return "FOLLOW"
        case .raid:
            return "RAID"
        default:
            return "EVENT"
        }
    }
}

struct BadgeView: View {
    let badge: ChatBadge

    var body: some View {
        Group {
            if let string =
                badge.imageURL,
               let url =
                URL(string: string) {
                AsyncImage(
                    url: url
                ) { phase in
                    switch phase {
                    case .success(
                        let image
                    ):
                        image
                            .resizable()
                            .scaledToFit()

                    default:
                        Text(
                            badge.name
                        )
                        .font(.caption2)
                    }
                }
                .frame(
                    width: 18,
                    height: 18
                )

            } else {
                Text(
                    badge.name
                )
                .font(.caption2.bold())
                .padding(
                    .horizontal,
                    4
                )
                .padding(
                    .vertical,
                    2
                )
                .background(
                    Color.secondary
                        .opacity(0.15)
                )
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 4
                    )
                )
            }
        }
    }
}

// ============================================================
// MARK: - Message + Apple Translation
// ============================================================

struct MessageContentView: View {
    @EnvironmentObject var store: AppStore

    let message: String
    let emotes: [ChatEmote]
    let fontSize: Double

    var body: some View {
        Group {
            if #available(iOS 18.0, *) {
                IOS18TranslatedMessageView(
                    message: message,
                    emotes: emotes,
                    fontSize: fontSize
                )
            } else {
                OriginalMessageView(
                    message: message,
                    emotes: emotes,
                    fontSize: fontSize
                )
            }
        }
    }
}

struct OriginalMessageView: View {
    let message: String
    let emotes: [ChatEmote]
    let fontSize: Double

    var body: some View {
        Group {
            if emotes.isEmpty {
                Text(message)
                    .font(
                        .system(
                            size: fontSize
                        )
                    )
                    .textSelection(
                        .enabled
                    )
            } else {
                ChatMessageWithEmotes(
                    message: message,
                    emotes: emotes,
                    fontSize: fontSize
                )
            }
        }
    }
}

@available(iOS 18.0, *)
struct IOS18TranslatedMessageView: View {
    @EnvironmentObject var store: AppStore

    let message: String
    let emotes: [ChatEmote]
    let fontSize: Double

    @State private var translatedText:
        String?

    @State private var configuration:
        TranslationSession.Configuration?

    @State private var translationFailed =
        false

    private var japanese:
        Locale.Language {
        Locale.Language(
            identifier: "ja"
        )
    }

    private var needsTranslation:
        Bool {
        guard
            store.autoTranslateEnabled
        else {
            return false
        }

        let trimmed =
            message.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard
            !trimmed.isEmpty
        else {
            return false
        }

        let detected =
            NLLanguageRecognizer
                .dominantLanguage(
                    for: trimmed
                )

        return detected != .japanese
    }

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 3
        ) {
            if
                store.translationOriginalVisible
                ||
                translatedText == nil
            {
                OriginalMessageView(
                    message: message,
                    emotes: emotes,
                    fontSize: fontSize
                )
            }

            if
                store.autoTranslateEnabled,
                let translatedText,
                !translatedText.isEmpty
            {
                HStack(
                    alignment: .top,
                    spacing: 5
                ) {
                    Text("🇯🇵")

                    Text(
                        translatedText
                    )
                    .font(
                        .system(
                            size:
                                max(
                                    fontSize - 1,
                                    12
                                )
                        )
                    )
                    .foregroundStyle(
                        .secondary
                    )
                    .textSelection(
                        .enabled
                    )
                }
            }
        }
        .onAppear {
            requestTranslation()
        }
        .onChange(
            of:
                store.autoTranslateEnabled
        ) {
            _,
            _ in

            requestTranslation()
        }
        .onChange(
            of:
                message
        ) {
            _,
            _ in

            requestTranslation()
        }
        .translationTask(
            configuration
        ) {
            session in

            guard
                needsTranslation
            else {
                translatedText = nil
                return
            }

            do {
                let response =
                    try await session
                        .translate(
                            message
                        )

                let result =
                    response.targetText
                        .trimmingCharacters(
                            in:
                                .whitespacesAndNewlines
                        )

                if
                    !result.isEmpty,
                    result != message
                {
                    translatedText =
                        result
                } else {
                    translatedText =
                        nil
                }

                translationFailed =
                    false

            } catch {
                translatedText =
                    nil

                translationFailed =
                    true
            }
        }
    }

    private func requestTranslation() {
        translatedText = nil
        translationFailed = false

        guard
            needsTranslation
        else {
            configuration = nil
            return
        }

        if configuration == nil {
            configuration =
                TranslationSession.Configuration(
                    source: nil,
                    target: japanese
                )
        } else {
            configuration?.invalidate()
        }
    }
}

// ============================================================
// MARK: - Twitch Emote rendering
// ============================================================

struct ChatMessageWithEmotes: View {
    let message: String
    let emotes: [ChatEmote]
    let fontSize: Double

    var body: some View {
        FlowLayout(
            spacing: 3
        ) {
            ForEach(
                Array(
                    segments.enumerated()
                ),
                id: \.offset
            ) {
                _,
                segment in

                switch segment {
                case .text(
                    let text
                ):
                    if !text.isEmpty {
                        Text(text)
                            .font(
                                .system(
                                    size:
                                        fontSize
                                )
                            )
                    }

                case .emote(
                    let emote
                ):
                    if let url =
                        URL(
                            string:
                                emote.imageURL
                        ) {
                        AsyncImage(
                            url: url
                        ) { phase in
                            switch phase {
                            case .success(
                                let image
                            ):
                                image
                                    .resizable()
                                    .scaledToFit()

                            default:
                                Text(
                                    emote.name
                                )
                                .font(
                                    .system(
                                        size:
                                            fontSize
                                    )
                                )
                            }
                        }
                        .frame(
                            height:
                                max(
                                    CGFloat(
                                        fontSize
                                    )
                                    * 1.45,
                                    24
                                )
                        )
                    }
                }
            }
        }
    }

    enum Segment {
        case text(String)
        case emote(ChatEmote)
    }

    private var segments:
        [Segment] {
        let valid =
            emotes
                .compactMap {
                    emote
                    ->
                    (
                        ChatEmote,
                        Int,
                        Int
                    )?
                    in

                    guard
                        let start =
                            emote.start,
                        let end =
                            emote.end,
                        start >= 0,
                        end >= start
                    else {
                        return nil
                    }

                    return (
                        emote,
                        start,
                        end
                    )
                }
                .sorted {
                    $0.1 < $1.1
                }

        if valid.isEmpty {
            return [
                .text(message)
            ]
        }

        let nsMessage =
            message as NSString

        let length =
            nsMessage.length

        var result:
            [Segment] = []

        var cursor = 0

        for (
            emote,
            start,
            end
        ) in valid {
            guard
                start < length,
                end < length,
                start >= cursor
            else {
                continue
            }

            if start > cursor {
                let range =
                    NSRange(
                        location: cursor,
                        length:
                            start - cursor
                    )

                let text =
                    nsMessage.substring(
                        with: range
                    )

                if !text.isEmpty {
                    result.append(
                        .text(text)
                    )
                }
            }

            result.append(
                .emote(emote)
            )

            cursor =
                end + 1
        }

        if cursor < length {
            let remainder =
                nsMessage.substring(
                    from: cursor
                )

            if !remainder.isEmpty {
                result.append(
                    .text(remainder)
                )
            }
        }

        return result.isEmpty
        ? [.text(message)]
        : result
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(
        proposal:
            ProposedViewSize,
        subviews:
            Subviews,
        cache:
            inout ()
    ) -> CGSize {
        let maxWidth =
            proposal.width ?? 320

        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size =
                subview.sizeThatFits(
                    .unspecified
                )

            if
                x > 0,
                x + size.width
                > maxWidth
            {
                x = 0
                y +=
                    lineHeight
                    + spacing

                lineHeight = 0
            }

            x +=
                size.width
                + spacing

            lineHeight =
                max(
                    lineHeight,
                    size.height
                )
        }

        return CGSize(
            width: maxWidth,
            height:
                y + lineHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal:
            ProposedViewSize,
        subviews:
            Subviews,
        cache:
            inout ()
    ) {
        var x =
            bounds.minX

        var y =
            bounds.minY

        var lineHeight:
            CGFloat = 0

        for subview in subviews {
            let size =
                subview.sizeThatFits(
                    .unspecified
                )

            if
                x > bounds.minX,
                x + size.width
                > bounds.maxX
            {
                x = bounds.minX

                y +=
                    lineHeight
                    + spacing

                lineHeight = 0
            }

            subview.place(
                at:
                    CGPoint(
                        x: x,
                        y: y
                    ),
                anchor:
                    .topLeading,
                proposal:
                    ProposedViewSize(
                        width:
                            size.width,
                        height:
                            size.height
                    )
            )

            x +=
                size.width
                + spacing

            lineHeight =
                max(
                    lineHeight,
                    size.height
                )
        }
    }
}

struct SimpleSettingsView: View {
    @State private var showConnectionSetup = false
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    @State private var draftAlertURLs:
        [UUID: String] = [:]

    var body: some View {
        NavigationStack {
            Form {
                Section("表示テーマ") {
                    Picker("外観", selection: $store.appearanceMode) {
                        Text("端末に合わせる").tag("system")
                        Text("ライト").tag("light")
                        Text("ダーク").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }

                Section("読み上げ") {
                    Toggle(
                        "棒読み",
                        isOn:
                            $store.ttsEnabled
                    )

                    Toggle(
                        "名前も読む",
                        isOn:
                            $store.ttsReadNames
                    )

                    Toggle(
                        "投げ銭・サブスクも読む",
                        isOn:
                            $store.ttsReadAlerts
                    )

                    HStack {
                        Text("速度")

                        Slider(
                            value:
                                $store.ttsRate,
                            in:
                                0.38...0.58
                        )

                        Button("テスト") {
                            store.testSpeech()
                        }
                    }
                }

                Section("読み上げ除外") {
                    AddIgnoredUserView()

                    if store.ttsIgnoredUsers.isEmpty {
                        Text(
                            "登録されているユーザーはいません"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        ForEach(
                            store.ttsIgnoredUsers,
                            id: \.self
                        ) { name in
                            HStack {
                                Image(
                                    systemName:
                                        "speaker.slash.fill"
                                )
                                .foregroundStyle(.secondary)

                                Text(name)

                                Spacer()

                                Button(
                                    role:
                                        .destructive
                                ) {
                                    store.ttsIgnoredUsers
                                        .removeAll {
                                            $0.caseInsensitiveCompare(
                                                name
                                            )
                                            == .orderedSame
                                        }
                                } label: {
                                    Image(
                                        systemName:
                                            "trash"
                                    )
                                }
                            }
                        }
                    }

                    Text(
                        "登録したユーザーのコメントは表示されますが、読み上げません。"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section("コメント表示") {
                    VStack(
                        alignment: .leading,
                        spacing: 5
                    ) {
                        HStack {
                            Text("文字サイズ")

                            Spacer()

                            Text(
                                "\(Int(store.commentFontSize))"
                            )
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        }

                        Slider(
                            value:
                                $store.commentFontSize,
                            in:
                                12...30,
                            step:
                                1
                        )
                    }

                    Picker(
                        "コメント密度",
                        selection:
                            $store.commentDensity
                    ) {
                        Text(
                            "コンパクト"
                        )
                        .tag("compact")

                        Text(
                            "標準"
                        )
                        .tag("standard")

                        Text(
                            "ゆったり"
                        )
                        .tag("comfortable")
                    }

                    Text(
                        "通常コメントはシンプル表示です。投げ銭・Bits・SUB・Gift・Membershipなどのみ専用カードになります。"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section("自動翻訳") {
                    Toggle(
                        "自動翻訳を表示",
                        isOn:
                            $store.autoTranslateEnabled
                    )

                    Toggle(
                        "原文も表示",
                        isOn:
                            $store.translationOriginalVisible
                    )
                    .disabled(
                        !store.autoTranslateEnabled
                    )

                    if #available(iOS 18.0, *) {
                        Text(
                            "日本語以外と判定されたコメントをAppleのTranslationフレームワークで日本語へ翻訳します。初回は必要な言語データのダウンロード確認が表示される場合があります。"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        Text(
                            "自動翻訳にはiOS 18以降が必要です。"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }

                Section("Twitch統合チャット") {
                    Toggle(
                        "同じコメントを自動で1件にまとめる",
                        isOn:
                            $store.twitchIntegratedDedupe
                    )

                    HStack {
                        Text("重複判定")

                        Slider(
                            value:
                                $store.duplicateWindow,
                            in:
                                1.0...5.0,
                            step:
                                0.5
                        )

                        Text(
                            String(
                                format:
                                    "%.1f秒",
                                store.duplicateWindow
                            )
                        )
                        .font(.caption)
                        .monospacedDigit()
                    }

                    LabeledContent(
                        "省いた重複",
                        value:
                            "\(store.hiddenDuplicateCount)件"
                    )
                }

                Section("アラート") {
                    Toggle(
                        "Streamlabs / StreamElementsを再生",
                        isOn:
                            $store.alertsVisible
                    )

                    Toggle(
                        "アラート利用中は画面を自動消灯しない",
                        isOn: $store.keepScreenAwakeForAlerts
                    )

                    Text("Streamlabs / StreamElementsのWidget URLを透明ブラウザで再生します。アプリを表示中のみ動作し、バックグラウンドや画面ロック中の再生はiOSの制限により保証されません。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(
                        $store.channels
                    ) { $channel in
                        DisclosureGroup(
                            channel.name.isEmpty
                            ? channel.platform.rawValue
                            : channel.name
                        ) {
                            Picker(
                                "サービス",
                                selection:
                                    $channel.alertProvider
                            ) {
                                ForEach(
                                    AlertProvider.allCases
                                ) { provider in
                                    Text(
                                        provider.rawValue
                                    )
                                    .tag(provider)
                                }
                            }

                            SecureField(
                                "Widget URL",
                                text:
                                    Binding(
                                        get: {
                                            draftAlertURLs[
                                                channel.id
                                            ]
                                            ??
                                            KeychainStore.read(
                                                channel.alertURLKey
                                            )
                                            ??
                                            ""
                                        },
                                        set: {
                                            draftAlertURLs[
                                                channel.id
                                            ] = $0
                                        }
                                    )
                            )

                            Button("保存") {
                                KeychainStore.write(
                                    channel.alertURLKey,
                                    value:
                                        draftAlertURLs[
                                            channel.id
                                        ]
                                        ??
                                        ""
                                )

                                store.testAlert()
                            }
                        }
                    }
                }

                Section("接続") {
                    Button("接続セットアップ") { showConnectionSetup = true }
                    Text("配布版には共用サーバーは設定されていません。ご自身が管理するサーバーを設定してください。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Circle()
                            .fill(
                                store.status
                                ==
                                "接続済み"
                                ? Color.green
                                : Color.orange
                            )
                            .frame(
                                width: 9,
                                height: 9
                            )

                        Text(
                            store.status
                        )
                    }

                    TextField(
                        "サーバーURL",
                        text:
                            $store.serverURL
                    )
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)

                    Button(
                        "保存して再接続"
                    ) {
                        store.saveServerURL()
                        store.connect()
                    }
                }

                Section("連携済み") {
                    ForEach(
                        store.channels
                    ) { channel in
                        HStack {
                            Image(
                                systemName:
                                    channel.platform.symbol
                            )
                            .foregroundStyle(
                                channel.platform.color
                            )

                            VStack(
                                alignment: .leading
                            ) {
                                Text(
                                    channel.name
                                )

                                Text(
                                    channel.platform.rawValue
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }

                            Spacer()
                        }
                    }
                    .onDelete {
                        store.removeChannel(
                            at: $0
                        )
                    }
                }
            }
            .sheet(isPresented: $showConnectionSetup) { DistributionSetupView() }
            .navigationTitle("設定")
            .toolbar {
                ToolbarItem(
                    placement:
                        .confirmationAction
                ) {
                    Button("完了") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct AddIgnoredUserView: View {
    @EnvironmentObject var store: AppStore
    @State private var name = ""

    var body: some View {
        HStack {
            TextField(
                "読み上げないユーザー名",
                text: $name
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            Button("追加") {
                let trimmed =
                    name.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )

                guard !trimmed.isEmpty else {
                    return
                }

                let exists =
                    store.ttsIgnoredUsers.contains {
                        $0.caseInsensitiveCompare(
                            trimmed
                        )
                        == .orderedSame
                    }

                if !exists {
                    store.ttsIgnoredUsers.append(
                        trimmed
                    )
                }

                name = ""
            }
        }
    }
}

enum KeychainStore {
    static func write(
        _ key: String,
        value: String
    ) {
        delete(key)

        guard let data =
            value.data(
                using: .utf8
            ) else {
            return
        }

        let query:
            [String: Any] = [
                kSecClass as String:
                    kSecClassGenericPassword,

                kSecAttrAccount as String:
                    "distribution.v1." + key,

                kSecAttrAccessible as String:
                    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecValueData as String:
                    data
            ]

        SecItemAdd(
            query as CFDictionary,
            nil
        )
    }

    static func read(
        _ key: String
    ) -> String? {
        let query:
            [String: Any] = [
                kSecClass as String:
                    kSecClassGenericPassword,

                kSecAttrAccount as String:
                    "distribution.v1." + key,

                kSecReturnData as String:
                    true,

                kSecMatchLimit as String:
                    kSecMatchLimitOne
            ]

        var result: AnyObject?

        guard
            SecItemCopyMatching(
                query as CFDictionary,
                &result
            )
            == errSecSuccess,
            let data =
                result as? Data
        else {
            return nil
        }

        return String(
            data: data,
            encoding: .utf8
        )
    }

    static func delete(
        _ key: String
    ) {
        let query:
            [String: Any] = [
                kSecClass as String:
                    kSecClassGenericPassword,

                kSecAttrAccount as String:
                    "distribution.v1." + key
            ]

        SecItemDelete(
            query as CFDictionary
        )
    }
}
