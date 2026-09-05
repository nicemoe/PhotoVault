# Photo · 分组相册

一个 iOS 相册 App：**分组 → 目录 → 图片** 三层结构，支持从系统相册导入，也支持在同一 WiFi 下用浏览器上传和管理。

原生 SwiftUI，零第三方依赖。

---

## 打开与运行

```bash
open Photo.xcodeproj
```

1. 用 **Xcode 16 及以上**打开（项目用了 Xcode 16 的「文件系统同步分组」，新增文件不用手动加进工程）。
2. 选中 `Photo` target → **Signing & Capabilities** → 填自己的 Team（Bundle Identifier 已是 `cn.nicemoe.box`，换成你自己的也可以）。
3. 选真机运行。

> WiFi 上传必须用**真机**：模拟器和电脑共用网卡，地址不是手机的局域网地址。
> 首次开启 WiFi 上传时，系统会弹「允许查找并连接本地网络设备」，必须点允许。

- 最低系统：iOS 17.0
- 界面按 iPhone 16 Pro Max（440×956pt）排版，其他机型自适应

---

## 功能

### 三层结构

| 层级 | 说明 |
| --- | --- |
| 分组 | 首页展示，2 列卡片，封面是组内最近 4 张照片的拼贴 |
| 目录 | 进入分组后创建，同样是卡片网格 |
| 图片 | 进入目录后是 3 列照片墙，点开可全屏缩放浏览 |

### 首页右上角

- **排序按钮**（左）：自定义顺序 / 名称升降序 / 创建时间新旧 / 照片数量，另有「手动调整顺序…」拖拽排序
- **加号**（右）：新建分组 · 从相册导入图片 · WiFi 上传

从相册导入时会先让你选目标目录，选目录的界面里可以就地新建分组和目录。

### 目录内

- 右上「多选」：全选 / 移动到其他目录 / 批量删除
- 长按单张照片：删除
- 点开照片：双指缩放、双击放大、左右滑动翻页、分享、删除
- 从别的 App 拖图片进来（iPad 分屏、「文件」App）可直接导入，也可以拖到分组页的目录卡片上

### WiFi 上传

手机上开启后会显示形如 `http://192.168.1.23:8080` 的地址和二维码。同一 WiFi 下的电脑或另一台手机用浏览器打开，就能：

- 新建 / 重命名 / 删除分组
- 在分组内新建 / 重命名 / 删除目录
- **把目录移动到其他分组**
- 上传图片，浏览和删除已有图片

网页端是同样的扁平化设计，跟随系统深浅色。

#### 拖拽上传

一次可以拖很多张，不限单张：

| 拖到哪 | 结果 |
| --- | --- |
| 目录页的任意位置 | 传到当前目录，整页高亮并显示目录名 |
| 分组页的某个目录卡片 | 直接传到那个目录，卡片高亮提示「松开上传到这里」 |
| 整个文件夹 | 递归取出里面所有图片一起传（`webkitGetAsEntry`） |

非图片文件会被自动过滤并在结果里说明。文件按 **20MB / 25 个一批**切分发送，显示总进度——手机端是把整个请求体读进内存再解析的，一次几百 MB 会被系统回收。当然也保留了点按钮选文件的方式，同样支持多选。

---

## 界面设计

扁平化，不用渐变和投影，层次靠**实色块 + 1px 描边 + 大圆角**建立。

| | 浅色 | 深色 |
| --- | --- | --- |
| 主色 | `#2F6FED` | `#5B8DFF` |
| 页面底 | `#F4F5F7` | `#0E1014` |
| 卡片 | `#FFFFFF` | `#191C22` |
| 描边 | `#E4E7EC` | `#2A2F39` |
| 正文 | `#12141A` | `#F2F4F8` |
| 次要文字 | `#767E90` | `#8B93A6` |

分组配色 8 色实色板：珊瑚 `#FF6B6B`、橙 `#FF922B`、黄 `#FCC419`、绿 `#51CF66`、青 `#22B8CF`、蓝 `#4C6EF5`、紫 `#845EF7`、粉 `#F06595`。

圆角：卡片 22 / 封面 18 / 照片格 12 / 按钮 14。边距：屏幕 20，卡片间距 14，照片间距 4。

全部集中在 [Theme.swift](Photo/Design/Theme.swift)，改一处全局生效。

---

## 代码结构

```
Config/Info.plist                权限声明等（在 Xcode 的 Config 组里可以直接改）
Photo/
├── PhotoApp.swift               App 入口 + 导航路由
├── Assets.xcassets              App 图标（1024 纯色扁平）+ 强调色
├── Design/Theme.swift           设计令牌：颜色 / 圆角 / 间距 / 按钮样式
├── Models/
│   ├── Models.swift             Asset / Folder / PhotoGroup / SortMode
│   └── LibraryStore.swift       数据仓库，@MainActor + @Observable，JSON 落盘
├── Media/ThumbnailCache.swift   缩略图降采样 + NSCache，App 和服务端共用
├── Server/
│   ├── HTTPTypes.swift          请求/响应模型、multipart 解析、取本机 IP
│   ├── HTTPServer.swift         基于 NWListener 的 HTTP/1.1 服务端
│   ├── WiFiService.swift        路由表，桥接 HTTP 与 LibraryStore
│   └── WebUI.swift              网页端单页应用（内嵌 HTML/CSS/JS）
└── Views/
    ├── RootView.swift           首页：分组网格 + 排序 + 加号
    ├── GroupDetailView.swift    分组详情：目录网格 + 移动目录
    ├── FolderDetailView.swift   目录详情：照片墙 + 多选
    ├── PhotoViewer.swift        全屏预览，支持缩放翻页
    ├── PickerSheets.swift       选目标目录 / 手动排序
    ├── WiFiTransferView.swift   WiFi 传输页，含二维码
    ├── DropImport.swift         跨 App 拖拽导入
    └── Components.swift         卡片、封面拼贴、空状态、Toast
```

### 数据存放

- 结构：`Documents/library.json`（写入有 400ms 合并，避免批量导入时反复落盘）
- 原图：`Documents/Media/<uuid>.<ext>`，原样保存不重新编码
- 缩略图：只在内存 `NSCache`，不占磁盘

### HTTP 服务端

`Network.framework` 的 `NWListener`，端口依次尝试 `8080 / 8081 / 8088 / 9000 / 9090`，支持 keep-alive。端口被占用时 `NWListener` 停在 `.waiting(EADDRINUSE)` 而不是 `.failed`，所以那个分支要单独识别，否则回退逻辑走不到。

请求解析分 header 和 body 两个阶段：header 阶段增量扫描分隔符，body 阶段只比长度，不会退化成 O(n²)。multipart 直接在原始 body 上扫描，不做整份拷贝。单请求上限 64MB，配合网页端的分批上传。

同时广播 Bonjour `_http._tcp`，这样系统能正确弹出本地网络权限。

| 方法 | 路径 | 作用 |
| --- | --- | --- |
| GET | `/` | 网页端 |
| GET | `/api/state` | 全部分组和目录 |
| GET | `/api/folder?id=` | 目录详情含图片列表 |
| GET | `/thumb?id=&s=` | 缩略图 |
| GET | `/photo?id=` | 原图 |
| POST | `/api/group/create` `/rename` `/delete` | 分组增删改 |
| POST | `/api/folder/create` `/rename` `/delete` `/move` | 目录增删改移 |
| POST | `/api/upload?folder=` | multipart 上传 |
| POST | `/api/asset/delete` | 删图 |

---

## GitHub Actions 自动构建

推代码上去就会自动出 IPA，不需要 Mac。

### 未签名构建（开箱即用，无需任何配置）

[.github/workflows/build-ipa.yml](.github/workflows/build-ipa.yml) —— 推 `main`/`master`、提 PR、打 `v*` 标签或手动触发时都会跑。

产物在 **Actions → 选中那次运行 → 页面底部 Artifacts** 下载。打标签会额外创建一个 Release 并把 IPA 挂上去：

```bash
git tag v1.0.0 && git push origin v1.0.0
```

出来的是未签名 IPA，不能直接装，要用工具自签侧载：

| 工具 | 平台 | 说明 |
| --- | --- | --- |
| Sideloadly | Windows / macOS | 拖进去填 Apple ID 即可，最常用 |
| AltStore | Windows / macOS | 能自动续期 |
| TrollStore | 设备端 | 系统版本支持的话可永久安装 |

免费 Apple ID 自签的有效期是 7 天，到期重签一次。

### 签名构建（需要开发者证书）

[.github/workflows/build-signed-ipa.yml](.github/workflows/build-signed-ipa.yml) —— 只能手动触发（Actions → 构建签名 IPA → Run workflow），可以选导出方式（`debugging` / `release-testing` / `app-store-connect` / `enterprise`）。

先在 **Settings → Secrets and variables → Actions** 配 4 个 secret：

| Secret | 内容 |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | 从钥匙串导出的 `.p12`，转 base64 |
| `P12_PASSWORD` | 导出 `.p12` 时设的密码 |
| `BUILD_PROVISION_PROFILE_BASE64` | 对应的 `.mobileprovision`，转 base64 |
| `KEYCHAIN_PASSWORD` | 随便一个字符串，只用于 CI 里的临时钥匙串 |

转 base64（在 Mac 上）：

```bash
base64 -i cert.p12 | pbcopy
```

Team ID 和 Bundle ID 会直接从描述文件里读出来，不用另外配；证书导入的是一次性临时钥匙串，跑完就删。注意描述文件不能是通配的（`*`），要绑定具体 Bundle ID。

两个工作流都跑在 `macos-15` 上，会自动挑机器上最新的 Xcode，并检查版本 ≥ 16（工程用了文件系统同步分组，低版本打不开）。构建号取 GitHub 的 run number，所以每次构建的 `CFBundleVersion` 都不一样。

## 已知限制

- App 切到后台或锁屏，服务会自动停止（iOS 不允许普通 App 后台持有监听 socket）。传输期间屏幕会保持常亮。
- 服务端没有鉴权，同一局域网内知道地址的人都能访问。只在可信网络下使用。
- 单请求体上限 64MB；网页端已自动分批，正常使用不会碰到。
- 目前只处理静态图片，不支持视频和 Live Photo。
