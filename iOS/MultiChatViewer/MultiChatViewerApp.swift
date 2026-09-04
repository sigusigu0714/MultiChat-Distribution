import SwiftUI

@main
struct MultiChatViewerApp: App {
    @StateObject private var store = AppStore()
    @StateObject private var obsRemote = OBSRemoteController()
    @StateObject private var twitchChat = TwitchCommentController()
    @ViewBuilder private var rootView: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--alert-queue-test") {
            AlertQueueFixture()
        } else if ProcessInfo.processInfo.arguments.contains("--alert-focus-test") {
            AlertFocusFixture().padding(8)
        } else if ProcessInfo.processInfo.arguments.contains("--alert-layout-test") {
            AlertLayoutFixture().padding(8)
        } else {
            IntegratedRootView()
        }
        #else
        IntegratedRootView()
        #endif
    }
    var body: some Scene {
        WindowGroup {
            rootView
                .environmentObject(store)
                .environmentObject(obsRemote)
                .environmentObject(twitchChat)
                .preferredColorScheme(store.preferredColorScheme)
        }
    }
}
