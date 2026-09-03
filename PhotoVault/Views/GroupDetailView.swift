import SwiftUI

struct GroupDetailView: View {

    let groupID: UUID
    @Binding var path: [Route]

    @Environment(LibraryStore.self) private var store

    @State private var showCreateFolder = false
    @State private var newFolderName = ""
    @State private var renamingFolder: Folder?
    @State private var renameText = ""
    @State private var deletingFolder: Folder?
    @State private var movingFolder: Folder?
    @State private var showReorder = false
    @State private var showWiFi = false
    @State private var toastItem: Toast?
    @State private var screenWidth: CGFloat = 0

    private var layout: CardGridLayout {
        CardGridLayout(contentWidth: max(0, screenWidth - Theme.Metric.margin * 2),
                   gap: Theme.Metric.cardGap,
                   preferredItemWidth: 190)
    }

    private var group: PhotoGroup? { store.group(groupID) }

    var body: some View {
        @Bindable var store = store

        ScrollView {
            if let group {
                VStack(alignment: .leading, spacing: 18) {
                    header(group)

                    if group.folders.isEmpty {
                        EmptyState(
                            icon: "folder.badge.plus",
                            title: "还没有目录",
                            message: "目录用来存放照片，\n可以按主题或时间来分。",
                            actionTitle: "新建目录"
                        ) {
                            newFolderName = ""
                            showCreateFolder = true
                        }
                        .padding(.top, 20)
                    } else if screenWidth > 0 {
                        LazyVGrid(columns: layout.columns, spacing: 20) {
                            ForEach(group.folders.sorted(by: store.folderSort)) { folder in
                                Button {
                                    path.append(.folder(folder.id))
                                } label: {
                                    FolderCard(folder: folder,
                                               side: layout.side,
                                               tint: Theme.color(at: group.colorIndex))
                                }
                                .buttonStyle(PressableCardStyle())
                                // 直接把图片拖到目录卡片上导入
                                .imageDropTarget(folderID: folder.id) { saved in
                                    toastItem = Toast(icon: "square.and.arrow.down.fill",
                                                      text: "已导入 \(saved) 张到「\(folder.name)」")
                                }
                                .contextMenu { folderMenu(folder) }
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Metric.margin)
                .padding(.bottom, 40)
            }
        }
        .background(Theme.background)
        .scrollIndicators(.hidden)
        .readingWidth($screenWidth)
        .navigationTitle(group?.name ?? "分组")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                SortMenu(mode: $store.folderSort) { showReorder = true }

                Menu {
                    Button {
                        newFolderName = ""
                        showCreateFolder = true
                    } label: {
                        Label("新建目录", systemImage: "folder.badge.plus")
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
        .alert("新建目录", isPresented: $showCreateFolder) {
            TextField("目录名称", text: $newFolderName)
            Button("取消", role: .cancel) {}
            Button("创建") {
                if let folder = store.addFolder(to: groupID, name: newFolderName) {
                    toastItem = Toast(icon: "checkmark.circle.fill", text: "已创建「\(folder.name)」")
                }
            }
        } message: {
            Text("例如：2025 京都、产品截图")
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
            Button("删除目录及其中照片", role: .destructive) {
                if let f = deletingFolder { store.deleteFolder(f.id) }
                deletingFolder = nil
            }
            Button("取消", role: .cancel) { deletingFolder = nil }
        } message: {
            if let f = deletingFolder {
                Text("将删除 \(f.photoCount) 张照片，操作不可撤销。")
            }
        }
        .sheet(item: $movingFolder) { folder in
            MoveFolderSheet(folder: folder, currentGroupID: groupID) {
                toastItem = Toast(icon: "arrow.right.circle.fill", text: "已移动目录")
            }
        }
        .sheet(isPresented: $showReorder) {
            ReorderFoldersSheet(groupID: groupID)
        }
        .sheet(isPresented: $showWiFi) {
            WiFiTransferView()
        }
        .toast($toastItem)
    }

    // MARK: 头部

    private func header(_ group: PhotoGroup) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.color(at: group.colorIndex))
                .frame(width: 6, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(group.folderCount) 个目录")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.label)
                Text("共 \(group.photoCount) 张照片")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.secondaryLabel)
            }
            Spacer()
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func folderMenu(_ folder: Folder) -> some View {
        Button {
            renameText = folder.name
            renamingFolder = folder
        } label: {
            Label("重命名", systemImage: "pencil")
        }

        Button {
            movingFolder = folder
        } label: {
            Label("移动到其他分组", systemImage: "arrow.right.square")
        }

        Divider()

        Button(role: .destructive) {
            deletingFolder = folder
        } label: {
            Label("删除目录", systemImage: "trash")
        }
    }
}

// MARK: - 移动目录到其他分组

struct MoveFolderSheet: View {

    let folder: Folder
    let currentGroupID: UUID
    var onMoved: () -> Void

    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(store.sortedGroups) { group in
                        Button {
                            store.moveFolder(folder.id, toGroup: group.id)
                            onMoved()
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(Theme.color(at: group.colorIndex))
                                    .frame(width: 12, height: 12)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.name)
                                        .font(.system(size: 15.5, weight: .semibold))
                                        .foregroundStyle(Theme.label)
                                    Text("\(group.folderCount) 个目录 · \(group.photoCount) 张")
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(Theme.secondaryLabel)
                                }

                                Spacer()

                                if group.id == currentGroupID {
                                    Text("当前")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Theme.secondaryLabel)
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 4)
                                        .background(Theme.fill, in: Capsule())
                                } else {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Theme.tertiaryLabel)
                                }
                            }
                            .padding(14)
                            .flatCard(radius: 16)
                            .tappableArea()
                        }
                        .buttonStyle(PressableCardStyle())
                        .disabled(group.id == currentGroupID)
                        .opacity(group.id == currentGroupID ? 0.55 : 1)
                    }
                }
                .padding(Theme.Metric.margin)
            }
            .background(Theme.background)
            .navigationTitle("移动「\(folder.name)」")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .font(.system(size: 16, weight: .semibold))
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
