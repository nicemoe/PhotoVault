import SwiftUI
import PhotosUI

struct RootView: View {

    @Environment(LibraryStore.self) private var store
    @Environment(WiFiService.self) private var wifi
    @Environment(\.scenePhase) private var scenePhase

    @State private var path: [Route] = []

    // 弹窗状态
    @State private var showCreateGroup = false
    @State private var newGroupName = ""
    @State private var renamingGroup: PhotoGroup?
    @State private var renameText = ""
    @State private var deletingGroup: PhotoGroup?
    @State private var showReorder = false
    @State private var showWiFi = false
    @State private var showImportDestination = false
    @State private var showPhotoPicker = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var pendingDestination: UUID?     // 目的地选择器回传
    @State private var importDestination: UUID?      // 实际导入的目录 id
    @State private var isImporting = false
    @State private var importProgress = 0.0
    @State private var toastItem: Toast?
    @State private var screenWidth: CGFloat = 0

    private var layout: CardGridLayout {
        let width = screenWidth > 0 ? screenWidth : ScreenMetrics.fallbackWidth
        return CardGridLayout(contentWidth: max(1, width - Theme.Metric.margin * 2),
                              gap: Theme.Metric.cardGap,
                              preferredItemWidth: 190)
    }

    var body: some View {
        @Bindable var store = store

        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    StatBar(items: [
                        ("\(store.groups.count)", "分组"),
                        ("\(store.groups.reduce(0) { $0 + $1.folderCount })", "目录"),
                        ("\(store.totalPhotoCount)", "照片")
                    ])
                    .padding(.top, 4)

                    if store.groups.isEmpty {
                        EmptyState(
                            icon: "square.grid.2x2",
                            title: "还没有分组",
                            message: "分组用来归类目录，目录里存放照片。\n先建一个分组开始吧。",
                            actionTitle: "新建分组"
                        ) {
                            newGroupName = ""
                            showCreateGroup = true
                        }
                        .padding(.top, 30)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("全部分组")
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundStyle(Theme.label)
                                Spacer()
                                Label(store.groupSort.title, systemImage: store.groupSort.icon)
                                    .labelStyle(.titleOnly)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(Theme.secondaryLabel)
                            }

                            LazyVGrid(columns: layout.columns, spacing: 20) {
                                ForEach(store.sortedGroups) { group in
                                    Button {
                                        path.append(.group(group.id))
                                    } label: {
                                        GroupCard(group: group, side: layout.side)
                                    }
                                    .buttonStyle(PressableCardStyle())
                                    .contextMenu { groupMenu(group) }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Metric.margin)
                .padding(.bottom, 40)
            }
            .background(Theme.background)
            .scrollIndicators(.hidden)
            .readingWidth($screenWidth)
            .navigationTitle("相册")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 6) {
                        sideMenu

                        if wifi.isRunning {
                            Button {
                                showWiFi = true
                            } label: {
                                HStack(spacing: 5) {
                                    Circle().fill(Color(hex: 0x2FBF5B)).frame(width: 6, height: 6)
                                    Text("传输中")
                                        .font(.system(size: 12.5, weight: .semibold))
                                }
                                .foregroundStyle(Theme.secondaryLabel)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Theme.fill, in: Capsule())
                            }
                        }
                    }
                }
                // 两个按钮放进同一个 ToolbarItem 里用 HStack 摆，
                // 这样各级页面的按钮位置和间距完全一致；交给
                // ToolbarItemGroup 排的话间距由系统决定，会偏大。
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 0) {
                        SortMenu(mode: $store.groupSort) { showReorder = true }
                        addMenu
                    }
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .group(let id):
                    GroupDetailView(groupID: id, path: $path)
                case .folder(let id):
                    FolderDetailView(folderID: id)
                }
            }
        }
        // MARK: 新建分组
        .alert("新建分组", isPresented: $showCreateGroup) {
            TextField("分组名称", text: $newGroupName)
            Button("取消", role: .cancel) {}
            Button("创建") {
                let group = store.addGroup(name: newGroupName)
                toastItem = Toast(icon: "checkmark.circle.fill", text: "已创建「\(group.name)」")
            }
        } message: {
            Text("例如：旅行、工作、灵感")
        }
        // MARK: 重命名
        .alert("重命名分组", isPresented: Binding(get: { renamingGroup != nil }, set: { if !$0 { renamingGroup = nil } })) {
            TextField("分组名称", text: $renameText)
            Button("取消", role: .cancel) { renamingGroup = nil }
            Button("保存") {
                if let g = renamingGroup { store.renameGroup(g.id, to: renameText) }
                renamingGroup = nil
            }
        }
        // MARK: 删除确认
        .confirmationDialog(
            deletingGroup.map { "删除「\($0.name)」" } ?? "",
            isPresented: Binding(get: { deletingGroup != nil }, set: { if !$0 { deletingGroup = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除分组及其中全部照片", role: .destructive) {
                if let g = deletingGroup { store.deleteGroup(g.id) }
                deletingGroup = nil
            }
            Button("取消", role: .cancel) { deletingGroup = nil }
        } message: {
            if let g = deletingGroup {
                Text("将删除 \(g.folderCount) 个目录、\(g.photoCount) 张照片，操作不可撤销。")
            }
        }
        // MARK: 排序 / WiFi / 导入
        .sheet(isPresented: $showReorder) {
            ReorderGroupsSheet()
        }
        .sheet(isPresented: $showWiFi) {
            WiFiTransferView()
        }
        .sheet(isPresented: $showImportDestination, onDismiss: {
            guard let target = pendingDestination else { return }
            pendingDestination = nil
            importDestination = target
            // 等目的地选择器完全消失，再拉起系统相册选择器
            Task {
                try? await Task.sleep(for: .milliseconds(280))
                showPhotoPicker = true
            }
        }) {
            DestinationPickerSheet { folderID in
                pendingDestination = folderID
            }
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $pickerItems,
            maxSelectionCount: nil,
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty, let target = importDestination else { return }
            Task { await runImport(items: items, into: target) }
        }
        .onChange(of: showPhotoPicker) { _, shown in
            // 用户在系统相册里点了取消：清掉残留的目标目录，免得带到下一次
            guard !shown else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                if !isImporting, pickerItems.isEmpty { importDestination = nil }
            }
        }
        .overlay {
            if isImporting {
                ImportProgressOverlay(progress: importProgress)
            }
        }
        // 作用在 window 上，所以 sheet、全屏预览都会跟着走
        .onChange(of: store.appearance, initial: true) { _, theme in
            theme.apply()
        }
        .onChange(of: scenePhase) { _, phase in
            // 进入后台后 socket 会被系统回收，直接停掉避免显示"运行中"却连不上
            if phase == .background, wifi.isRunning { wifi.stop() }
        }
        .toast($toastItem)
    }

    // MARK: 加号菜单

    private var addMenu: some View {
        Menu {
            Button {
                newGroupName = ""
                showCreateGroup = true
            } label: {
                Label("新建分组", systemImage: "folder.badge.plus")
            }

            Button {
                showImportDestination = true
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

    // MARK: 左上角菜单
    //
    // 三条杠是「容器」语义，不需要表达里面装了什么，所以不用再纠结
    // 「哪个图标代表外观」；以后要加别的设置也有地方放。
    // 加号保持纯粹的「添加」，两者语义不重叠。

    private var sideMenu: some View {
        Menu {
            // 外观作为一个条目收在这里，点开才是三个选项。
            // 不把三个选项直接铺在第一层，是为了给后续功能留位置。
            Menu {
                Picker("", selection: Binding(
                    get: { store.appearance },
                    set: { store.appearance = $0 }
                )) {
                    ForEach(AppTheme.allCases) { theme in
                        Label(theme.title, systemImage: theme.icon).tag(theme)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                // 一级条目直接显示当前选中的值（跟随系统 / 浅色 / 深色），
                // 不要再加「外观」前缀——展开后的对勾已经说明了它是什么
                Label(store.appearance.title, systemImage: store.appearance.icon)
            }
        } label: {
            // 三条杠是自己画的，宽度/线宽/行距各自独立可调，
            // 见 HamburgerIcon 里的说明
            HamburgerIcon().circleIcon()
        }
    }

    @ViewBuilder
    private func groupMenu(_ group: PhotoGroup) -> some View {
        Button {
            renameText = group.name
            renamingGroup = group
        } label: {
            Label("重命名", systemImage: "pencil")
        }

        Menu {
            ForEach(Array(Theme.palette.enumerated()), id: \.offset) { index, _ in
                Button {
                    store.setGroupColor(group.id, index: index)
                } label: {
                    Label(colorName(index), systemImage: index == group.colorIndex ? "checkmark.circle.fill" : "circle.fill")
                }
            }
        } label: {
            Label("更换颜色", systemImage: "paintpalette")
        }

        Divider()

        Button(role: .destructive) {
            deletingGroup = group
        } label: {
            Label("删除分组", systemImage: "trash")
        }
    }

    private func colorName(_ index: Int) -> String {
        let names = ["珊瑚", "橙", "黄", "绿", "青", "蓝", "紫", "粉"]
        return names[((index % names.count) + names.count) % names.count]
    }

    // MARK: 导入

    private func runImport(items: [PhotosPickerItem], into folderID: UUID) async {
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
        importDestination = nil
        isImporting = false
        toastItem = Toast(icon: "photo.badge.checkmark", text: "已导入 \(saved) 张照片")
    }
}

// MARK: - 导入进度遮罩

struct ImportProgressOverlay: View {
    let progress: Double

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
                    .frame(width: 180)
                Text("正在导入 \(Int(progress * 100))%")
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(Theme.secondaryLabel)
            }
            .padding(28)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}
