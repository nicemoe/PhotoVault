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
        let width = screenWidth > 0 ? screenWidth : ScreenMetrics.fallbackWidth
        return CardGridLayout(contentWidth: max(1, width - Theme.Metric.margin * 2),
                              gap: Theme.Metric.cardGap,
                              preferredItemWidth: 118)
    }

    private var group: PhotoGroup? { store.group(groupID) }

    var body: some View {
        @Bindable var store = store

        ScrollView {
            if let group {
                VStack(alignment: .leading, spacing: 18) {
                    header(group)

                    // 只列直接挂在分组下的那层；子目录在各自的父目录里显示
                    if group.rootFolders.isEmpty {
                        EmptyState(
                            icon: "folder.badge.plus",
                            title: "还没有目录",
                            message: "目录用来存放照片，\n里面还可以再建子目录。",
                            actionTitle: "新建目录"
                        ) {
                            newFolderName = ""
                            showCreateFolder = true
                        }
                        .padding(.top, 20)
                    } else {
                        LazyVGrid(columns: layout.columns, spacing: 16) {
                            ForEach(group.rootFolders.sorted(by: store.folderSort)) { folder in
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
            // 和首页一样：右上角只有加号和三条杠，排序收进三条杠
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 0) {
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
                        Image(systemName: "plus").circleIcon(weight: .medium)
                    }

                    PageMenu {
                        SortMenuSection(mode: $store.folderSort) { showReorder = true }
                    }
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
            Button("删除目录及其中内容", role: .destructive) {
                if let f = deletingFolder { store.deleteFolder(f.id) }
                deletingFolder = nil
            }
            Button("取消", role: .cancel) { deletingFolder = nil }
        } message: {
            if let f = deletingFolder {
                // 子目录会跟着一起删，数量必须说清楚，不然用户以为只删了一层
                let subCount = store.totalFolderCount(in: f.id)
                let photoCount = store.totalPhotoCount(in: f.id)
                Text(subCount > 0
                     ? "将删除 \(subCount) 个子目录、\(photoCount) 张照片，操作不可撤销。"
                     : "将删除 \(photoCount) 张照片，操作不可撤销。")
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
            Label("移动到…", systemImage: "arrow.right.square")
        }

        Divider()

        Button(role: .destructive) {
            deletingFolder = folder
        } label: {
            Label("删除目录", systemImage: "trash")
        }
    }
}

// MARK: - 移动目录

/// 目标可以是任意分组的根，也可以是任意目录。
struct MoveFolderSheet: View {

    let folder: Folder
    let currentGroupID: UUID
    var onMoved: () -> Void

    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// 列表里的一行：分组根或某个目录
    private struct Destination: Identifiable {
        let id: String
        let groupID: UUID
        /// nil 表示放在分组根下
        let folderID: UUID?
        let name: String
        let detail: String
        let depth: Int
        let colorIndex: Int
        /// 不能选的原因，nil 表示可选
        let blocked: String?
    }

    private var destinations: [Destination] {
        store.sortedGroups.flatMap { rows(for: $0) }
    }

    private func rows(for group: PhotoGroup) -> [Destination] {
        // 自己和自己的子孙都不能当目标：移进去这棵子树就从树上断开了，
        // parent 链还会成环，界面遍历不到头
        let forbidden = Set(group.subtree(of: folder.id).map(\.id))
        let currentParent = folder.parentID

        var out: [Destination] = [
            Destination(id: "g-\(group.id)",
                        groupID: group.id,
                        folderID: nil,
                        name: group.name,
                        detail: "\(group.rootFolders.count) 个目录 · \(group.photoCount) 张",
                        depth: 0,
                        colorIndex: group.colorIndex,
                        blocked: (group.id == currentGroupID && currentParent == nil) ? "当前" : nil)
        ]

        func walk(_ parent: UUID?, depth: Int) {
            for child in group.folders.filter({ $0.parentID == parent }).sorted(by: store.folderSort) {
                let isSelf = child.id == folder.id
                out.append(Destination(id: "f-\(child.id)",
                                       groupID: group.id,
                                       folderID: child.id,
                                       name: child.name,
                                       detail: "\(store.totalPhotoCount(in: child.id)) 张",
                                       depth: depth,
                                       colorIndex: group.colorIndex,
                                       blocked: isSelf ? "自身"
                                              : (child.id == currentParent ? "当前" : nil)))
                // 自己的子树不展开：它们全都不能选，列出来只是噪音
                if !forbidden.contains(child.id) { walk(child.id, depth: depth + 1) }
            }
        }
        walk(nil, depth: 1)
        return out
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(destinations) { item in
                        Button {
                            store.moveFolder(folder.id, toGroup: item.groupID, parent: item.folderID)
                            onMoved()
                            dismiss()
                        } label: {
                            row(item)
                        }
                        .buttonStyle(PressableCardStyle())
                        .disabled(item.blocked != nil)
                        .opacity(item.blocked != nil ? 0.5 : 1)
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

    private func row(_ item: Destination) -> some View {
        HStack(spacing: 12) {
            if item.folderID == nil {
                Circle()
                    .fill(Theme.color(at: item.colorIndex))
                    .frame(width: 12, height: 12)
            } else {
                Image(systemName: "folder.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.color(at: item.colorIndex))
                    .frame(width: 12)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
                Text(item.detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryLabel)
            }

            Spacer()

            if let blocked = item.blocked {
                Text(blocked)
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
        .padding(.vertical, 12)
        .padding(.trailing, 14)
        // 靠缩进表达层级，比画连线简单，扫一眼也够清楚
        .padding(.leading, 14 + CGFloat(item.depth) * 20)
        .flatCard(radius: 16)
        .tappableArea()
    }
}
