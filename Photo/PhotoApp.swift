import SwiftUI
import UIKit

/// 全局的屏幕方向开关。
///
/// 整个 App 是按竖屏设计的：网格的列宽是量出来的固定值，一旦允许全局旋转，
/// 横屏时量到的宽度会残留到转回竖屏之后，三列卡片按横屏宽度排就全挤出屏幕。
/// 所以默认锁竖屏，只有视频播放页临时放开横屏。
final class AppDelegate: NSObject, UIApplicationDelegate {

    @MainActor static var allowedOrientations: UIInterfaceOrientationMask = .portrait

    nonisolated func application(_ application: UIApplication,
                                 supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { AppDelegate.allowedOrientations }
    }
}

@main
struct PhotoApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    @State private var store: LibraryStore
    @State private var wifi: WiFiService

    init() {
        let store = LibraryStore()
        _store = State(initialValue: store)
        _wifi = State(initialValue: WiFiService(store: store))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(wifi)
                .tint(Theme.accent)
        }
    }
}

// MARK: - 导航路由

enum Route: Hashable {
    case group(UUID)
    case folder(UUID)
}
