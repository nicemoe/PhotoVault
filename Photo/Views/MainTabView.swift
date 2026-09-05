import SwiftUI

struct MainTabView: View {

    @Environment(LibraryStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Environment(WiFiService.self) private var wifi

    var body: some View {
        TabView {
            RootView()
                // 叫「媒体」不叫「相册」：以后这里还要放视频
                .tabItem { Label("媒体", systemImage: "photo.on.rectangle.angled") }

            BookshelfView()
                .tabItem { Label("书架", systemImage: "books.vertical") }
        }
        // 外观作用在 window 上，所以放在最外层统一处理
        .onChange(of: store.appearance, initial: true) { _, theme in
            theme.apply()
        }
        .onChange(of: scenePhase) { _, phase in
            // 进入后台后 socket 会被系统回收，直接停掉避免显示"运行中"却连不上
            if phase == .background, wifi.isRunning { wifi.stop() }
        }
    }
}
