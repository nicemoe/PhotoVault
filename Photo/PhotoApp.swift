import SwiftUI

@main
struct PhotoApp: App {

    @State private var store: LibraryStore
    @State private var books: BookLibrary
    @State private var wifi: WiFiService

    init() {
        let store = LibraryStore()
        let books = BookLibrary()
        _store = State(initialValue: store)
        _books = State(initialValue: books)
        _wifi = State(initialValue: WiFiService(store: store, books: books))
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environment(store)
                .environment(books)
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
