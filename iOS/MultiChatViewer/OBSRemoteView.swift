import SwiftUI
import AuthenticationServices
import Security
import UIKit
import UniformTypeIdentifiers

private enum OBSIntegrationConfig {
    static let defaultRelayURL = ""
}

struct IntegratedRootView: View {
    @AppStorage("distribution_setup_complete") private var setupComplete = false

    var body: some View {
        TabView {
            ContentView()
                .tabItem { Label("MultiChat", systemImage: "message.fill") }

            OBSControlView()
                .tabItem { Label("OBS", systemImage: "dot.radiowaves.left.and.right") }

            TwitchCommentView()
                .tabItem { Label("コメント", systemImage: "paperplane.fill") }
        }
        .sheet(isPresented: Binding(get: { !setupComplete }, set: { if !$0 { setupComplete = true } })) {
            DistributionSetupView()
        }
    }
}

struct OBSRemoteState: Codable {
    var obsOnline = false
    var streaming = false
    var currentScene = ""
    var scenes: [String] = []
    var sources: [OBSRemoteSource] = []
}

struct OBSRemoteSource: Codable, Identifiable {
    var name: String
    var enabled: Bool
    var id: String { name }
}

protocol OBSWebSocket: AnyObject {
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void)
    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
}

extension URLSessionWebSocketTask: OBSWebSocket {}

@MainActor
final class OBSRemoteController: ObservableObject {
    @Published var connected = false
    @Published var agentOnline = false
    @Published var state = OBSRemoteState()
    @Published var message = "未設定"

    var serverURL: String {
        get { UserDefaults.standard.string(forKey: "obsRemoteServerURL") ?? OBSIntegrationConfig.defaultRelayURL }
        set { UserDefaults.standard.set(newValue, forKey: "obsRemoteServerURL") }
    }

    var adminToken: String {
        get { SecureValueStore.read("obs_remote_admin_token") ?? "" }
        set {
            if newValue.isEmpty { SecureValueStore.delete("obs_remote_admin_token") }
            else { SecureValueStore.write(newValue, key: "obs_remote_admin_token") }
        }
    }

    var isAdminConfigured: Bool { !adminToken.isEmpty }

    private let makeSocket: (URL) -> any OBSWebSocket
    private var task: (any OBSWebSocket)?
    private var reconnectTask: Task<Void, Never>?

    init(makeSocket: @escaping (URL) -> any OBSWebSocket = { URLSession.shared.webSocketTask(with: $0) }) {
        self.makeSocket = makeSocket
    }

    var obsReady: Bool { connected && agentOnline && state.obsOnline }

    func connect() {
        disconnect(shouldReconnect: false)
        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "wss", let host = url.host, !host.isEmpty,
              !adminToken.isEmpty else {
            message = "WSSのURLとOBS管理者トークンを入力してください"
            return
        }
        let socket = makeSocket(url)
        task = socket
        socket.resume()
        message = "接続中…"
        sendRaw(["type": "auth", "role": "client", "token": adminToken])
        receive(socket)
    }

    func disconnect(shouldReconnect: Bool = true) {
        reconnectTask?.cancel()
        reconnectTask = nil
        let oldTask = task
        task = nil
        oldTask?.cancel(with: .goingAway, reason: nil)
        connected = false
        agentOnline = false
        state = OBSRemoteState()
        message = "未接続"
        if shouldReconnect && isAdminConfigured {
            message = "接続が切れました。再接続します…"
            reconnectTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(3)) }
                catch { return }
                guard !Task.isCancelled else { return }
                self?.connect()
            }
        }
    }

    func command(_ action: String, extra: [String: Any] = [:]) {
        guard connected && agentOnline else { message = "OBSパソコンへ未接続です"; return }
        if ["start_stream", "stop_stream", "set_scene", "set_source_visible"].contains(action) && !state.obsOnline {
            message = "OBSへ未接続です"
            return
        }
        var body = extra
        body["type"] = "command"
        body["id"] = UUID().uuidString
        body["action"] = action
        sendRaw(body)
        message = "操作を送信しました"
    }

    private func sendRaw(_ value: [String: Any]) {
        guard let socket = task,
              let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { [weak self, weak socket] error in
            Task { @MainActor in
                guard let self, let socket, self.task === socket else { return }
                if error != nil { self.disconnect() }
            }
        }
    }

    private func receive(_ socket: any OBSWebSocket) {
        socket.receive { [weak self, weak socket] result in
            Task { @MainActor in
                guard let self, let socket, self.task === socket else { return }
                switch result {
                case .failure:
                    self.disconnect()
                case .success(let packet):
                    let text: String
                    switch packet {
                    case .string(let value): text = value
                    case .data(let data): text = String(data: data, encoding: .utf8) ?? ""
                    @unknown default: text = ""
                    }
                    self.handle(text)
                    if self.task === socket { self.receive(socket) }
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }
        switch type {
        case "auth_ok":
            connected = true
            agentOnline = json["agentOnline"] as? Bool ?? false
            message = "中継サーバー接続済み"
            if agentOnline { command("refresh") }
        case "agent_status":
            let wasOnline = agentOnline
            agentOnline = json["online"] as? Bool ?? false
            if !agentOnline { state = OBSRemoteState() }
            else if !wasOnline { command("refresh") }
        case "state":
            if let decoded = try? JSONDecoder().decode(OBSRemoteState.self, from: data) {
                state = decoded
            }
        case "result":
            message = (json["ok"] as? Bool == true)
                ? "操作しました"
                : (json["error"] as? String ?? "操作に失敗しました")
        case "error":
            message = json["message"] as? String ?? "中継サーバーでエラーが発生しました"
        default:
            break
        }
    }
}

@MainActor
final class TwitchCommentController: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published var loginName = ""
    @Published var status = "Twitch未ログイン"
    @Published var sending = false
    @Published var targetChannel =
        UserDefaults.standard.string(forKey: "obs_twitch_target_channel") ?? "" {
        didSet {
            let normalized = targetChannel
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "@", with: "")
            if normalized != targetChannel { targetChannel = normalized }
            UserDefaults.standard.set(normalized, forKey: "obs_twitch_target_channel")
        }
    }
    @Published var oauthClientID = UserDefaults.standard.string(forKey: "distribution_twitch_client_id") ?? "" {
        didSet {
            if oldValue != oauthClientID { logout() }
            UserDefaults.standard.set(oauthClientID, forKey: "distribution_twitch_client_id")
        }
    }
    @Published var oauthRedirectURI = UserDefaults.standard.string(forKey: "distribution_twitch_redirect_uri") ?? "" {
        didSet {
            if oldValue != oauthRedirectURI { logout() }
            UserDefaults.standard.set(oauthRedirectURI, forKey: "distribution_twitch_redirect_uri")
        }
    }
    var oauthConfigured: Bool {
        guard !oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: oauthRedirectURI), url.scheme == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil else { return false }
        return true
    }
    private var authSession: ASWebAuthenticationSession?
    private var userID = ""
    private var accessToken: String? { SecureValueStore.read("obs_twitch_access_token") }

    override init() {
        super.init()
        Task { await restore() }
    }

    func login() {
        guard oauthConfigured else {
            status = "Twitch接続設定にClient IDとHTTPSの戻り先URLを入力してください"
            return
        }
        let state = UUID().uuidString
        UserDefaults.standard.set(state, forKey: "obs_twitch_oauth_state")
        var parts = URLComponents(string: "https://id.twitch.tv/oauth2/authorize")!
        parts.queryItems = [
            .init(name: "response_type", value: "token"),
            .init(name: "client_id", value: oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines)),
            .init(name: "redirect_uri", value: oauthRedirectURI),
            .init(name: "scope", value: "user:write:chat"),
            .init(name: "state", value: state),
            .init(name: "force_verify", value: "true")
        ]

        authSession = ASWebAuthenticationSession(url: parts.url!, callbackURLScheme: "obsremote") { [weak self] url, error in
            Task { @MainActor in
                guard error == nil, let url,
                      let values = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
                    self?.status = "Twitchログインを中止しました"
                    return
                }
                let dict = Dictionary(uniqueKeysWithValues: values.compactMap { item in
                    item.value.map { (item.name, $0) }
                })
                guard dict["state"] == UserDefaults.standard.string(forKey: "obs_twitch_oauth_state"),
                      let token = dict["access_token"] else {
                    self?.status = "ログイン確認に失敗しました"
                    return
                }
                SecureValueStore.write(token, key: "obs_twitch_access_token")
                await self?.restore()
            }
        }
        authSession?.presentationContextProvider = self
        authSession?.prefersEphemeralWebBrowserSession = false
        authSession?.start()
    }

    func logout() {
        authSession?.cancel()
        authSession = nil
        UserDefaults.standard.removeObject(forKey: "obs_twitch_oauth_state")
        SecureValueStore.delete("obs_twitch_access_token")
        loginName = ""
        userID = ""
        status = "Twitch未ログイン"
    }

    func send(_ message: String) async {
        let clean = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 500, let token = accessToken else {
            status = "Twitchへログインしてください"
            return
        }
        sending = true
        defer { sending = false }
        do {
            if userID.isEmpty { try await validate(token) }
            guard !targetChannel.isEmpty else {
                throw TwitchCommentError.message("送信先チャンネルを入力してください")
            }
            let broadcasterID = try await lookupUser(targetChannel, token: token)
            var request = URLRequest(url: URL(string: "https://api.twitch.tv/helix/chat/messages")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "Client-Id")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "broadcaster_id": broadcasterID,
                "sender_id": userID,
                "message": clean
            ])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw TwitchCommentError.message(String(data: data, encoding: .utf8) ?? "送信失敗")
            }
            status = "\(loginName)として送信しました"
        } catch {
            status = error.localizedDescription
        }
    }

    private func restore() async {
        guard oauthConfigured, let token = accessToken else { return }
        do { try await validate(token) } catch { logout() }
    }

    private func validate(_ token: String) async throws {
        var request = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/validate")!)
        request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["user_id"] as? String,
              let login = json["login"] as? String else {
            throw TwitchCommentError.message("Twitchログインの期限が切れました")
        }
        userID = id
        loginName = login
        status = "\(login)でログイン中"
    }

    private func lookupUser(_ login: String, token: String) async throws -> String {
        var parts = URLComponents(string: "https://api.twitch.tv/helix/users")!
        parts.queryItems = [.init(name: "login", value: login)]
        var request = URLRequest(url: parts.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "Client-Id")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let users = json["data"] as? [[String: Any]],
              let id = users.first?["id"] as? String else {
            throw TwitchCommentError.message("送信先チャンネルが見つかりません")
        }
        return id
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? UIWindow()
    }
}

struct OBSControlView: View {
    @EnvironmentObject var remote: OBSRemoteController
    @EnvironmentObject var twitch: TwitchCommentController
    @EnvironmentObject var store: AppStore
    @State private var showSettings = false
    @State private var confirmStop = false

    var body: some View {
        NavigationStack {
            Group {
                if remote.isAdminConfigured {
                    ScrollView {
                        VStack(spacing: 16) {
                            connectionCard
                            streamButton.disabled(!remote.obsReady)
                            HStack {
                                Button("Twitch !fix") { remote.command("twitch_fix") }
                                Button("KICK !fix") { remote.command("kick_fix") }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!remote.connected || !remote.agentOnline)
                            Menu {
                                Button("Twitchへ送信") {
                                    Task { await twitch.send("!fix") }
                                }
                                .disabled(twitch.loginName.isEmpty)

                                ForEach(kickAccounts) { account in
                                    Button("KICK（\(account.name)）へ送信") {
                                        guard let id = account.serverAccountID else { return }
                                        Task { await store.sendKickComment("!fix", accountID: id) }
                                    }
                                }
                            } label: {
                                Label("!fixを自分のアカウントで送信", systemImage: "wrench.and.screwdriver.fill")
                                    .frame(maxWidth: .infinity).padding()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.purple)
                            .disabled(twitch.loginName.isEmpty && kickAccounts.isEmpty)
                            scenes.disabled(!remote.obsReady)
                            sources.disabled(!remote.obsReady)
                            Text(remote.message).font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding()
                    }
                } else {
                    ContentUnavailableView(
                        "OBS管理者設定が必要です",
                        systemImage: "lock.shield",
                        description: Text("OBSを操作する管理者だけが右上の歯車から設定します。")
                    )
                }
            }
            .navigationTitle("OBS Remote")
            .toolbar { Button { showSettings = true } label: { Image(systemName: "gearshape.fill") }.accessibilityIdentifier("obs-settings") }
            .sheet(isPresented: $showSettings) { OBSAdminSettingsView() }
            .alert("配信を終了しますか？", isPresented: $confirmStop) {
                Button("キャンセル", role: .cancel) {}
                Button("終了", role: .destructive) { remote.command("stop_stream") }
            }
            .onAppear { if remote.isAdminConfigured && !remote.connected { remote.connect() } }
        }
    }

    private var kickAccounts: [ChannelConfig] {
        store.channels.filter {
            $0.platform == .kick && $0.serverAccountID != nil
        }
    }

    private var connectionCard: some View {
        HStack {
            Circle().fill(remote.obsReady ? .green : .red).frame(width: 12)
            Text(remote.obsReady ? "OBS接続中" : "未接続").bold()
            Spacer()
            Text(remote.obsReady ? (remote.state.streaming ? "配信中" : "停止中") : "状態不明")
                .foregroundStyle(remote.state.streaming ? .red : .secondary)
        }
        .padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var streamButton: some View {
        Button {
            if remote.state.streaming { confirmStop = true }
            else { remote.command("start_stream") }
        } label: {
            Label(remote.state.streaming ? "配信を終了" : "配信を開始",
                  systemImage: remote.state.streaming ? "stop.circle.fill" : "play.circle.fill")
                .font(.title2.bold()).frame(maxWidth: .infinity).padding()
        }
        .buttonStyle(.borderedProminent)
        .tint(remote.state.streaming ? .red : .green)
    }

    private var scenes: some View {
        GroupBox("シーン切り替え") {
            VStack(spacing: 8) {
                ForEach(remote.state.scenes, id: \.self) { scene in
                    Button { remote.command("set_scene", extra: ["sceneName": scene]) } label: {
                        HStack { Text(scene); Spacer(); if scene == remote.state.currentScene { Image(systemName: "checkmark.circle.fill") } }
                            .frame(maxWidth: .infinity).padding(8)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var sources: some View {
        GroupBox("ソース表示・非表示") {
            VStack {
                ForEach(remote.state.sources) { source in
                    Toggle(source.name, isOn: Binding(
                        get: { source.enabled },
                        set: { value in remote.command("set_source_visible", extra: ["sceneName": remote.state.currentScene, "sourceName": source.name, "enabled": value]) }
                    )).padding(.vertical, 4)
                }
            }
        }
    }
}

struct TwitchCommentView: View {
    @EnvironmentObject var twitch: TwitchCommentController
    @EnvironmentObject var store: AppStore
    @AppStorage("commentSendPlatform") private var sendPlatform = "Twitch"
    @State private var message = ""
    @FocusState private var isCommentFocused: Bool
    @State private var selectedKickAccountID = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("送信サービス") {
                    Picker("送信サービス", selection: $sendPlatform) {
                        Text("Twitch").tag("Twitch")
                        Text("KICK").tag("KICK")
                    }
                    .pickerStyle(.segmented)
                }

                if sendPlatform == "Twitch" {
                    twitchSettings
                } else {
                    kickSettings
                }

                Section("チャットへ送信") {
                    TextField("コメントを入力", text: $message, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($isCommentFocused)
                    Text("\(message.count)/500").font(.caption).foregroundStyle(.secondary)
                    Button("送信") {
                        isCommentFocused = false
                        let text = message
                        message = ""
                        Task {
                            if sendPlatform == "KICK" {
                                await store.sendKickComment(text, accountID: selectedKickAccountID)
                            } else {
                                await twitch.send(text)
                            }
                        }
                    }
                    .disabled(!canSend || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || message.count > 500)
                    Button("!fixを送信") {
                        isCommentFocused = false
                        Task {
                            if sendPlatform == "KICK" {
                                await store.sendKickComment("!fix", accountID: selectedKickAccountID)
                            } else {
                                await twitch.send("!fix")
                            }
                        }
                    }
                    .disabled(!canSend)
                }
            }
            .navigationTitle("コメント送信")
            .onAppear { selectDefaultKickAccount() }
            .onChange(of: store.channels.count) { _, _ in selectDefaultKickAccount() }
        }
    }

    @ViewBuilder
    private var twitchSettings: some View {
        Section("Twitch接続設定") {
            TextField("Twitch Client ID", text: $twitch.oauthClientID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("twitch-client-id")
            TextField("HTTPSのOAuth戻り先URL", text: $twitch.oauthRedirectURI)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .accessibilityIdentifier("twitch-redirect-uri")
            Text("ご自身のTwitchアプリ登録のClient IDと、obsremoteコールバックに対応した戻り先URLを設定してください。Client Secretは入力しません。")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Twitchアカウント") {
            Text(twitch.status)
            if twitch.loginName.isEmpty {
                Button("Twitchでログイン") { twitch.login() }
                    .disabled(!twitch.oauthConfigured)
            } else {
                Button("ログアウト", role: .destructive) { twitch.logout() }
            }
        }
        Section("送信先") {
            TextField("Twitchチャンネル名", text: $twitch.targetChannel)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("twitch-target-channel")
            Text("送信先のチャンネル名を入力してください（@は不要です）")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var kickSettings: some View {
        Section("KICKアカウント") {
            Text(store.kickSendStatus)

            if kickAccounts.isEmpty {
                Text("KICKを連携してください")
                    .foregroundStyle(.secondary)
            } else {
                Picker("送信アカウント", selection: $selectedKickAccountID) {
                    ForEach(kickAccounts) { account in
                        Text(account.name).tag(account.serverAccountID ?? "")
                    }
                }
            }

            Button(kickAccounts.isEmpty ? "KICKを連携" : "KICKを再連携して送信権限を許可") {
                store.startOAuth(.kick)
            }

            Text("NOALBSが監視しているKICKアカウントを選択してください。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var kickAccounts: [ChannelConfig] {
        store.channels.filter {
            $0.platform == .kick && $0.serverAccountID != nil
        }
    }

    private var canSend: Bool {
        if sendPlatform == "KICK" {
            return !selectedKickAccountID.isEmpty && !store.kickSending
        }
        return twitch.oauthConfigured && !twitch.loginName.isEmpty && !twitch.targetChannel.isEmpty && !twitch.sending
    }

    private func selectDefaultKickAccount() {
        if !kickAccounts.contains(where: { $0.serverAccountID == selectedKickAccountID }) {
            selectedKickAccountID = kickAccounts.first?.serverAccountID ?? ""
        }
    }
}

struct OBSAdminSettingsView: View {
    @EnvironmentObject var remote: OBSRemoteController
    @Environment(\.dismiss) private var dismiss
    @State private var serverURL = ""
    @State private var token = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("OBS管理者専用") {
                    Text("視聴・コメントだけ使う利用者は設定不要です。管理トークンを共有しないでください。")
                    TextField("WSSサーバーURL", text: $serverURL)
                        .textInputAutocapitalization(.never).keyboardType(.URL)
                        .accessibilityIdentifier("obs-server-url")
                    SecureField("OBS操作用トークン", text: $token)
                }
                Section {
                    Button("保存して接続") {
                        remote.serverURL = serverURL
                        remote.adminToken = token
                        remote.connect()
                        dismiss()
                    }
                    Button("管理者設定を削除", role: .destructive) {
                        remote.adminToken = ""
                        remote.disconnect(shouldReconnect: false)
                        dismiss()
                    }
                }
            }
            .navigationTitle("OBS管理者設定")
            .toolbar { Button("閉じる") { dismiss() } }
            .onAppear {
                serverURL = remote.serverURL
                token = remote.adminToken
            }
        }
    }
}

private enum TwitchCommentError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

private enum SecureValueStore {
    static func write(_ value: String, key: String) {
        delete(key)
        let data = Data(value.utf8)
        SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: "distribution.v1." + key,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ] as CFDictionary, nil)
    }

    static func read(_ key: String) -> String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: "distribution.v1." + key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrAccount: "distribution.v1." + key] as CFDictionary)
    }
}


// Only public connection settings belong in an importable profile.
struct DistributionProfile: Codable {
    let serverURL: String
    let obsRelayURL: String?
    let twitchClientID: String?
    let twitchRedirectURI: String?

    func validate() throws {
        try Self.validateURL(serverURL, scheme: "https", optional: false)
        try Self.validateURL(obsRelayURL ?? "", scheme: "wss", optional: true)
        try Self.validateURL(twitchRedirectURI ?? "", scheme: "https", optional: true)
        let client = twitchClientID ?? ""
        guard client.isEmpty || client.range(of: "^[a-zA-Z0-9]+$", options: .regularExpression) != nil else {
            throw DistributionSetupError.invalid("Twitch Client IDを確認してください")
        }
        guard client.isEmpty == (twitchRedirectURI ?? "").isEmpty else {
            throw DistributionSetupError.invalid("Twitch送信を設定する場合はClient IDと戻り先URLの両方を入力してください")
        }
    }

    static func validateURL(_ value: String, scheme: String, optional: Bool) throws {
        if optional && value.isEmpty { return }
        guard let url = URL(string: value), url.scheme == scheme,
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil,
              url.query == nil else {
            throw DistributionSetupError.invalid("接続先には認証情報を含まない\(scheme)://形式のURLを入力してください")
        }
    }

    static func read(_ data: Data) throws -> DistributionProfile {
        guard data.count <= 16_384,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["serverURL", "obsRelayURL", "twitchClientID", "twitchRedirectURI"]) else {
            throw DistributionSetupError.invalid("接続設定ファイルを確認してください。パスワードやトークンを含む設定は読み込めません。")
        }
        let profile = try JSONDecoder().decode(DistributionProfile.self, from: data)
        try profile.validate()
        return profile
    }
}

enum DistributionSetupError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}


// Device-owner transfer only. This is never a public distribution profile.
struct DeviceSetupPackage: Codable {
    let version: Int
    let profile: DistributionProfile
    let obsToken: String?

    static func read(_ data: Data) throws -> DeviceSetupPackage {
        guard data.count <= 16_384,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["version", "profile", "obsToken"]),
              let profileObject = object["profile"] as? [String: Any] else {
            throw DistributionSetupError.invalid("個人用設定ファイルを確認してください")
        }
        _ = try DistributionProfile.read(JSONSerialization.data(withJSONObject: profileObject))
        let package = try JSONDecoder().decode(Self.self, from: data)
        guard package.version == 1 else {
            throw DistributionSetupError.invalid("この設定ファイルのバージョンには対応していません")
        }
        if let token = package.obsToken {
            guard !token.isEmpty, token.utf8.count <= 512,
                  token.rangeOfCharacter(from: .controlCharacters) == nil,
                  !(package.profile.obsRelayURL ?? "").isEmpty else {
                throw DistributionSetupError.invalid("OBSの個人用設定を確認してください")
            }
        }
        return package
    }
}

struct DistributionSetupView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var twitch: TwitchCommentController
    @EnvironmentObject var remote: OBSRemoteController
    @Environment(\.dismiss) private var dismiss
    @AppStorage("distribution_setup_complete") private var setupComplete = false
    @State private var serverURL = ""
    @State private var relayURL = ""
    @State private var clientID = ""
    @State private var redirectURI = ""
    @State private var showImporter = false
    @State private var showAdvanced = false
    @State private var errorMessage: String?
    @State private var imported = false
    @State private var importedAdminToken: String?
    @State private var importedTokenRelayURL = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("接続先を設定してはじめましょう")
                        .font(.headline)
                    Text("ご自身のサーバー、または利用を許可されたサーバーへ接続します。アプリには接続先やアカウントは登録されていません。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button("接続設定ファイルを読み込む") { showImporter = true }
                        .accessibilityIdentifier("import-connection-profile")
                    if imported {
                        Text("設定を読み込みました。接続先を確認してから保存してください。")
                            .font(.caption)
                    }
                    if importedAdminToken != nil {
                        Text("OBS管理キーを含む個人用設定です。自分の接続先であることを確認して保存してください。このファイルは他の人へ共有しないでください。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Section("1. チャットの接続先") {
                    TextField("https://chat.example.com", text: $serverURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("setup-server-url")
                    Text("接続先の管理者から案内されたURLを入力します。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    DisclosureGroup("2. Twitch送信・OBS操作（任意）", isExpanded: $showAdvanced) {
                        Text("Twitch送信").font(.headline)
                        TextField("Twitch Client ID", text: $clientID)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("setup-twitch-client-id")
                        TextField("HTTPSのOAuth戻り先URL", text: $redirectURI)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("setup-twitch-redirect-uri")
                        Text("管理者が配布する接続設定ファイルを使うと、ここは自動で入力されます。保存後に「コメント」からご自身のTwitchへログインしてください。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("OBS操作").font(.headline)
                        TextField("wss://relay.example.com/obsremote/ws", text: $relayURL)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("setup-obs-url")
                        Text("OBS管理トークンは、保存後に「OBS」の管理者設定で入力できます。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("保存してはじめる") { save() }
                        .disabled(serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("save-connection-setup")
                    Button("あとで設定する") {
                        setupComplete = true
                        dismiss()
                    }.accessibilityIdentifier("skip-connection-setup")
                } footer: {
                    Text("接続設定は後から「設定」→「接続セットアップ」で変更できます。KICKのアカウント連携は接続設定後に行ってください。")
                }
            }
            .navigationTitle("接続セットアップ")
            .onAppear {
                serverURL = store.serverURL
                relayURL = remote.serverURL
                clientID = twitch.oauthClientID
                redirectURI = twitch.oauthRedirectURI
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get()
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let values = try url.resourceValues(forKeys: [.fileSizeKey])
                    guard (values.fileSize ?? 0) <= 16_384 else {
                        throw DistributionSetupError.invalid("設定ファイルが大きすぎます")
                    }
                    let data = try Data(contentsOf: url)
                    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    let profile: DistributionProfile
                    let adminToken: String?
                    if object?["version"] != nil || object?["profile"] != nil {
                        let package = try DeviceSetupPackage.read(data)
                        profile = package.profile
                        adminToken = package.obsToken
                    } else {
                        profile = try DistributionProfile.read(data)
                        adminToken = nil
                    }
                    importedAdminToken = adminToken
                    importedTokenRelayURL = adminToken == nil ? "" : (profile.obsRelayURL ?? "")
                    serverURL = profile.serverURL
                    relayURL = profile.obsRelayURL ?? ""
                    clientID = profile.twitchClientID ?? ""
                    redirectURI = profile.twitchRedirectURI ?? ""
                    showAdvanced = !relayURL.isEmpty || !clientID.isEmpty
                    imported = true
                } catch {
                    errorMessage = "設定を読み込めませんでした。管理者から受け取ったJSON形式の接続設定を選んでください。"
                }
            }
            .alert("接続設定を確認してください", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func save() {
        let profile = DistributionProfile(
            serverURL: serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
            obsRelayURL: relayURL.trimmingCharacters(in: .whitespacesAndNewlines),
            twitchClientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
            twitchRedirectURI: redirectURI.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        do {
            try profile.validate()
            if importedAdminToken != nil && profile.obsRelayURL != importedTokenRelayURL {
                throw DistributionSetupError.invalid("個人用設定のOBS接続先が変更されています。正しい設定ファイルを読み込み直してください。")
            }
            if store.serverURL != profile.serverURL {
                store.disconnect()
                for channel in store.channels {
                    KeychainStore.delete(channel.alertURLKey)
                    if let accountID = channel.serverAccountID {
                        KeychainStore.delete("kick_send_key_\(accountID)")
                    }
                }
                store.channels = []
                store.events = []
            }
            if remote.serverURL != (profile.obsRelayURL ?? "") {
                remote.disconnect(shouldReconnect: false)
                remote.adminToken = ""
            }
            store.serverURL = profile.serverURL
            store.saveServerURL()
            remote.serverURL = profile.obsRelayURL ?? ""
            if let adminToken = importedAdminToken { remote.adminToken = adminToken }
            twitch.oauthClientID = profile.twitchClientID ?? ""
            twitch.oauthRedirectURI = profile.twitchRedirectURI ?? ""
            setupComplete = true
            store.connect()
            Task { await store.syncAccountsFromServer() }
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
