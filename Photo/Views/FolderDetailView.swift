import SwiftUI
import PhotosUI

struct FolderDetailView: View {

    let folderID: UUID
    @Binding var path: [Route]

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

    // 子目录
    @State private var showCreateFolder = false
    @State private var newFolderName = ""
    @State private var renamingFolder: Folder?
    @State private var renameText = ""
    @State private var deletingFolder: Folder?
    @State private var movingFolder: Folder?
    @State private var showReorder = false

    /// 照片用固定三列
    private var layout: CardGridLayout {
        let width = screenWidth > 0 ? screenWidth : ScreenMetrics.fallbackWidth
        return CardGridLayout(contentWidth: max(1, width - Theme.Metric.margin * 2),
                              gap: Theme.Metric.photoGap,
                              fixedColumns: 3)
    }

    /// 子目录卡片和分组页用同一套尺寸
    private var folderLayout: CardGridLayout {
        let width = screenWidth > 0 ? screenWidth : ScreenMetrics.fallbackWidth
        return CardGridLayout(contentWidth: max(1, width - Theme.Metric.margin * 2),
                              gap: Theme.Metric.cardGap,
                              preferredItemWidth: 190)
    }

    private var folder: Folder? { store.folder(folderID) }
    private var assets: [Asset] { (folder?.assets ?? []).reversed() }   // 新加入的排前面
    private var children: [Folder] { store.children(of: folderID).sorted(by: store.folderSort) }
    private var groupID: UUID? { store.groupID(containing: folderID) }
    private var tint: Color {
        guard let gid = groupID, let g = store.group(gid) else { return Theme.accent }
        return Theme.color(at: g.colorIndex)
    }

    var body: some View {
        @Bindable var store = store

        return ScrollView {
            if let folder {
                VStack(alignment: .leading, spacing: 16) {
                    breadcrumb

                    if !children.isEmpty {
                        subfolderSection
                    }

                    if folder.assets.isEmpty && children.isEmpty {
                        EmptyState(
                            icon: "photo.badge.plus",
                            title: "这个目录是空的",
                            message: "可以从系统相册导入照片，\n也可以在里面再建子目录来分类。",
                            actionTitle: "从相册导入"
                        ) {
                            showPhotoPicker = true
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 30)
                    } else if !folder.assets.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            if !children.isEmpty {
                                sectionTitle("照片", count: folder.assets.count)
                            }
                            LazyVGrid(columns: layout.columns, spacing: Theme.Metric.photoGap) {
                                ForEach(assets) { asset in
                                    photoCell(asset)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Metric.margin)
                .padding(.top, 6)
                .padding(.bottom, isSelecting ? 100 : 40)
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
            // 和首页一样：右上角只有加号和三条杠，选择、排序都收进三条杠
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
                        Menu {
                            Button {
                                newFolderName = ""
                                showCreateFolder = true
                            } label: {
                                Label("新建子目录", systemImage: "folder.badge.plus")
                            }
                            Divider()
                            Button {
                                showPhotoPicker = true
                            } label: {
                                Label("从相册导入", systemImage: "photo.on.rectangle.angled")
                            }
                            Button {
                                showWiFi = true
                            } label: {
                                Label("WiFi 上传", systemImage: "wifi")
                            }
                        } label: {
                            Image(systemName: "plus").circleIcon()
                        }

                        PageMenu {
                            if !(folder?.assets.isEmpty ?? true) {
                                Button {
                                    withAnimation(.easeOut(duration: 0.18)) { isSelecting = true }
                                } label: {
                                    Label("选择", systemImage: "checkmark.circle")
                                }
                            }
                            if !children.isEmpty {
                                SortMenuSection(mode: $store.folderSort) { showReorder = true }
                            }
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
            matching: .any(of: [.images, .videos]),
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
        .sheet(isPresented: $showReorder) {
            // 只重排本目录下的这一层子目录
            ReorderFoldersSheet(groupID: groupID ?? UUID(), parentID: folderID)
        }
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
        .alert("新建子目录", isPresented: $showCreateFolder) {
            TextField("目录名称", text: $newFolderName)
            Button("取消", role: .cancel) {}
            Button("创建") {
                guard let gid = groupID,
                      let sub = store.addFolder(to: gid, name: newFolderName, parent: folderID) else { return }
                toastItem = Toast(icon: "checkmark.circle.fill", text: "已创建「\(sub.name)」")
            }
        } message: {
            Text("例如：照片、视频、原图")
        }
        .alert("重命名目录", isPresented: Binding(get: { renamingFolder != nil }, set: { if !$0 { renamingFolder = nil } })) {
            TextField("目录名称", text: $renameText)
            Button("取消", role: .cancel) { renamingFolder = nil }
            Button("保存") {
                if let f = renamingFolder { store.renameFolder(f.id, to: renameText) }
                renamingFolder = nil
            }
        }
        .confirmationDialog(
            deletingFolder.map { "删除「\($0.name)」" } ?? "",
            isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除目录及其中内容", role: .destructive) {
                if let f = deletingFolder { store.deleteFolder(f.id) }
                deletingFolder = nil
            }
            Button("取消", role: .cancel) { deletingFolder = nil }
        } message: {
            if let f = deletingFolder {
                let subCount = store.totalFolderCount(in: f.id)
                let photoCount = store.totalPhotoCount(in: f.id)
                Text(subCount > 0
                     ? "将删除 \(subCount) 个子目录、\(photoCount) 张照片，操作不可撤销。"
                     : "将删除 \(photoCount) 张照片，操作不可撤销。")
            }
        }
        .sheet(item: $movingFolder) { sub in
            MoveFolderSheet(folder: sub, currentGroupID: groupID ?? UUID()) {
                toastItem = Toast(icon: "arrow.right.circle.fill", text: "已移动目录")
            }
        }
        .overlay {
            if isImporting { ImportProgressOverlay(progress: importProgress) }
        }
        .toast($toastItem)
    }

    // MARK: 面包屑与子目录

    /// 分组 › 上级目录 …
    ///
    /// 导航栏只显示当前目录名，层数一多就不知道自己在哪儿了。
    @ViewBuilder
    private var breadcrumb: some View {
        let chain = store.path(to: folderID).dropLast()   // 最后一个是自己，标题已经写了
        if let gid = groupID, let group = store.group(gid) {
            HStack(spacing: 5) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 10))
                Text(group.name)
                ForEach(chain) { node in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    Text(node.name)
                }
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Theme.secondaryLabel)
            .lineLimit(1)
        }
    }

    private func sectionTitle(_ text: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.label)
            Text("\(count)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.secondaryLabel)
        }
    }

    private var subfolderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("子目录", count: children.count)

            LazyVGrid(columns: folderLayout.columns, spacing: 20) {
                ForEach(children) { sub in
                    Button {
                        path.append(.folder(sub.id))
                    } label: {
                        FolderCard(folder: sub, side: folderLayout.side, tint: tint)
                    }
                    .buttonStyle(PressableCardStyle())
                    .imageDropTarget(folderID: sub.id) { saved in
                        toastItem = Toast(icon: "square.and.arrow.down.fill",
                                          text: "已导入 \(saved) 张到「\(sub.name)」")
                    }
                    .contextMenu { subfolderMenu(sub) }
                }
            }
        }
    }

    @ViewBuilder
    private func subfolderMenu(_ sub: Folder) -> some View {
        Button {
            renameText = sub.name
            renamingFolder = sub
        } label: {
            Label("重命名", systemImage: "pencil")
        }

        Button {
            movingFolder = sub
        } label: {
            Label("移动到…", systemImage: "arrow.right.square")
        }

        Divider()

        Button(role: .destructive) {
            deletingFolder = sub
        } label: {
            Label("删除目录", systemImage: "trash")
        }
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
                // 尺寸跟着列宽走，不用量出来的 side ——
                // 测量值一过时就会把整片格子挤出屏幕
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                .overlay {
                    if isSelecting {
                        RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                            .fill(Color.black.opacity(selected ? 0.25 : 0))
                    }
                }
                // 视频角标放左下，选择标记在右下，两边不打架
                .overlay(alignment: .bottomLeading) {
                    if asset.isVideo {
                        HStack(spacing: 3) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 8.5, weight: .bold))
                            Text(asset.durationText)
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.45), in: Capsule())
                        .padding(6)
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
                    Label(asset.isVideo ? "删除视频" : "删除照片", systemImage: "trash")
                }
            }
        }
    }

    // MARK: 多选操作条

    /// 多选操作条：左边一个全选勾选框，右边移动和删除两个图标。
    /// 不用带文字的按钮——一排方块把这条压得又高又满，图标就够了。
    private var selectionBar: some View {
        let allSelected = !assets.isEmpty && selection.count == assets.count

        return HStack(spacing: 6) {
            Button {
                selection = allSelected ? [] : Set(assets.map(\.id))
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: allSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(allSelected ? Theme.accent : Theme.secondaryLabel)
                    Text(selection.isEmpty ? "全选" : "已选 \(selection.count)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.label)
                        .monospacedDigit()
                }
                .padding(.vertical, 6)
                .padding(.trailing, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            selectionAction("arrow.right.square", tint: Theme.accent) { showMoveSheet = true }
            selectionAction("trash", tint: Theme.danger) { showDeleteConfirm = true }
        }
        .padding(.horizontal, Theme.Metric.margin)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }

    private func selectionAction(_ icon: String, tint: Color,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(selection.isEmpty)
        .opacity(selection.isEmpty ? 0.3 : 1)
    }

    // MARK: 导入

    private func runImport(_ items: [PhotosPickerItem]) async {
        isImporting = true
        importProgress = 0
        var photos = 0
        var videos = 0

        for (index, item) in items.enumerated() {
            // 视频必须按文件搬。手机拍的 1 分钟 4K 就有几百 MB，
            // 走 Data 读进内存会直接被系统杀掉。
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                    if await store.addVideo(from: movie.url, to: folderID) != nil { videos += 1 }
                    // persistVideo 成功时是移动走的，失败才留下，这里兜底清一次
                    try? FileManager.default.removeItem(at: movie.url)
                }
            } else if let data = try? await item.loadTransferable(type: Data.self),
                      await store.addImage(data: data, to: folderID) != nil {
                photos += 1
            }
            importProgress = Double(index + 1) / Double(items.count)
        }

        store.saveNow()
        pickerItems = []
        isImporting = false

        let parts = [photos > 0 ? "\(photos) 张照片" : nil,
                     videos > 0 ? "\(videos) 个视频" : nil].compactMap { $0 }
        toastItem = Toast(icon: "photo.badge.checkmark",
                          text: parts.isEmpty ? "没有导入任何内容" : "已导入 " + parts.joined(separator: "、"))
    }
}

// MARK: - 从系统相册取视频

/// PhotosPicker 给视频的是一个临时文件。
/// 它在回调返回后就会被清掉，所以必须先拷到自己的临时目录再用。
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "." + received.file.pathExtension)
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

// MARK: - 预览上下文

struct ViewerContext: Identifiable {
    let id = UUID()
    let assets: [Asset]
    let index: Int
}
