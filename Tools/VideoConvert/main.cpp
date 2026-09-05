// 转片 —— 把手机放不了的视频批量转成 iOS 能直接播的 mp4。
//
// 纯 Win32，除了系统自带的 comctl32 / shell32 / ole32 没有任何依赖。
// 实际干活的是 ffmpeg：本程序只负责排队、探测、拼命令行、盯进度。
//
// 为什么在电脑上转而不是在手机上解：iOS 只有 H.264/HEVC 有硬件解码器，
// mkv、rmvb、wmv 这些要么封装不认、要么编码不认。手机上塞软解码器的话
// 费电、发热、高码率还掉帧；在电脑上转一次，之后每次播放都是硬件解码。

#include <windows.h>
#include <commctrl.h>
#include <shlobj.h>
#include <shellapi.h>
#include <string>
#include <vector>
#include <algorithm>
#include <mutex>

#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "comctl32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "comdlg32.lib")   // GetOpenFileNameW

// 用 v6 的通用控件，列表和按钮才是现在这个样子而不是 Win95 的样子
#pragma comment(linker, "\"/manifestdependency:type='win32' \
name='Microsoft.Windows.Common-Controls' version='6.0.0.0' \
processorArchitecture='amd64' publicKeyToken='6595b64144ccf1df' language='*'\"")

// ── 控件 ID ──────────────────────────────────────────────────────────
enum {
    ID_LIST = 1001,
    ID_QUALITY, ID_QUALITY_LABEL,
    ID_ADD_FILES, ID_ADD_FOLDER, ID_REMOVE, ID_CLEAR,
    ID_OUT_EDIT, ID_OUT_PICK,
    ID_START, ID_STOP,
    ID_SKIP_EXISTING, ID_PROGRESS, ID_STATUS
};

// 工作线程发给界面的消息
enum {
    MSG_ITEM = WM_APP + 1,   // wParam = 行号，那一行的字段已经更新好了
    MSG_DONE = WM_APP + 2,   // 整个队列跑完
    MSG_BUSY = WM_APP + 3    // wParam = 是否正在跑，用来开关按钮
};

// ── 一个待转的文件 ───────────────────────────────────────────────────
struct Item {
    std::wstring path;      // 源文件绝对路径
    std::wstring relDir;    // 相对子目录。按文件夹添加时保留结构，
                            // 这样倒进 App 的「导入」文件夹还能分好组
    std::wstring name;      // 显示用的文件名
    std::wstring plan;      // 处理方式：换壳 / 重编码
    std::wstring status;    // 状态文字
    int percent = -1;       // -1 表示还没开始
    bool finished = false;
};

// ── 全局状态 ─────────────────────────────────────────────────────────
static HWND g_main, g_list, g_outEdit, g_progress, g_status;
static HWND g_btnStart, g_btnStop, g_btnAddFiles, g_btnAddFolder,
            g_btnRemove, g_btnClear, g_btnOutPick, g_chkSkip, g_quality;

/// 画质档。CRF 越小越清楚、文件越大；preset 越慢压得越狠，同样画质文件更小。
///
/// 默认给「高」：这批片子是要留着看的，不是赶时间过一遍。CRF 18 在 x264 上
/// 基本看不出和源的差别，slow 比 medium 慢六七成，但换来同画质下更小的体积。
struct QualityLevel {
    const wchar_t* label;
    const wchar_t* preset;
    int crf;
};
static const QualityLevel kQuality[] = {
    { L"高画质（慢）",   L"slow",   18 },
    { L"标准",           L"medium", 20 },
    { L"快（画质一般）", L"veryfast", 23 },
};
static HFONT g_font;

static std::vector<Item> g_items;
static std::mutex g_lock;          // g_items 会被两个线程读写

static std::wstring g_ffmpeg, g_ffprobe, g_outDir;
static volatile bool g_running = false;
static volatile bool g_cancel = false;
static HANDLE g_child = nullptr;   // 正在跑的 ffmpeg，停止时要杀掉
static std::mutex g_childLock;

// ── 小工具 ───────────────────────────────────────────────────────────

/// ffmpeg 在 Windows 上的输出有时是 UTF-8、有时是本地代码页，
/// 先按 UTF-8 严格解，解不动再退回本地代码页
static std::wstring Widen(const std::string& s) {
    if (s.empty()) return L"";
    for (UINT cp : { (UINT)CP_UTF8, (UINT)CP_ACP }) {
        DWORD flags = (cp == CP_UTF8) ? MB_ERR_INVALID_CHARS : 0;
        int n = MultiByteToWideChar(cp, flags, s.c_str(), (int)s.size(), nullptr, 0);
        if (n <= 0) continue;
        std::wstring out(n, L'\0');
        MultiByteToWideChar(cp, flags, s.c_str(), (int)s.size(), &out[0], n);
        return out;
    }
    return L"";
}

static std::wstring Lower(std::wstring s) {
    std::transform(s.begin(), s.end(), s.begin(), ::towlower);
    return s;
}

static std::wstring DirOf(const std::wstring& path) {
    size_t i = path.find_last_of(L"\\/");
    return i == std::wstring::npos ? L"" : path.substr(0, i);
}

static std::wstring NameOf(const std::wstring& path) {
    size_t i = path.find_last_of(L"\\/");
    return i == std::wstring::npos ? path : path.substr(i + 1);
}

static std::wstring StemOf(const std::wstring& path) {
    std::wstring name = NameOf(path);
    size_t i = name.find_last_of(L'.');
    return i == std::wstring::npos ? name : name.substr(0, i);
}

static std::wstring ExtOf(const std::wstring& path) {
    std::wstring name = NameOf(path);
    size_t i = name.find_last_of(L'.');
    return i == std::wstring::npos ? L"" : Lower(name.substr(i + 1));
}

static std::wstring Join(const std::wstring& a, const std::wstring& b) {
    if (a.empty()) return b;
    if (b.empty()) return a;
    if (a.back() == L'\\') return a + b;
    return a + L"\\" + b;
}

static bool IsDir(const std::wstring& path) {
    DWORD a = GetFileAttributesW(path.c_str());
    return a != INVALID_FILE_ATTRIBUTES && (a & FILE_ATTRIBUTE_DIRECTORY);
}

static bool FileExists(const std::wstring& path) {
    DWORD a = GetFileAttributesW(path.c_str());
    return a != INVALID_FILE_ATTRIBUTES && !(a & FILE_ATTRIBUTE_DIRECTORY);
}

static std::wstring TimeText(double seconds) {
    if (seconds <= 0) return L"—";
    int t = (int)(seconds + 0.5);
    wchar_t buf[32];
    if (t >= 3600) swprintf_s(buf, L"%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60);
    else           swprintf_s(buf, L"%d:%02d", t / 60, t % 60);
    return buf;
}

/// 认哪些后缀。宁可放宽——真打不开 ffprobe 会说话，
/// 在这儿卡掉反而让人以为程序漏了文件。
static bool IsVideoFile(const std::wstring& path) {
    static const wchar_t* kExts[] = {
        L"mp4", L"m4v", L"mov", L"qt", L"3gp", L"3g2",
        L"mkv", L"webm", L"avi", L"wmv", L"asf", L"flv", L"f4v",
        L"rm", L"rmvb", L"vob", L"mpg", L"mpeg", L"mpe", L"m2v", L"m2p",
        L"ts", L"mts", L"m2ts", L"mxf", L"dv", L"ogv", L"ogm",
        L"divx", L"xvid", L"amv"
    };
    std::wstring ext = ExtOf(path);
    for (const wchar_t* e : kExts) if (ext == e) return true;
    return false;
}

// ── 找 ffmpeg ────────────────────────────────────────────────────────

static std::wstring ExeDir() {
    wchar_t buf[MAX_PATH];
    GetModuleFileNameW(nullptr, buf, MAX_PATH);
    return DirOf(buf);
}

/// 先看自己旁边，再看 PATH。放旁边最省事：整个工具就是一个文件夹，
/// 拷到别的机器上也能用。
static std::wstring FindTool(const wchar_t* name) {
    std::wstring beside = Join(ExeDir(), name);
    if (FileExists(beside)) return beside;

    wchar_t found[MAX_PATH];
    if (SearchPathW(nullptr, name, nullptr, MAX_PATH, found, nullptr)) return found;
    return L"";
}

// ── 跑一个子进程，把它的输出一行行喂给回调 ───────────────────────────

/// onLine 返回 false 表示要求中断。
/// stdout 和 stderr 合并到同一个管道：进度和报错都要，分两个管道读起来更麻烦。
static bool RunCapture(const std::wstring& cmdline,
                       bool (*onLine)(const std::string&, void*),
                       void* ctx,
                       std::string* tail) {
    SECURITY_ATTRIBUTES sa{ sizeof(sa), nullptr, TRUE };
    HANDLE rd = nullptr, wr = nullptr;
    if (!CreatePipe(&rd, &wr, &sa, 0)) return false;
    SetHandleInformation(rd, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOW si{};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdOutput = wr;
    si.hStdError = wr;
    si.hStdInput = nullptr;

    PROCESS_INFORMATION pi{};
    std::wstring mutableCmd = cmdline;   // CreateProcessW 会改这块缓冲区
    BOOL ok = CreateProcessW(nullptr, &mutableCmd[0], nullptr, nullptr, TRUE,
                             CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi);
    CloseHandle(wr);
    if (!ok) { CloseHandle(rd); return false; }

    {
        std::lock_guard<std::mutex> guard(g_childLock);
        g_child = pi.hProcess;
    }

    std::string buffer, line;
    char chunk[4096];
    DWORD got = 0;
    bool aborted = false;

    while (ReadFile(rd, chunk, sizeof(chunk), &got, nullptr) && got > 0) {
        buffer.append(chunk, got);
        size_t start = 0;
        for (size_t i = 0; i < buffer.size(); ++i) {
            if (buffer[i] != '\n' && buffer[i] != '\r') continue;
            line.assign(buffer, start, i - start);
            start = i + 1;
            if (line.empty()) continue;
            if (tail) {
                // 只留最后几行，报错信息一般在末尾
                tail->append(line);
                tail->append("\n");
                if (tail->size() > 2000) tail->erase(0, tail->size() - 2000);
            }
            if (onLine && !onLine(line, ctx)) { aborted = true; break; }
        }
        buffer.erase(0, start);
        if (aborted) break;
    }

    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 1;
    GetExitCodeProcess(pi.hProcess, &code);

    {
        std::lock_guard<std::mutex> guard(g_childLock);
        g_child = nullptr;
    }
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    CloseHandle(rd);
    return !aborted && code == 0;
}

// ── 探测：这个文件里装的是什么 ───────────────────────────────────────

struct Probe {
    std::string vcodec, pixfmt, acodec;
    double duration = 0;
    bool hasVideo = false, hasAudio = false;
};

struct ProbeParser {
    Probe* out;
    std::string curType, curCodec, curPix;

    /// mkv 里内嵌的封面图也算一路 video 流，不能当成正片
    static bool IsCoverArt(const std::string& codec) {
        return codec == "mjpeg" || codec == "png" || codec == "bmp" || codec == "gif";
    }

    void flush() {
        if (curType == "video" && !out->hasVideo && !IsCoverArt(curCodec)) {
            out->hasVideo = true;
            out->vcodec = curCodec;
            out->pixfmt = curPix;
        } else if (curType == "audio" && !out->hasAudio) {
            out->hasAudio = true;
            out->acodec = curCodec;
        }
        curType.clear(); curCodec.clear(); curPix.clear();
    }
};

static bool ProbeLine(const std::string& line, void* ctx) {
    auto* p = (ProbeParser*)ctx;
    size_t eq = line.find('=');
    if (eq == std::string::npos) return true;
    std::string key = line.substr(0, eq), value = line.substr(eq + 1);

    // index= 是每个流的第一行，遇到就把上一个流收了
    if (key == "index") { p->flush(); return true; }
    if (key == "codec_type") p->curType = value;
    else if (key == "codec_name") p->curCodec = value;
    else if (key == "pix_fmt") p->curPix = value;
    else if (key == "duration") {
        p->flush();
        p->out->duration = atof(value.c_str());
    }
    return true;
}

static bool ProbeFile(const std::wstring& path, Probe* out) {
    std::wstring cmd = L"\"" + g_ffprobe + L"\" -v error"
        L" -show_entries stream=index,codec_type,codec_name,pix_fmt:format=duration"
        L" -of default=nw=1 \"" + path + L"\"";
    ProbeParser parser{ out };
    bool ok = RunCapture(cmd, ProbeLine, &parser, nullptr);
    parser.flush();
    return ok && out->hasVideo;
}

// ── 决定怎么转 ───────────────────────────────────────────────────────

/// 一律重新编码，不做「只换壳」这条快路。
///
/// 换壳的诱惑很大：编码本身合规的话几秒钟就好，画质零损失。但判断「合规」
/// 只能靠 ffprobe 报的编码名和像素格式，而这两样说明不了时间戳是不是好的：
///
/// - AVI 压根不存每帧的显示时间，换壳出来的 mp4 里 DTS 非单调递增
/// - 网上流传的片子常被人硬套成 .mp4：容器换了，里面的时间戳还是坏的，
///   ffprobe 照样报 h264 + yuv420p，看不出任何毛病
///
/// 这两种情况 ffmpeg 都退出码 0，Windows 播放器也多半能凑合放，
/// 只有 iOS 的解码器严格，拿到没有正确显示时间的帧就是不放——
/// 也就是说，快路省下的那点时间，代价是「转完了但手机上放不了」，
/// 而且要装到手机上才发现。不值。
///
/// 重新编码的输出是 ffmpeg 自己排的时间戳，一定干净。
static std::wstring PlanLabel(const Probe& p, const QualityLevel& level) {
    std::wstring codec = Widen(p.vcodec);
    return std::wstring(level.label) + L"  ·  " + (codec.empty() ? L"?" : codec);
}

// ── 转换 ─────────────────────────────────────────────────────────────

/// ffmpeg 抱怨过时间戳没有？
///
/// 这几句都出现在换壳的时候：源容器没存每帧的显示时间，ffmpeg 只能按包的
/// 顺序凑，遇到 B 帧就凑错。它自己退出码还是 0，写出来的 mp4 里 DTS 非单调，
/// iOS 拿到这种文件直接不放。
static bool HasTimestampTrouble(const std::string& log) {
    static const char* kMarkers[] = {
        "Timestamps are unset",
        "pts has no value",
        "non monotonically increasing",
        "Non-monotonic DTS"
    };
    for (const char* marker : kMarkers) {
        if (log.find(marker) != std::string::npos) return true;
    }
    return false;
}

struct ConvertCtx {
    size_t index;
    double duration;
};

static bool ConvertLine(const std::string& line, void* ctx) {
    if (g_cancel) return false;
    auto* c = (ConvertCtx*)ctx;

    // ffmpeg -progress 输出的是 key=value。out_time_us 是微秒；
    // 老版本只有 out_time_ms，但它给的其实也是微秒（ffmpeg 的历史遗留）。
    long long us = -1;
    if (line.compare(0, 12, "out_time_us=") == 0) us = _atoi64(line.c_str() + 12);
    else if (line.compare(0, 12, "out_time_ms=") == 0) us = _atoi64(line.c_str() + 12);
    if (us < 0) return true;

    int percent = 0;
    if (c->duration > 0.01) {
        percent = (int)((us / 1e6) / c->duration * 100.0);
        percent = max(0, min(99, percent));   // 100% 留给真正结束
    }

    std::lock_guard<std::mutex> guard(g_lock);
    if (c->index < g_items.size() && g_items[c->index].percent != percent) {
        g_items[c->index].percent = percent;
        PostMessageW(g_main, MSG_ITEM, (WPARAM)c->index, 0);
    }
    return true;
}

/// 界面上选的是哪一档。工作线程会读它，所以只读控件、不改。
static int CurrentQuality() {
    int i = (int)SendMessageW(g_quality, CB_GETCURSEL, 0, 0);
    if (i < 0 || i >= (int)(sizeof(kQuality) / sizeof(kQuality[0]))) return 0;
    return i;
}

static void SetStatus(size_t index, const std::wstring& text, int percent) {
    {
        std::lock_guard<std::mutex> guard(g_lock);
        if (index >= g_items.size()) return;
        g_items[index].status = text;
        g_items[index].percent = percent;
    }
    PostMessageW(g_main, MSG_ITEM, (WPARAM)index, 0);
}

static void ConvertOne(size_t index) {
    std::wstring src, relDir;
    {
        std::lock_guard<std::mutex> guard(g_lock);
        if (index >= g_items.size()) return;
        src = g_items[index].path;
        relDir = g_items[index].relDir;
    }

    SetStatus(index, L"读取信息…", -1);
    Probe probe;
    if (!ProbeFile(src, &probe)) {
        SetStatus(index, L"读不出视频流", -1);
        std::lock_guard<std::mutex> guard(g_lock);
        g_items[index].finished = true;
        return;
    }
    std::wstring label = PlanLabel(probe, kQuality[CurrentQuality()]);

    std::wstring dstDir = Join(g_outDir, relDir);
    SHCreateDirectoryExW(nullptr, dstDir.c_str(), nullptr);
    std::wstring dst = Join(dstDir, StemOf(src) + L".mp4");

    {
        std::lock_guard<std::mutex> guard(g_lock);
        g_items[index].plan = label;
    }

    // 已经转过就跳过，中途关掉再开能接着来，不用重头跑一遍
    if (SendMessageW(g_chkSkip, BM_GETCHECK, 0, 0) == BST_CHECKED && FileExists(dst)) {
        SetStatus(index, L"已存在，跳过", 100);
        std::lock_guard<std::mutex> guard(g_lock);
        g_items[index].finished = true;
        return;
    }

    // 源和目标同名同路径时先写到临时文件，免得把源文件截断
    bool inPlace = (Lower(dst) == Lower(src));
    std::wstring target = inPlace ? dst + L".tmp.mp4" : dst;

    const QualityLevel& level = kQuality[CurrentQuality()];
    std::wstring cmd = L"\"" + g_ffmpeg + L"\" -hide_banner -nostdin -y"
        L" -i \"" + src + L"\""
        // 只要第一路视频和第一路音频。mkv 里常带字幕流，mp4 装不下，
        // 不显式挑的话 ffmpeg 会直接报错退出。
        L" -map 0:V:0 -map 0:a:0? -sn -dn"
        L" -c:v libx264 -preset " + level.preset
        + L" -crf " + std::to_wstring(level.crf)
        + L" -pix_fmt yuv420p"
        L" -c:a aac -b:a 192k"
        // 时间戳全部重排。源文件的时间戳本来就可能是坏的（AVI 没有、
        // 被人硬套成 mp4 的也常是坏的），这里不继承，让 ffmpeg 重新排。
        L" -fps_mode cfr -reset_timestamps 1"
        // faststart 把索引挪到文件开头，边下边播和拖进度条才不用先读到尾
        L" -movflags +faststart -progress pipe:1 -nostats -loglevel warning"
        L" \"" + target + L"\"";

    SetStatus(index, label + L"…", 0);

    ConvertCtx ctx{ index, probe.duration };
    std::string tail;
    bool ok = RunCapture(cmd, ConvertLine, &ctx, &tail);

    if (g_cancel) {
        DeleteFileW(target.c_str());
        SetStatus(index, L"已取消", -1);
        return;
    }

    // 重新编码之后还抱怨时间戳，说明源文件坏得更深，不是换壳能解释的。
    // 转出来的文件多半在手机上放不了，明说，别报「完成」让人白装一遍。
    if (ok && HasTimestampTrouble(tail)) {
        SetStatus(index, L"完成，但时间戳有告警，手机上可能放不了", 100);
        std::lock_guard<std::mutex> guard(g_lock);
        if (index < g_items.size()) g_items[index].finished = true;
        return;
    }

    if (ok && inPlace) {
        DeleteFileW(dst.c_str());
        ok = MoveFileW(target.c_str(), dst.c_str()) != 0;
    }

    if (ok) {
        SetStatus(index, L"完成", 100);
    } else {
        DeleteFileW(target.c_str());
        // 报错信息一般在最后一行
        std::string last = tail;
        size_t cut = last.find_last_not_of("\r\n");
        if (cut != std::string::npos) last.erase(cut + 1);
        cut = last.find_last_of('\n');
        if (cut != std::string::npos) last = last.substr(cut + 1);
        SetStatus(index, last.empty() ? L"失败" : L"失败：" + Widen(last), -1);
    }

    std::lock_guard<std::mutex> guard(g_lock);
    if (index < g_items.size()) g_items[index].finished = true;
}

static DWORD WINAPI WorkerThread(LPVOID) {
    // 转一大批片子要跑很久，别让电脑睡过去。
    // 只挡休眠不挡息屏——屏幕该黑还是让它黑。
    SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED);

    for (size_t i = 0; ; ++i) {
        if (g_cancel) break;
        {
            std::lock_guard<std::mutex> guard(g_lock);
            if (i >= g_items.size()) break;
            if (g_items[i].finished) continue;
        }
        ConvertOne(i);
    }

    SetThreadExecutionState(ES_CONTINUOUS);
    g_running = false;
    PostMessageW(g_main, MSG_DONE, 0, 0);
    return 0;
}

// ── 往列表里加文件 ───────────────────────────────────────────────────

static void AddOne(const std::wstring& path, const std::wstring& relDir) {
    std::lock_guard<std::mutex> guard(g_lock);
    for (const Item& it : g_items) {
        if (Lower(it.path) == Lower(path)) return;   // 重复的不再加一遍
    }
    Item item;
    item.path = path;
    item.relDir = relDir;
    item.name = NameOf(path);
    item.status = L"等待";
    g_items.push_back(item);
}

/// 递归扫一个文件夹。relDir 是相对最初那个文件夹的路径，
/// 转出来的文件按同样的层级摆好——App 那边正是按目录层级分组的。
static void AddFolder(const std::wstring& dir, const std::wstring& relDir) {
    std::wstring pattern = Join(dir, L"*");
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW(pattern.c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return;

    do {
        std::wstring name = fd.cFileName;
        if (name == L"." || name == L"..") continue;
        std::wstring full = Join(dir, name);
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
            AddFolder(full, Join(relDir, name));
        } else if (IsVideoFile(full)) {
            AddOne(full, relDir);
        }
    } while (FindNextFileW(h, &fd));
    FindClose(h);
}

static void RefreshList() {
    size_t count;
    {
        std::lock_guard<std::mutex> guard(g_lock);
        count = g_items.size();
    }
    ListView_SetItemCountEx(g_list, (int)count, LVSICF_NOSCROLL);
    InvalidateRect(g_list, nullptr, FALSE);

    wchar_t buf[128];
    swprintf_s(buf, L"共 %zu 个文件", count);
    SetWindowTextW(g_status, buf);
}

// ── 对话框 ───────────────────────────────────────────────────────────

static void PickFiles() {
    // 一次能选几百个，缓冲区给足
    std::vector<wchar_t> buf(1 << 16, 0);
    OPENFILENAMEW ofn{};
    ofn.lStructSize = sizeof(ofn);
    ofn.hwndOwner = g_main;
    ofn.lpstrFilter = L"视频文件\0*.mp4;*.m4v;*.mov;*.mkv;*.webm;*.avi;*.wmv;*.asf;"
                      L"*.flv;*.f4v;*.rm;*.rmvb;*.vob;*.mpg;*.mpeg;*.ts;*.mts;*.m2ts;"
                      L"*.3gp;*.divx;*.xvid;*.ogv\0所有文件\0*.*\0\0";
    ofn.lpstrFile = buf.data();
    ofn.nMaxFile = (DWORD)buf.size();
    ofn.Flags = OFN_ALLOWMULTISELECT | OFN_EXPLORER | OFN_FILEMUSTEXIST | OFN_NOCHANGEDIR;
    if (!GetOpenFileNameW(&ofn)) return;

    // 多选时格式是：目录\0文件1\0文件2\0\0；单选时就是一个完整路径
    std::wstring dir = buf.data();
    wchar_t* p = buf.data() + dir.size() + 1;
    if (*p == L'\0') {
        AddOne(dir, L"");
    } else {
        while (*p) {
            AddOne(Join(dir, p), L"");
            p += wcslen(p) + 1;
        }
    }
    RefreshList();
}

static std::wstring PickFolder(const wchar_t* title) {
    BROWSEINFOW bi{};
    bi.hwndOwner = g_main;
    bi.lpszTitle = title;
    bi.ulFlags = BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE;
    LPITEMIDLIST idl = SHBrowseForFolderW(&bi);
    if (!idl) return L"";

    wchar_t path[MAX_PATH] = L"";
    SHGetPathFromIDListW(idl, path);
    CoTaskMemFree(idl);
    return path;
}

// ── 界面 ─────────────────────────────────────────────────────────────

static void Layout(HWND hwnd) {
    RECT rc;
    GetClientRect(hwnd, &rc);
    const int W = rc.right, H = rc.bottom;
    const int pad = 12, row = 30, gap = 8;

    int x = pad, y = pad;
    auto place = [&](HWND h, int w) {
        MoveWindow(h, x, y, w, row, TRUE);
        x += w + gap;
    };
    place(g_btnAddFiles, 96);
    place(g_btnAddFolder, 108);
    place(g_btnRemove, 84);
    place(g_btnClear, 72);

    MoveWindow(GetDlgItem(hwnd, ID_QUALITY_LABEL), W - pad - 150 - gap - 48, y + 5, 48, 22, TRUE);
    // 下拉框的高度是展开后的总高，不是关着的那一条
    MoveWindow(g_quality, W - pad - 150, y, 150, row + 120, TRUE);

    // 第二行：输出目录
    y += row + gap;
    x = pad;
    MoveWindow(g_outEdit, x, y, W - pad * 2 - 88 - gap, row, TRUE);
    MoveWindow(g_btnOutPick, W - pad - 88, y, 88, row, TRUE);

    // 中间：列表占满剩下的高度
    y += row + gap;
    int bottom = H - pad - row - gap - row - gap;
    MoveWindow(g_list, pad, y, W - pad * 2, max(60, bottom - y), TRUE);

    // 倒数第二行：进度条 + 状态
    y = H - pad - row * 2 - gap * 2;
    MoveWindow(g_progress, pad, y, W - pad * 2, 16, TRUE);
    y += 16 + 6;
    MoveWindow(g_status, pad, y, W - pad * 2 - 200, row, TRUE);

    // 最后一行：勾选 + 开始/停止
    y = H - pad - row;
    MoveWindow(g_chkSkip, pad, y + 4, 180, 22, TRUE);
    MoveWindow(g_btnStart, W - pad - 96 - gap - 96, y, 96, row, TRUE);
    MoveWindow(g_btnStop, W - pad - 96, y, 96, row, TRUE);
}

static void UpdateButtons() {
    BOOL idle = g_running ? FALSE : TRUE;
    EnableWindow(g_btnStart, idle);
    EnableWindow(g_btnStop, !idle);
    EnableWindow(g_btnAddFiles, idle);
    EnableWindow(g_btnAddFolder, idle);
    EnableWindow(g_btnRemove, idle);
    EnableWindow(g_btnClear, idle);
    EnableWindow(g_btnOutPick, idle);
    EnableWindow(g_quality, idle);
}

static void StartQueue() {
    if (g_running) return;
    if (g_ffmpeg.empty()) {
        MessageBoxW(g_main,
            L"没找到 ffmpeg.exe。\n\n"
            L"从 ffmpeg 官网下载 Windows 版，把 ffmpeg.exe 和 ffprobe.exe "
            L"放到本程序旁边就行。",
            L"缺少 ffmpeg", MB_ICONWARNING);
        return;
    }
    {
        std::lock_guard<std::mutex> guard(g_lock);
        if (g_items.empty()) return;
        // 重新开始时把上一轮的失败项也重跑
        for (Item& it : g_items) {
            if (it.percent != 100) { it.finished = false; it.status = L"等待"; it.percent = -1; }
        }
    }
    wchar_t buf[MAX_PATH];
    GetWindowTextW(g_outEdit, buf, MAX_PATH);
    g_outDir = buf;
    if (g_outDir.empty()) {
        MessageBoxW(g_main, L"先选一个输出目录。", L"提示", MB_ICONINFORMATION);
        return;
    }
    SHCreateDirectoryExW(nullptr, g_outDir.c_str(), nullptr);

    g_cancel = false;
    g_running = true;
    UpdateButtons();
    RefreshList();
    CloseHandle(CreateThread(nullptr, 0, WorkerThread, nullptr, 0, nullptr));
}

static void StopQueue() {
    g_cancel = true;
    std::lock_guard<std::mutex> guard(g_childLock);
    if (g_child) TerminateProcess(g_child, 1);
}

static void OnDrop(HDROP drop) {
    UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
    for (UINT i = 0; i < count; ++i) {
        wchar_t path[MAX_PATH];
        DragQueryFileW(drop, i, path, MAX_PATH);
        if (IsDir(path)) {
            AddFolder(path, NameOf(path));   // 拖进来的文件夹本身也算一层
        } else if (IsVideoFile(path)) {
            AddOne(path, L"");
        }
    }
    DragFinish(drop);
    RefreshList();
}

static void FillListItem(NMLVDISPINFOW* info) {
    LVITEMW& item = info->item;
    std::lock_guard<std::mutex> guard(g_lock);
    if (item.iItem < 0 || (size_t)item.iItem >= g_items.size()) return;
    const Item& it = g_items[item.iItem];
    if (!(item.mask & LVIF_TEXT)) return;

    static wchar_t buf[512];
    switch (item.iSubItem) {
    case 0: wcscpy_s(buf, it.name.c_str()); break;
    case 1: wcscpy_s(buf, it.relDir.empty() ? L"—" : it.relDir.c_str()); break;
    case 2: wcscpy_s(buf, it.plan.empty() ? L"—" : it.plan.c_str()); break;
    case 3:
        if (it.percent >= 0 && it.percent < 100) swprintf_s(buf, L"%d%%  %s", it.percent, it.status.c_str());
        else wcscpy_s(buf, it.status.c_str());
        break;
    default: buf[0] = 0;
    }
    item.pszText = buf;
}

static void OnItemUpdated(size_t index) {
    ListView_RedrawItems(g_list, (int)index, (int)index);

    size_t total = 0, done = 0;
    int percent = 0;
    std::wstring current;
    {
        std::lock_guard<std::mutex> guard(g_lock);
        total = g_items.size();
        for (const Item& it : g_items) if (it.finished) ++done;
        if (index < g_items.size()) {
            percent = max(0, g_items[index].percent);
            current = g_items[index].name;
        }
    }
    SendMessageW(g_progress, PBM_SETPOS, percent, 0);

    wchar_t buf[512];
    swprintf_s(buf, L"%zu / %zu   正在处理：%s", done + (g_running ? 1 : 0), total, current.c_str());
    SetWindowTextW(g_status, buf);
}

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_CREATE: {
        g_main = hwnd;

        NONCLIENTMETRICSW ncm{ sizeof(ncm) };
        SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof(ncm), &ncm, 0);
        g_font = CreateFontIndirectW(&ncm.lfMessageFont);

        auto button = [&](const wchar_t* text, int id) {
            HWND h = CreateWindowExW(0, L"BUTTON", text,
                WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
                0, 0, 0, 0, hwnd, (HMENU)(INT_PTR)id, nullptr, nullptr);
            SendMessageW(h, WM_SETFONT, (WPARAM)g_font, TRUE);
            return h;
        };

        g_btnAddFiles = button(L"添加文件", ID_ADD_FILES);
        g_btnAddFolder = button(L"添加文件夹", ID_ADD_FOLDER);
        g_btnRemove = button(L"移除选中", ID_REMOVE);
        g_btnClear = button(L"清空", ID_CLEAR);
        g_btnOutPick = button(L"输出目录…", ID_OUT_PICK);
        g_btnStart = button(L"开始", ID_START);
        g_btnStop = button(L"停止", ID_STOP);

        g_outEdit = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"",
            WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL | ES_READONLY,
            0, 0, 0, 0, hwnd, (HMENU)ID_OUT_EDIT, nullptr, nullptr);
        SendMessageW(g_outEdit, WM_SETFONT, (WPARAM)g_font, TRUE);

        HWND qlabel = CreateWindowExW(0, L"STATIC", L"画质：",
            WS_CHILD | WS_VISIBLE | SS_RIGHT, 0, 0, 0, 0, hwnd,
            (HMENU)ID_QUALITY_LABEL, nullptr, nullptr);
        SendMessageW(qlabel, WM_SETFONT, (WPARAM)g_font, TRUE);

        g_quality = CreateWindowExW(0, L"COMBOBOX", nullptr,
            WS_CHILD | WS_VISIBLE | CBS_DROPDOWNLIST | WS_VSCROLL,
            0, 0, 0, 0, hwnd, (HMENU)ID_QUALITY, nullptr, nullptr);
        SendMessageW(g_quality, WM_SETFONT, (WPARAM)g_font, TRUE);
        for (const QualityLevel& q : kQuality) {
            SendMessageW(g_quality, CB_ADDSTRING, 0, (LPARAM)q.label);
        }
        SendMessageW(g_quality, CB_SETCURSEL, 0, 0);

        g_chkSkip = CreateWindowExW(0, L"BUTTON", L"跳过已经转好的",
            WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX,
            0, 0, 0, 0, hwnd, (HMENU)ID_SKIP_EXISTING, nullptr, nullptr);
        SendMessageW(g_chkSkip, WM_SETFONT, (WPARAM)g_font, TRUE);
        SendMessageW(g_chkSkip, BM_SETCHECK, BST_CHECKED, 0);

        g_progress = CreateWindowExW(0, PROGRESS_CLASSW, nullptr,
            WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, hwnd, (HMENU)ID_PROGRESS, nullptr, nullptr);
        SendMessageW(g_progress, PBM_SETRANGE32, 0, 100);

        g_status = CreateWindowExW(0, L"STATIC", L"把视频或文件夹直接拖进来",
            WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, hwnd, (HMENU)ID_STATUS, nullptr, nullptr);
        SendMessageW(g_status, WM_SETFONT, (WPARAM)g_font, TRUE);

        // 虚拟列表：几千个文件也不用往控件里塞几千份字符串
        g_list = CreateWindowExW(WS_EX_CLIENTEDGE, WC_LISTVIEWW, nullptr,
            WS_CHILD | WS_VISIBLE | LVS_REPORT | LVS_OWNERDATA | LVS_SHOWSELALWAYS,
            0, 0, 0, 0, hwnd, (HMENU)ID_LIST, nullptr, nullptr);
        SendMessageW(g_list, WM_SETFONT, (WPARAM)g_font, TRUE);
        ListView_SetExtendedListViewStyle(g_list, LVS_EX_FULLROWSELECT | LVS_EX_DOUBLEBUFFER);

        const wchar_t* cols[] = { L"文件", L"子目录", L"处理方式", L"状态" };
        const int widths[] = { 380, 160, 130, 220 };
        for (int i = 0; i < 4; ++i) {
            LVCOLUMNW col{};
            col.mask = LVCF_TEXT | LVCF_WIDTH;
            col.pszText = (LPWSTR)cols[i];
            col.cx = widths[i];
            ListView_InsertColumn(g_list, i, &col);
        }

        DragAcceptFiles(hwnd, TRUE);
        UpdateButtons();
        return 0;
    }

    case WM_SIZE:
        Layout(hwnd);
        return 0;

    case WM_GETMINMAXINFO:
        ((MINMAXINFO*)lp)->ptMinTrackSize = { 720, 460 };
        return 0;

    case WM_DROPFILES:
        if (!g_running) OnDrop((HDROP)wp);
        else DragFinish((HDROP)wp);
        return 0;

    case WM_NOTIFY: {
        auto* nm = (NMHDR*)lp;
        if (nm->idFrom == ID_LIST && nm->code == LVN_GETDISPINFOW) {
            FillListItem((NMLVDISPINFOW*)lp);
        }
        return 0;
    }

    case MSG_ITEM:
        OnItemUpdated((size_t)wp);
        return 0;

    case MSG_DONE: {
        UpdateButtons();
        SendMessageW(g_progress, PBM_SETPOS, 0, 0);

        size_t ok = 0, bad = 0;
        {
            std::lock_guard<std::mutex> guard(g_lock);
            for (const Item& it : g_items) {
                if (it.percent == 100) ++ok; else if (it.finished) ++bad;
            }
        }
        wchar_t buf[256];
        swprintf_s(buf, L"全部结束：成功 %zu，失败 %zu", ok, bad);
        SetWindowTextW(g_status, buf);

        // 跑完可能已经过了很久，闪一下任务栏，不用一直守着
        FLASHWINFO fi{ sizeof(fi), hwnd, FLASHW_TRAY | FLASHW_TIMERNOFG, 3, 0 };
        FlashWindowEx(&fi);
        return 0;
    }

    case WM_COMMAND:
        switch (LOWORD(wp)) {
        case ID_ADD_FILES:
            PickFiles();
            return 0;
        case ID_ADD_FOLDER: {
            std::wstring dir = PickFolder(L"选择要转换的文件夹");
            if (!dir.empty()) { AddFolder(dir, NameOf(dir)); RefreshList(); }
            return 0;
        }
        case ID_REMOVE: {
            std::vector<int> rows;
            int i = -1;
            while ((i = ListView_GetNextItem(g_list, i, LVNI_SELECTED)) != -1) rows.push_back(i);
            {
                std::lock_guard<std::mutex> guard(g_lock);
                for (auto it = rows.rbegin(); it != rows.rend(); ++it) {
                    if ((size_t)*it < g_items.size()) g_items.erase(g_items.begin() + *it);
                }
            }
            RefreshList();
            return 0;
        }
        case ID_CLEAR: {
            {
                std::lock_guard<std::mutex> guard(g_lock);
                g_items.clear();
            }
            RefreshList();
            return 0;
        }
        case ID_OUT_PICK: {
            std::wstring dir = PickFolder(L"转好的文件放到哪里");
            if (!dir.empty()) SetWindowTextW(g_outEdit, dir.c_str());
            return 0;
        }
        case ID_START:
            StartQueue();
            return 0;
        case ID_STOP:
            StopQueue();
            return 0;
        }
        return 0;

    case WM_CLOSE:
        if (g_running) {
            if (MessageBoxW(hwnd, L"还在转换中，确定要退出吗？", L"转片",
                            MB_OKCANCEL | MB_ICONQUESTION) != IDOK) return 0;
            StopQueue();
        }
        DestroyWindow(hwnd);
        return 0;

    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

/// 命令行上带的文件和文件夹直接入队。
/// 这样在资源管理器里选中一堆视频拖到 exe 图标上、或者用「发送到」，
/// 都能一次全丢进来，不用开程序再拖一遍。
static void AddFromCommandLine() {
    int count = 0;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &count);
    if (!argv) return;
    for (int i = 1; i < count; ++i) {   // argv[0] 是程序自己
        std::wstring path = argv[i];
        if (IsDir(path)) AddFolder(path, NameOf(path));
        else if (IsVideoFile(path)) AddOne(path, L"");
    }
    LocalFree(argv);
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE, PWSTR, int show) {
    SetProcessDPIAware();
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

    INITCOMMONCONTROLSEX icc{ sizeof(icc), ICC_LISTVIEW_CLASSES | ICC_PROGRESS_CLASS
                                           | ICC_STANDARD_CLASSES };
    InitCommonControlsEx(&icc);

    g_ffmpeg = FindTool(L"ffmpeg.exe");
    g_ffprobe = FindTool(L"ffprobe.exe");

    WNDCLASSEXW wc{ sizeof(wc) };
    wc.lpfnWndProc = WndProc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
    wc.lpszClassName = L"VideoConvertWindow";
    wc.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
    RegisterClassExW(&wc);

    HWND hwnd = CreateWindowExW(WS_EX_ACCEPTFILES, wc.lpszClassName,
        L"转片 —— 转成手机能直接播的 mp4",
        WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 960, 600,
        nullptr, nullptr, inst, nullptr);
    if (!hwnd) return 1;

    // 默认放在「视频\手机视频」，省得每次都选
    wchar_t videos[MAX_PATH] = L"";
    if (SUCCEEDED(SHGetFolderPathW(nullptr, CSIDL_MYVIDEO, nullptr, 0, videos))) {
        SetWindowTextW(g_outEdit, Join(videos, L"手机视频").c_str());
    }

    AddFromCommandLine();
    RefreshList();

    if (g_ffmpeg.empty() || g_ffprobe.empty()) {
        SetWindowTextW(g_status,
            L"没找到 ffmpeg.exe / ffprobe.exe —— 放到本程序旁边即可");
    }

    ShowWindow(hwnd, show);
    UpdateWindow(hwnd);

    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    CoUninitialize();
    return 0;
}
