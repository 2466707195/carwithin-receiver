import SwiftUI

@main
struct CarWithinReceiverApp: App {

    @StateObject private var controller = ReceiverController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(controller)
                .preferredColorScheme(.light)
        }
    }
}

/// 只有两个界面：没在连接时是连接页，连上就整屏播放。
struct RootView: View {

    @EnvironmentObject private var controller: ReceiverController
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if controller.isBusy {
                PlayerScreen()
            } else {
                ConnectScreen()
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                controller.resumeIfNeeded()
            }
        }
    }
}
