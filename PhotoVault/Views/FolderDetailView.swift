import SwiftUI
import PhotosUI

struct FolderDetailView: View {

    let folderID: UUID

    @Environment(LibraryStore.self) private var store

    @State private var isSelecting = false
    @State private var selection: Set<UUID> = []
    @State private var viewerContext: ViewerContext?
    @State private var showPhotoPicker = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isImporting = false
    @State private var importProgress = 0.0
    @State private var showWiFi = false
    @State private var showMoveSheet = false
    @State private var showDeleteConfirm = false
    @State private var toastItem: Toast?
    @State private var screenWidth: CGFloat = 0

    private var layout: CardGridLayout {
        let width = screenWidth > 0 ? screenWidth : ScreenMetrics.fallbackWidth
        return CardGridLayout(contentWidth: max(1, width - Theme.Metric.margin * 2),
                              gap: Theme.Metric.photoGap,
                              fixedColumns: 3)
    }

    private var folder: Folder? { store.folder(folderID) }
    private var assets: [Asset] { (folder?.assets ?? []).reversed() }   // 新加入的排前面

    var body: some View {
        ScrollView {
            if let folder {
                if folder.assets.isEmpty {
                    EmptyState(
                        icon: "photo.badge.plus",
                        title: "这个目录还没有照片",
                        message: "可以从系统相册导入，\n也可以让同一 WiFi 下的电脑上传。",
                        actionTitle: "从相册导入"
                    ) {
                        showPhotoPicker = true
                    }
                    .padding(.top, 40)
                } else {
                    LazyVGrid(columns: layout.columns, spacing: Theme.Metric.photoGap) {
                        ForEach(assets) { asset in
                            photoCell(asset)
                        }
                    }
                    .padding(.horizontal, Theme.Metric.margin)
                    .padding(.top, 6)
                    .padding(.bottom, isSelecting ? 100 : 40)
                }
            }
        }
        .background(Theme.background)
        .scrollIndicators(.hidden)
        .readingWidth($screenWidth)
        // 从别的 App 拖图片进来（iPad 分屏、「文件」App 等），一次可以拖多张
        .imageDropTarget(folderID: folderID, cornerRadius: 0) { saved in
            toastItem = Toast(icon: "square.and.arrow.down.fill", text: "已导入 \(saved) 张照片")
        }
        .navigationTitle(folder?.name ?? "目录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 0) {
                    if isSelecting {
                        Button("完成") {
                            withAnimation(.easeOut(duration: 0.18)) {
                                isSelecting = false
                                selection.removeAll()
                            }
                        }
                        .font(.system(size: 16, weight: .semibold))
                    } else {
                        if !(folder?.assets.isEmpty ?? true) {
                            Button {
                                withAnimation(.easeOut(duration: 0.18)) { isSelecting = true }
                            } label: {
                                // 用纯 checkmark，不要 checkmark.circle——
                                // 外面已经有圆底了，再套一个圆就是圆中圆
                                Image(systemName: "checkmark").circleIcon(glyph: 13)
                            }
                            .buttonStyle(.plain)
                        }

                        Menu {
                            Button {
                                showPhotoPicker = true
                            } label: {
                                Label("从相册导入图片", systemImage: "photo.on.rectangle.angled")
                            }
                            Divider()
                            Button {
                                showWiFi = true
                            } label: {
                                Label("WiFi 上传", systemImage: "wifi")
                            }
                        } label: {
                            Image(systemName: "plus").circleIcon()
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting { selectionBar }
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $pickerItems,
            maxSelectionCount: nil,
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await runImport(items) }
        }
        .fullScreenCover(item: $viewerContext) { context in
            PhotoViewer(assets: context.assets, startIndex: context.index, folderID: folderID)
        }
        .sheet(isPresented: $showWiFi) { WiFiTransferView() }
        .sheet(isPresented: $showMoveSheet) {
            DestinationPickerSheet(title: "移动 \(selection.count) 张照片", excludingFolder: folderID) { target in
                let ids = selection
                store.moveAssets(ids, from: folderID, to: target)
                withAnimation { isSelecting = false; selection.removeAll() }
                toastItem = Toast(icon: "arrow.right.circle.fill", text: "已移动 \(ids.count) 张")
            }
        }
        .confirmationDialog("删除 \(selection.count) 张照片？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                let count = selection.count
                store.deleteAssets(selection, from: folderID)
                withAnimation { isSelecting = false; selection.removeAll() }
                toastItem = Toast(icon: "trash.fill", text: "已删除 \(count) 张")
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("照片将从设备中永久移除。")
        }
        .overlay {
            if isImporting { ImportProgressOverlay(progress: importProgress) }
        }
        .toast($toastItem)
    }

    // MARK: 单元格

    private func photoCell(_ asset: Asset) -> some View {
        let selected = selection.contains(asset.id)

        return Button {
            if isSelecting {
                if selected { selection.remove(asset.id) } else { selection.insert(asset.id) }
            } else {
                let list = assets
                let index = list.firstIndex(where: { $0.id == asset.id }) ?? 0
                viewerContext = ViewerContext(assets: list, index: index)
            }
        } label: {
            AssetImage(asset: asset, maxPixel: 420)
                .frame(width: layout.side, height: layout.side)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                .overlay {
                    if isSelecting {
                        RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                            .fill(Color.black.opacity(selected ? 0.25 : 0))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isSelecting {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(selected ? Color.white : Color.white.opacity(0.85))
                            .background(
                                Circle()
                                    .fill(selected ? Theme.accent : Color.black.opacity(0.25))
                                    .frame(width: 20, height: 20)
                            )
                            .padding(7)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                        .strokeBorder(selected ? Theme.accent : .clear, lineWidth: 2.5)
                }
        }
        .buttonStyle(PressableCardStyle())
        .contextMenu {
            if !isSelecting {
                Button(role: .destructive) {
                    store.deleteAssets([asset.id], from: folderID)
                } label: {
                    Label("删除照片", systemImage: "trash")
                }
            }
        }
    }

    // MARK: 多选操作条

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Button {
                if selection.count == assets.count {
                    selection.removeAll()
                } else {
                    selection = Set(assets.map(\.id))
                }
            } label: {
                Text(selection.count == assets.count ? "取消全选" : "全选")
            }
            .buttonStyle(SecondaryButtonStyle())

            Button {
                showMoveSheet = true
            } label: {
                Label("移动", systemImage: "arrow.right.square")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(selection.isEmpty)

            Button {
                showDeleteConfirm = true
            } label: {
                Label("删除", systemImage: "trash")
            }
            .buttonStyle(PrimaryButtonStyle(tint: Theme.danger))
            .disabled(selection.isEmpty)
        }
        .opacity(selection.isEmpty ? 0.75 : 1)
        .padding(.horizontal, Theme.Metric.margin)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }

    // MARK: 导入

    private func runImport(_ items: [PhotosPickerItem]) async {
        isImporting = true
        importProgress = 0
        var saved = 0

        for (index, item) in items.enumerated() {
            if let data = try? await item.loadTransferable(type: Data.self),
               await store.addImage(data: data, to: folderID) != nil {
                saved += 1
            }
            importProgress = Double(index + 1) / Double(items.count)
        }

        store.saveNow()
        pickerItems = []
        isImporting = false
        toastItem = Toast(icon: "photo.badge.checkmark", text: "已导入 \(saved) 张照片")
    }
}

// MARK: - 预览上下文

struct ViewerContext: Identifiable {
    let id = UUID()
    let assets: [Asset]
    let index: Int
}
