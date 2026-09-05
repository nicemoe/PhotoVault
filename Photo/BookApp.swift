import SwiftUI

@main
struct BookApp: App {

    @State private var books: BookLibrary
    @State private var wifi: WiFiService

    init() {
        let books = BookLibrary()
        _books = State(initialValue: books)
        _wifi = State(initialValue: WiFiService(books: books))
    }

    var body: some Scene {
        WindowGroup {
            BookshelfView()
                .environment(books)
                .environment(wifi)
                .tint(Theme.accent)
                // 外观作用在 window 上，所以在最外层统一处理。
                // 不用 preferredColorScheme：它设过非 nil 之后再设回 nil
                // 并不会恢复成跟随系统，只有 .unspecified 能真正还原。
                .onChange(of: books.appearance, initial: true) { _, theme in
                    theme.apply()
                }
        }
    }
}
