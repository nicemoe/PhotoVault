import SwiftUI

@main
struct PhotoApp: App {

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
