import SwiftUI
import UniformTypeIdentifiers

/// 「文件」选取器。
///
/// 不用 SwiftUI 的 .fileImporter：它内部是 asCopy: false，也就是让 App
/// 原地打开别人家的文件，要求 App 在 Info.plist 里声明
/// LSSupportsOpeningDocumentsInPlace。没声明的话，选取器里文件看着是亮的、
/// 点得到，但点下去什么都不会发生——就是「打开点击无效」。
///
/// 这里改成 asCopy: true：系统先把文件拷一份到 App 自己的临时目录再给 URL。
/// 拿到的是普通 URL，不用 startAccessingSecurityScopedResource；iCloud 上
/// 还没下载下来的文件，系统也会先下完再回调。反正导入本来就要把内容
/// 读进来重新落盘，多这一次拷贝不亏。
struct DocumentPicker: UIViewControllerRepresentable {

    /// 不按类型过滤。小说多半是从浏览器存下来的，很多文件没有声明类型，
    /// 用 .plainText / .epub 去过滤的话它们在选取器里是灰的。
    /// 格式由 importBook 按扩展名校验，选错了会明确说不支持哪种。
    var types: [UTType] = [.item]
    var allowsMultiple = true
    var onPick: @MainActor ([URL]) -> Void
    var onFinish: @MainActor () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = allowsMultiple
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onFinish: onFinish)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: @MainActor ([URL]) -> Void
        private let onFinish: @MainActor () -> Void

        init(onPick: @escaping @MainActor ([URL]) -> Void,
             onFinish: @escaping @MainActor () -> Void) {
            self.onPick = onPick
            self.onFinish = onFinish
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            Task { @MainActor in
                onPick(urls)
                // 装在 sheet 里的选取器不会自己退场，得我们收
                onFinish()
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            Task { @MainActor in onFinish() }
        }
    }
}
