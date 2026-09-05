import Foundation
import UIKit

// MARK: - 外观

enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light:  return "浅色"
        case .dark:   return "深色"
        }
    }

    /// 只用在菜单行里。菜单行没有圆形底，所以可以放心用最标准的那套图标，
    /// 圆环字形在这里不会变成「圆套圆」。
    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }

    /// 用 UIKit 的 overrideUserInterfaceStyle 而不是 SwiftUI 的 preferredColorScheme：
    /// 后者一旦设过非 nil 值，再设回 nil 并不会恢复成跟随系统，
    /// 只有 .unspecified 能真正还原。
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    @MainActor
    func apply() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = interfaceStyle
            }
        }
    }
}
