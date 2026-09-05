import SwiftUI

// MARK: - 选择目标目录（导入 / 移动照片时用）

struct DestinationPickerSheet: View {

    var title: String = "选择目标目录"
    var excludingFolder: UUID? = nil
    var onPick: (UUID) -> Void

    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var showCreateGroup = false
    @State private var newGroupName = ""
    @State private var creatingFolderIn: UUID?
    @State private var newFolderName = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if store.groups.isEmpty {
                        EmptyState(
                            icon: "folder.badge.plus",
                            title: "还没有可用的目录",
                            message: "先创建一个分组，再在分组里建目录。",
                            actionTitle: "新建分组"
                        ) {
                            newGroupName = ""
                            showCreateGroup = true
                        }
                    }

                    ForEach(store.sortedGroups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Theme.color(at: group.colorIndex))
                                    .frame(width: 9, height: 9)
                                Text(group.name)
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(Theme.label)
                                Spacer()
                                Text("\(group.folderCount) 个目录")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.tertiaryLabel)
                            }
                            .padding(.horizontal, 4)

                            VStack(spacing: 6) {
                                // 按层级深度优先铺开，靠缩进表达父子；
                                // 直接列 group.folders 的话所有层级会混成一片，
                                // 顺序还是插入顺序，看不出谁在谁里面
                                ForEach(flatten(group), id: \.folder.id) { row in
                                    folderRow(row.folder,
                                              depth: row.depth,
                                              tint: Theme.color(at: group.colorIndex))
                                }

                                Button {
                                    newFolderName = ""
                                    creatingFolderIn = group.id
                                } label: {
                                    HStack(spacing: 9) {
                                        Image(systemName: "plus")
                                            .font(.system(size: 13, weight: .bold))
                                        Text("在此分组新建目录")
                                            .font(.system(size: 14.5, weight: .semibold))
                                        Spacer()
                                    }
                                    .foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 13)
                                    .background(Theme.accent.opacity(0.09),
                                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .tappableArea()
                                }
                                .buttonStyle(PressableCardStyle())
                            }
                        }
                    }
                }
                .padding(Theme.Metric.margin)
                .padding(.bottom, 20)
            }
            .background(Theme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newGroupName = ""
                        showCreateGroup = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                }
            }
            .alert("新建分组", isPresented: $showCreateGroup) {
                TextField("分组名称", text: $newGroupName)
                Button("取消", role: .cancel) {}
                Button("创建") { store.addGroup(name: newGroupName) }
            }
            .alert("新建目录", isPresented: Binding(get: { creatingFolderIn != nil }, set: { if !$0 { creatingFolderIn = nil } })) {
                TextField("目录名称", text: $newFolderName)
                Button("取消", role: .cancel) { creatingFolderIn = nil }
                Button("创建并选择") {
                    if let groupID = creatingFolderIn,
                       let folder = store.addFolder(to: groupID, name: newFolderName) {
                        creatingFolderIn = nil
                        pick(folder.id)
                    }
                    creatingFolderIn = nil
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    /// 把一个分组的目录树按显示顺序铺平，带上各自的深度
    private func flatten(_ group: PhotoGroup) -> [(folder: Folder, depth: Int)] {
        var out: [(Folder, Int)] = []
        func walk(_ parent: UUID?, depth: Int) {
            for f in group.folders.filter({ $0.parentID == parent }) {
                out.append((f, depth))
                walk(f.id, depth: depth + 1)
            }
        }
        walk(nil, depth: 0)
        return out.map { (folder: $0.0, depth: $0.1) }
    }

    private func folderRow(_ folder: Folder, depth: Int, tint: Color) -> some View {
        let disabled = folder.id == excludingFolder

        return Button {
            pick(folder.id)
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tint.opacity(0.15))
                    .frame(width: 38, height: 38)
                    .overlay {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(tint)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.label)
                    Text("\(folder.photoCount) 张照片")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondaryLabel)
                }

                Spacer()

                if disabled {
                    Text("当前目录")
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
            .padding(12)
            .padding(.leading, CGFloat(depth) * 18)   // 缩进表达层级
            .flatCard(radius: 16)
            .tappableArea()
        }
        .buttonStyle(PressableCardStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }

    private func pick(_ folderID: UUID) {
        dismiss()
        onPick(folderID)
    }
}

// MARK: - 手动排序：分组

struct ReorderGroupsSheet: View {

    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                hint("按住右侧手柄拖动，即可调整分组在首页的顺序")

                List {
                    ForEach(store.groups) { group in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Theme.color(at: group.colorIndex))
                                .frame(width: 10, height: 10)
                            Text(group.name)
                                .font(.system(size: 15.5, weight: .semibold))
                            Spacer()
                            Text("\(group.photoCount) 张")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.secondaryLabel)
                        }
                        .listRowBackground(Theme.surface)
                    }
                    .onMove { source, destination in
                        store.moveGroups(from: source, to: destination)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(Theme.background)
                .environment(\.editMode, .constant(.active))
            }
            .background(Theme.background)
            .navigationTitle("调整分组顺序")
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

// MARK: - 手动排序：目录

struct ReorderFoldersSheet: View {

    let groupID: UUID
    /// 只重排这一层。nil = 分组根下那层。
    var parentID: UUID?

    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// 同级目录。整个分组的目录是平铺存的，这里只取当前这一层，
    /// 不然会把别的层级也列进来，拖动的下标也就对不上了。
    private var siblings: [Folder] {
        (store.group(groupID)?.folders ?? []).filter { $0.parentID == parentID }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                hint(parentID == nil ? "拖动调整目录在该分组内的顺序" : "拖动调整子目录的顺序")

                List {
                    ForEach(siblings) { folder in
                        HStack(spacing: 12) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.accent)
                            Text(folder.name)
                                .font(.system(size: 15.5, weight: .semibold))
                            Spacer()
                            Text("\(store.totalPhotoCount(in: folder.id)) 张")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.secondaryLabel)
                        }
                        .listRowBackground(Theme.surface)
                    }
                    .onMove { source, destination in
                        store.moveFolders(in: groupID, parent: parentID,
                                          from: source, to: destination)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(Theme.background)
                .environment(\.editMode, .constant(.active))
            }
            .background(Theme.background)
            .navigationTitle("调整目录顺序")
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

// MARK: - 排序页顶部说明

@ViewBuilder
private func hint(_ text: String) -> some View {
    HStack(spacing: 8) {
        Image(systemName: "info.circle.fill")
            .font(.system(size: 13))
        Text(text)
            .font(.system(size: 13))
        Spacer()
    }
    .foregroundStyle(Theme.secondaryLabel)
    .padding(.horizontal, Theme.Metric.margin)
    .padding(.top, 14)
}
