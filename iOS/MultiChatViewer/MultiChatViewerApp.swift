import SwiftUI

@main
struct MultiChatViewerApp: App {
    @StateObject private var store = AppStore()
    @StateObject private var obsRemote = OBSRemoteController()
    @StateObject private var twitchChat = TwitchCommentController()
    var body: some Scene {
        WindowGroup {
            IntegratedRootView()
                .environmentObject(store)
                .environmentObject(obsRemote)
                .environmentObject(twitchChat)
                .preferredColorScheme(store.preferredColorScheme)
        }
    }
}
