import SwiftUI
import UniformTypeIdentifiers

/// 从其他 App 拖图片进来（iPad 分屏、「文件」App、Safari 等）
enum DropImport {

    static func imageProviders(_ providers: [NSItemProvider]) -> [NSItemProvider] {
        providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
    }

    static func data(from provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}

/// 把任意视图变成「拖图片进来就导入到某个目录」的投放目标
struct ImageDropTarget: ViewModifier {

    let folderID: UUID
    var cornerRadius: CGFloat = Theme.Radius.cover
    var onFinish: (Int) -> Void

    @Environment(LibraryStore.self) private var store
    @State private var isTargeted = false
    @State private var isReceiving = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if isTargeted || isReceiving {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Theme.accent.opacity(0.16))
                        .overlay {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                        }
                        .overlay {
                            if isReceiving {
                                ProgressView().tint(Theme.accent)
                            } else {
                                Label("松开导入", systemImage: "square.and.arrow.down")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(Theme.surface, in: Capsule())
                            }
                        }
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: isTargeted)
            .onDrop(of: [.image], isTargeted: $isTargeted) { providers in
                let usable = DropImport.imageProviders(providers)
                guard !usable.isEmpty else { return false }

                isReceiving = true
                Task {
                    var saved = 0
                    for provider in usable {
                        if let data = await DropImport.data(from: provider),
                           await store.addImage(data: data, to: folderID) != nil {
                            saved += 1
                        }
                    }
                    store.saveNow()
                    isReceiving = false
                    onFinish(saved)
                }
                return true
            }
    }
}

extension View {
    /// - Parameter onFinish: 参数是实际导入成功的张数
    func imageDropTarget(folderID: UUID,
                         cornerRadius: CGFloat = Theme.Radius.cover,
                         onFinish: @escaping (Int) -> Void) -> some View {
        modifier(ImageDropTarget(folderID: folderID, cornerRadius: cornerRadius, onFinish: onFinish))
    }
}
