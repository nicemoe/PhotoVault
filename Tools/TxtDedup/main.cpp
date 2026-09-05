// 查重 —— 一堆小说 txt 里把重复的挑出来。
//
// 纯 Win32，只用系统自带的 comctl32 / shell32 / bcrypt，没有第三方依赖。
//
// 同一本书往往存了好几份：文件名不一样、编码不一样（UTF-8 / GBK / UTF-16）、
// 有的是下到一半的截断版、有的正文里夹了广告页。光比 MD5 只能抓到字节完全
// 相同的那一种，所以这里从严到松叠了五层判据，见 Compare()。
//
// 中文没有空格，「分词」不靠词典，用字符二元组（bigram）算 Jaccard 相似度——
// 对中文这是最省事又够用的做法，也不会因为词典缺词而漏判。

#include <windows.h>
#include <commctrl.h>
#include <shlobj.h>
#include <shellapi.h>
#include <bcrypt.h>
#include <string>
#include <vector>
#include <unordered_map>
#include <unordered_set>
#include <algorithm>
#include <mutex>

#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "comctl32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "comdlg32.lib")
#pragma comment(lib, "bcrypt.lib")

#pragma comment(linker, "\"/manifestdependency:type='win32' \
name='Microsoft.Windows.Common-Controls' version='6.0.0.0' \
processorArchitecture='amd64' publicKeyToken='6595b64144ccf1df' language='*'\"")

// ── 控件 ID ──────────────────────────────────────────────────────────
enum {
    ID_LIST = 1001,
    ID_ADD_FOLDER, ID_CLEAR,
    ID_SCAN, ID_STOP,
    ID_CHECK_ALL, ID_UNCHECK_ALL,
    ID_MOVE, ID_RECYCLE, ID_EXPORT,
    ID_STATUS, ID_PROGRESS,
    ID_SIM_LABEL, ID_SIM_EDIT
};

enum {
    MSG_PROGRESS = WM_APP + 1,   // wParam = 已处理，lParam = 总数
    MSG_SCANNED  = WM_APP + 2    // 扫描线程干完了
};

// ── 一个文件 ─────────────────────────────────────────────────────────
struct Doc {
    std::wstring path;
    std::wstring name;          // 带后缀的文件名
    std::wstring rel;           // 相对扫描根的路径，移动时保留结构
    unsigned long long bytes = 0;

    std::string md5raw;         // 原始字节
    std::string md5norm;        // 归一化正文
    std::string md5head;        // 归一化正文的前 HEAD_CHARS 个字
    unsigned long long simhash = 0;
    size_t chars = 0;           // 归一化后的字数

    std::wstring title;         // 文件名去掉修饰后的书名
    std::vector<unsigned long long> titleGrams;  // 书名的字符二元组，排好序
    bool ok = false;

    // 分组结果
    int group = -1;
    bool keep = false;
    std::wstring reason;
};

static const size_t HEAD_CHARS = 5000;   // 「截断版」判据取多长的开头

// ── 全局状态 ─────────────────────────────────────────────────────────
static HWND g_main, g_list, g_status, g_progress, g_simEdit;
static HWND g_btnAdd, g_btnClear, g_btnScan, g_btnStop,
            g_btnCheckAll, g_btnUncheckAll, g_btnMove, g_btnRecycle, g_btnExport;
static HFONT g_font;

static std::vector<std::wstring> g_roots;       // 要扫的文件夹
static std::vector<Doc> g_docs;                 // 扫到的全部文件
static std::vector<int> g_rows;                 // 列表里显示的是 g_docs 的哪些下标
static std::mutex g_lock;

static volatile bool g_scanning = false;
static volatile bool g_cancel = false;

// ── 小工具 ───────────────────────────────────────────────────────────

static std::wstring DirOf(const std::wstring& p) {
    size_t i = p.find_last_of(L"\\/");
    return i == std::wstring::npos ? L"" : p.substr(0, i);
}

static std::wstring NameOf(const std::wstring& p) {
    size_t i = p.find_last_of(L"\\/");
    return i == std::wstring::npos ? p : p.substr(i + 1);
}

static std::wstring Join(const std::wstring& a, const std::wstring& b) {
    if (a.empty()) return b;
    if (b.empty()) return a;
    if (a.back() == L'\\') return a + b;
    return a + L"\\" + b;
}

static bool IsDir(const std::wstring& p) {
    DWORD a = GetFileAttributesW(p.c_str());
    return a != INVALID_FILE_ATTRIBUTES && (a & FILE_ATTRIBUTE_DIRECTORY);
}

static std::wstring SizeText(unsigned long long bytes) {
    wchar_t buf[64];
    if (bytes >= 1024ull * 1024) swprintf_s(buf, L"%.1f MB", bytes / 1048576.0);
    else if (bytes >= 1024) swprintf_s(buf, L"%.0f KB", bytes / 1024.0);
    else swprintf_s(buf, L"%llu B", bytes);
    return buf;
}

// ── MD5：用系统的 bcrypt，不自己实现 ─────────────────────────────────

static std::string MD5Hex(const void* data, size_t len) {
    BCRYPT_ALG_HANDLE alg = nullptr;
    if (BCryptOpenAlgorithmProvider(&alg, BCRYPT_MD5_ALGORITHM, nullptr, 0) != 0) return "";

    BCRYPT_HASH_HANDLE hash = nullptr;
    unsigned char digest[16] = {};
    std::string hex;

    if (BCryptCreateHash(alg, &hash, nullptr, 0, nullptr, 0, 0) == 0) {
        // 大文件分块喂，一次性传几百 MB 没必要
        const unsigned char* p = (const unsigned char*)data;
        size_t left = len;
        while (left > 0) {
            ULONG chunk = (ULONG)min(left, (size_t)(4 * 1024 * 1024));
            BCryptHashData(hash, (PUCHAR)p, chunk, 0);
            p += chunk;
            left -= chunk;
        }
        if (BCryptFinishHash(hash, digest, sizeof(digest), 0) == 0) {
            static const char* kHex = "0123456789abcdef";
            hex.reserve(32);
            for (unsigned char b : digest) {
                hex.push_back(kHex[b >> 4]);
                hex.push_back(kHex[b & 0xF]);
            }
        }
        BCryptDestroyHash(hash);
    }
    BCryptCloseAlgorithmProvider(alg, 0);
    return hex;
}

// ── 读文件 + 猜编码 ──────────────────────────────────────────────────

static bool ReadAll(const std::wstring& path, std::string* out) {
    HANDLE h = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                           OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;

    LARGE_INTEGER size{};
    GetFileSizeEx(h, &size);
    // 单个 txt 超过 200MB 基本不是小说，跳过免得把内存吃光
    if (size.QuadPart <= 0 || size.QuadPart > 200ll * 1024 * 1024) {
        CloseHandle(h);
        return false;
    }

    out->resize((size_t)size.QuadPart);
    size_t done = 0;
    while (done < out->size()) {
        DWORD got = 0;
        DWORD want = (DWORD)min(out->size() - done, (size_t)(8 * 1024 * 1024));
        if (!ReadFile(h, &(*out)[done], want, &got, nullptr) || got == 0) break;
        done += got;
    }
    CloseHandle(h);
    out->resize(done);
    return done > 0;
}

/// 小说来源杂，UTF-8、GBK、UTF-16 都有。先看 BOM，再按 UTF-8 严格解，
/// 解不动就当 GB18030——国内下载的十有八九是这个。
static std::wstring Decode(const std::string& bytes) {
    if (bytes.size() >= 3 && (unsigned char)bytes[0] == 0xEF
        && (unsigned char)bytes[1] == 0xBB && (unsigned char)bytes[2] == 0xBF) {
        int n = MultiByteToWideChar(CP_UTF8, 0, bytes.data() + 3, (int)bytes.size() - 3, nullptr, 0);
        std::wstring out(n, L'\0');
        MultiByteToWideChar(CP_UTF8, 0, bytes.data() + 3, (int)bytes.size() - 3, &out[0], n);
        return out;
    }
    if (bytes.size() >= 2 && (unsigned char)bytes[0] == 0xFF && (unsigned char)bytes[1] == 0xFE) {
        return std::wstring((const wchar_t*)(bytes.data() + 2), (bytes.size() - 2) / 2);
    }
    if (bytes.size() >= 2 && (unsigned char)bytes[0] == 0xFE && (unsigned char)bytes[1] == 0xFF) {
        // 大端 UTF-16，翻个个儿
        std::wstring out((bytes.size() - 2) / 2, L'\0');
        for (size_t i = 0; i < out.size(); ++i) {
            out[i] = (wchar_t)(((unsigned char)bytes[2 + i * 2] << 8)
                               | (unsigned char)bytes[3 + i * 2]);
        }
        return out;
    }

    for (UINT cp : { (UINT)CP_UTF8, (UINT)54936 /* GB18030 */, (UINT)CP_ACP }) {
        DWORD flags = (cp == CP_UTF8) ? MB_ERR_INVALID_CHARS : 0;
        int n = MultiByteToWideChar(cp, flags, bytes.data(), (int)bytes.size(), nullptr, 0);
        if (n <= 0) continue;
        std::wstring out(n, L'\0');
        MultiByteToWideChar(cp, flags, bytes.data(), (int)bytes.size(), &out[0], n);
        return out;
    }
    return L"";
}

// ── 归一化 ───────────────────────────────────────────────────────────

static bool IsSpaceLike(wchar_t c) {
    return c == L' ' || c == L'\t' || c == L'\r' || c == L'\n'
        || c == L'　'      // 全角空格
        || c == L'﻿';     // 零宽不换行空格，很多 txt 头上有
}

/// 只去空白，不动标点。
///
/// 同一本书重新排版之后，换行位置、段首缩进、行尾空格全会变，但字还是
/// 那些字——去掉空白再比，才抓得住「只是排版不同」这种重复。
/// 标点保留：标点也是正文的一部分，去掉反而会把不同的书拉近。
static std::wstring Normalize(const std::wstring& text) {
    std::wstring out;
    out.reserve(text.size());
    for (wchar_t c : text) {
        if (!IsSpaceLike(c)) out.push_back(c);
    }
    return out;
}

static std::string ToUtf8(const std::wstring& s) {
    if (s.empty()) return "";
    int n = WideCharToMultiByte(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0, nullptr, nullptr);
    std::string out(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, s.data(), (int)s.size(), &out[0], n, nullptr, nullptr);
    return out;
}

// ── SimHash ──────────────────────────────────────────────────────────

static unsigned long long Fnv1a(const wchar_t* p, size_t n) {
    unsigned long long h = 1469598103934665603ull;
    for (size_t i = 0; i < n; ++i) {
        h ^= (unsigned long long)p[i];
        h *= 1099511628211ull;
    }
    return h;
}

/// 对中文用字符二元组当特征——不需要词典，也不会因为词典缺词漏判。
/// 每个二元组算一个 64 位散列，按位投票，最后取符号位组成指纹。
/// 两个文件指纹的汉明距离越小，正文越像。
static unsigned long long SimHash(const std::wstring& text) {
    if (text.size() < 2) return 0;
    int vote[64] = {};

    // 长文本抽样：几百万字全跑一遍没必要，隔几个字取一个二元组，
    // 统计意义上一样能反映内容
    size_t step = text.size() > 400000 ? text.size() / 400000 + 1 : 1;
    for (size_t i = 0; i + 1 < text.size(); i += step) {
        unsigned long long h = Fnv1a(&text[i], 2);
        for (int b = 0; b < 64; ++b) {
            vote[b] += (h >> b) & 1 ? 1 : -1;
        }
    }

    unsigned long long sig = 0;
    for (int b = 0; b < 64; ++b) {
        if (vote[b] > 0) sig |= (1ull << b);
    }
    return sig;
}

static int Hamming(unsigned long long a, unsigned long long b) {
    unsigned long long x = a ^ b;
    int n = 0;
    while (x) { x &= x - 1; ++n; }
    return n;
}

// ── 文件名归一化：这就是「分词」那一步 ───────────────────────────────

/// 括号里装的多半是修饰语：【完结】(全本)[精校]。
/// 但书名号《》里装的正是书名，所以它只脱壳、不丢内容。
static std::wstring StripBrackets(const std::wstring& s) {
    std::wstring out;
    int depth = 0;
    for (wchar_t c : s) {
        switch (c) {
        case L'[': case L'(': case L'（': case L'【': case L'〔': case L'{':
            ++depth; continue;
        case L']': case L')': case L'）': case L'】': case L'〕': case L'}':
            if (depth > 0) --depth;
            continue;
        case L'《': case L'》': case L'〈': case L'〉':
            continue;                    // 只脱壳，里面的书名留着
        default:
            if (depth == 0) out.push_back(c);
        }
    }
    return out;
}

static bool IsSeparator(wchar_t c) {
    return c == L'-' || c == L'_' || c == L'~' || c == L'+' || c == L'.'
        || c == L',' || c == L'，' || c == L'、' || c == L'；' || c == L';'
        || c == L'|' || c == L'/' || c == L'\\' || c == L'—' || c == L'　'
        || IsSpaceLike(c);
}

/// 这些词只是来源和状态标记，跟是不是同一本书无关，去掉。
/// 注意别去数字：《三体2》和《三体3》是两本书。
static const wchar_t* kNoise[] = {
    L"全本", L"完本", L"完结", L"已完结", L"未完", L"连载", L"精校", L"校对",
    L"精编", L"排版", L"修订", L"无错", L"未删减", L"删减", L"珍藏", L"典藏",
    L"下载", L"免费", L"最新", L"章节", L"全集", L"合集", L"文字版", L"电子书",
    L"小说", L"txt", L"TXT", L"epub", L"番茄", L"起点", L"纵横", L"新笔趣阁",
    L"笔趣阁", L"书包网", L"努努书坊", L"知轩藏书", L"精品", L"整理", L"版"
};

/// 文件名 → 用来比对的书名。
/// 顺序有讲究：先脱括号（连里面的修饰一起丢），再删噪声词，
/// 最后把分隔符和剩下的符号全抹掉。反过来的话，噪声词被符号切碎就匹配不上了。
static std::wstring TitleOf(const std::wstring& fileName) {
    // 去扩展名
    std::wstring s = fileName;
    size_t dot = s.find_last_of(L'.');
    if (dot != std::wstring::npos) s = s.substr(0, dot);

    s = StripBrackets(s);

    for (const wchar_t* noise : kNoise) {
        size_t at;
        while ((at = s.find(noise)) != std::wstring::npos) {
            s.erase(at, wcslen(noise));
        }
    }

    std::wstring out;
    for (wchar_t c : s) {
        if (IsSeparator(c)) continue;
        // 剩下的西文标点也一并抹掉，中文字和数字留着
        if (c < 128 && !iswalnum(c)) continue;
        out.push_back((wchar_t)towlower(c));
    }
    return out;
}

/// 书名切成字符二元组，去重排序。
/// 每个文件只算一次——放在两两比较里现算的话，几千个文件要建几百万次集合。
static std::vector<unsigned long long> TitleGrams(const std::wstring& s) {
    std::vector<unsigned long long> grams;
    if (s.size() < 2) return grams;
    grams.reserve(s.size());
    for (size_t i = 0; i + 1 < s.size(); ++i) grams.push_back(Fnv1a(&s[i], 2));
    std::sort(grams.begin(), grams.end());
    grams.erase(std::unique(grams.begin(), grams.end()), grams.end());
    return grams;
}

/// 两个书名的相似度：字符二元组的 Jaccard。两边都排好序，扫一遍就行。
/// 「斗破苍穹」和「斗破苍穹后传」交集 3、并集 5，算出来 0.6——
/// 低于阈值，正好不会把续作当成同一本。
static double TitleSimilarity(const std::vector<unsigned long long>& a,
                              const std::vector<unsigned long long>& b) {
    if (a.empty() || b.empty()) return 0;

    size_t i = 0, j = 0, inter = 0;
    while (i < a.size() && j < b.size()) {
        if (a[i] == b[j]) { ++inter; ++i; ++j; }
        else if (a[i] < b[j]) ++i;
        else ++j;
    }
    size_t uni = a.size() + b.size() - inter;
    return uni ? (double)inter / (double)uni : 0;
}

// ── 并查集 ───────────────────────────────────────────────────────────

struct DisjointSet {
    std::vector<int> parent;
    void reset(size_t n) {
        parent.resize(n);
        for (size_t i = 0; i < n; ++i) parent[i] = (int)i;
    }
    int find(int x) {
        while (parent[x] != x) { parent[x] = parent[parent[x]]; x = parent[x]; }
        return x;
    }
    void merge(int a, int b) {
        a = find(a); b = find(b);
        if (a != b) parent[b] = a;
    }
};

// ── 扫描 ─────────────────────────────────────────────────────────────

static void CollectFiles(const std::wstring& dir, const std::wstring& root,
                         std::vector<Doc>* out) {
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW(Join(dir, L"*").c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return;

    do {
        std::wstring name = fd.cFileName;
        if (name == L"." || name == L"..") continue;
        std::wstring full = Join(dir, name);

        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
            if (name == L"_重复") continue;    // 自己挪出去的那堆，别再扫回来
            CollectFiles(full, root, out);
            continue;
        }
        size_t dot = name.find_last_of(L'.');
        if (dot == std::wstring::npos) continue;
        std::wstring ext = name.substr(dot + 1);
        std::transform(ext.begin(), ext.end(), ext.begin(), ::towlower);
        if (ext != L"txt") continue;

        Doc doc;
        doc.path = full;
        doc.name = name;
        doc.rel = full.size() > root.size() + 1 ? full.substr(root.size() + 1) : name;
        LARGE_INTEGER sz;
        sz.LowPart = fd.nFileSizeLow;
        sz.HighPart = fd.nFileSizeHigh;
        doc.bytes = (unsigned long long)sz.QuadPart;
        out->push_back(doc);
    } while (FindNextFileW(h, &fd));
    FindClose(h);
}

static void Fingerprint(Doc* doc) {
    std::string bytes;
    if (!ReadAll(doc->path, &bytes)) return;

    doc->md5raw = MD5Hex(bytes.data(), bytes.size());

    std::wstring text = Normalize(Decode(bytes));
    doc->chars = text.size();
    if (text.empty()) { doc->ok = !doc->md5raw.empty(); return; }

    std::string utf8 = ToUtf8(text);
    doc->md5norm = MD5Hex(utf8.data(), utf8.size());

    // 开头指纹：一份下到一半、一份是全的，前面这段还是一模一样
    if (text.size() >= HEAD_CHARS) {
        std::string head = ToUtf8(text.substr(0, HEAD_CHARS));
        doc->md5head = MD5Hex(head.data(), head.size());
    }

    doc->simhash = SimHash(text);
    doc->ok = true;
}

/// 模糊判据：正文指纹接近、或者书名几乎一样。返回空串表示不是同一本。
///
/// 三种「完全相等」的判据（原始 MD5、归一化 MD5、开头 MD5）不走这里——
/// 那些用哈希表分桶是 O(n)，塞进两两比较白白多花 n² 次字符串比较。
static std::wstring CompareFuzzy(const Doc& a, const Doc& b, int maxHamming) {
    if (a.simhash && b.simhash) {
        int d = Hamming(a.simhash, b.simhash);
        if (d <= maxHamming) {
            // 长度差太多就不是「相似」，是两本不同的书恰好用词接近
            double ratio = (double)min(a.chars, b.chars) / (double)max(a.chars, b.chars);
            if (ratio > 0.5) {
                wchar_t buf[96];
                swprintf_s(buf, L"正文高度相似（差 %d 位）", d);
                return buf;
            }
        }
    }

    if (a.title.size() >= 3 && b.title.size() >= 3) {
        double sim = TitleSimilarity(a.titleGrams, b.titleGrams);
        if (sim >= 0.85) {
            wchar_t buf[96];
            swprintf_s(buf, L"书名相似 %.0f%%（正文未必相同）", sim * 100);
            return buf;
        }
    }
    return L"";
}

/// 一组里留哪一份：先要正文最全的，一样全就要文件名最干净的。
/// 「干净」= 原名和归一化书名的长度差最小，也就是修饰最少。
static bool BetterKeeper(const Doc& candidate, const Doc& current) {
    if (candidate.chars != current.chars) return candidate.chars > current.chars;
    if (candidate.bytes != current.bytes) return candidate.bytes > current.bytes;
    size_t noiseA = candidate.name.size() - min(candidate.name.size(), candidate.title.size());
    size_t noiseB = current.name.size() - min(current.name.size(), current.title.size());
    if (noiseA != noiseB) return noiseA < noiseB;
    return candidate.name < current.name;
}

static DWORD WINAPI ScanThread(LPVOID) {
    std::vector<std::wstring> roots;
    {
        std::lock_guard<std::mutex> guard(g_lock);
        roots = g_roots;
    }

    std::vector<Doc> docs;
    for (const std::wstring& root : roots) CollectFiles(root, root, &docs);

    // 同一个文件被两个根目录都扫到时去掉一份
    std::unordered_set<std::wstring> seen;
    std::vector<Doc> unique;
    for (Doc& d : docs) {
        std::wstring key = d.path;
        std::transform(key.begin(), key.end(), key.begin(), ::towlower);
        if (seen.insert(key).second) unique.push_back(std::move(d));
    }
    docs.swap(unique);

    PostMessageW(g_main, MSG_PROGRESS, 0, (LPARAM)docs.size());

    for (size_t i = 0; i < docs.size(); ++i) {
        if (g_cancel) break;
        docs[i].title = TitleOf(docs[i].name);
        docs[i].titleGrams = TitleGrams(docs[i].title);
        Fingerprint(&docs[i]);
        if ((i & 7) == 0 || i + 1 == docs.size()) {
            PostMessageW(g_main, MSG_PROGRESS, (WPARAM)(i + 1), (LPARAM)docs.size());
        }
    }

    int maxHamming = 3;
    {
        wchar_t buf[16] = L"";
        GetWindowTextW(g_simEdit, buf, 16);
        int v = _wtoi(buf);
        if (v >= 0 && v <= 16) maxHamming = v;
    }

    DisjointSet ds;
    ds.reset(docs.size());
    std::vector<std::wstring> reason(docs.size());

    // 第一轮：三种「完全相等」的判据用哈希表分桶，O(n)。
    // 从严到松依次来，先命中哪条就按哪条记依据。
    struct Bucket {
        const std::string Doc::* field;
        const wchar_t* why;
    };
    const Bucket kBuckets[] = {
        { &Doc::md5raw,  L"完全相同" },
        { &Doc::md5norm, L"正文相同（编码或排版不同）" },
        { &Doc::md5head, L"开头相同" },
    };
    for (const Bucket& bucket : kBuckets) {
        std::unordered_map<std::string, int> seenHash;
        for (size_t i = 0; i < docs.size() && !g_cancel; ++i) {
            if (!docs[i].ok) continue;
            const std::string& key = docs[i].*(bucket.field);
            if (key.empty()) continue;
            auto hit = seenHash.find(key);
            if (hit == seenHash.end()) { seenHash[key] = (int)i; continue; }

            int first = hit->second;
            if (ds.find(first) == ds.find((int)i)) continue;
            ds.merge(first, (int)i);
            if (reason[i].empty()) {
                // 开头一样但长度差一截，多半是一份没下完，说清楚差多少
                if (bucket.field == &Doc::md5head && docs[i].chars != docs[first].chars) {
                    double ratio = (double)min(docs[i].chars, docs[first].chars)
                                 / (double)max(docs[i].chars, docs[first].chars);
                    wchar_t buf[96];
                    swprintf_s(buf, L"开头相同，其中一份只有 %.0f%%", ratio * 100);
                    reason[i] = buf;
                } else {
                    reason[i] = bucket.why;
                }
            }
        }
    }

    // 第二轮：模糊判据只能两两比。几千个文件几百万次比较，
    // 都是整数运算加两个排好序的数组扫一遍，很快。
    for (size_t i = 0; i < docs.size() && !g_cancel; ++i) {
        if (!docs[i].ok) continue;
        for (size_t j = i + 1; j < docs.size(); ++j) {
            if (!docs[j].ok) continue;
            if (ds.find((int)i) == ds.find((int)j)) continue;
            std::wstring why = CompareFuzzy(docs[i], docs[j], maxHamming);
            if (why.empty()) continue;
            ds.merge((int)i, (int)j);
            if (reason[j].empty()) reason[j] = why;
        }
    }

    // 只有成组的才进列表；组内挑一份留着
    std::unordered_map<int, std::vector<int>> clusters;
    for (size_t i = 0; i < docs.size(); ++i) {
        if (docs[i].ok) clusters[ds.find((int)i)].push_back((int)i);
    }

    std::vector<int> rows;
    int groupNo = 0;
    for (auto& entry : clusters) {
        std::vector<int>& members = entry.second;
        if (members.size() < 2) continue;
        ++groupNo;

        int keeper = members[0];
        for (int idx : members) {
            if (BetterKeeper(docs[idx], docs[keeper])) keeper = idx;
        }
        // 留下的排在组里第一行，剩下的按体积从大到小
        std::sort(members.begin(), members.end(), [&](int x, int y) {
            if (x == keeper) return true;
            if (y == keeper) return false;
            return docs[x].chars > docs[y].chars;
        });
        for (int idx : members) {
            docs[idx].group = groupNo;
            docs[idx].keep = (idx == keeper);
            docs[idx].reason = (idx == keeper) ? L"保留" : reason[idx];
            rows.push_back(idx);
        }
    }

    {
        std::lock_guard<std::mutex> guard(g_lock);
        g_docs.swap(docs);
        g_rows.swap(rows);
    }
    g_scanning = false;
    PostMessageW(g_main, MSG_SCANNED, 0, 0);
    return 0;
}

// ── 界面 ─────────────────────────────────────────────────────────────

static void UpdateButtons() {
    BOOL idle = g_scanning ? FALSE : TRUE;
    EnableWindow(g_btnScan, idle);
    EnableWindow(g_btnStop, !idle);
    EnableWindow(g_btnAdd, idle);
    EnableWindow(g_btnClear, idle);
    EnableWindow(g_btnMove, idle);
    EnableWindow(g_btnRecycle, idle);
    EnableWindow(g_btnCheckAll, idle);
    EnableWindow(g_btnUncheckAll, idle);
    EnableWindow(g_btnExport, idle);
}

/// 把分组结果写成一份清单，存到第一个扫描根下面。
/// 动手删之前可以先看看这份，也留个凭据：哪些被判成重复、依据是什么。
static void ExportList() {
    std::wstring root, text;
    {
        std::lock_guard<std::mutex> guard(g_lock);
        if (g_roots.empty() || g_rows.empty()) return;
        root = g_roots[0];

        int lastGroup = -1;
        for (int idx : g_rows) {
            const Doc& d = g_docs[idx];
            if (d.group != lastGroup) {
                lastGroup = d.group;
                text += L"\r\n第 " + std::to_wstring(d.group) + L" 组\r\n";
            }
            text += (d.keep ? L"  [保留] " : L"  [重复] ");
            text += d.name;
            text += L"\t" + SizeText(d.bytes);
            text += L"\t" + (d.chars ? std::to_wstring(d.chars) + L" 字" : std::wstring(L"—"));
            text += L"\t" + d.reason;
            text += L"\t" + d.rel + L"\r\n";
        }
    }

    std::wstring out = Join(root, L"_查重清单.txt");
    HANDLE h = CreateFileW(out.c_str(), GENERIC_WRITE, 0, nullptr,
                           CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return;

    // 带 BOM 存 UTF-8，记事本打开不会乱码
    const unsigned char bom[] = { 0xEF, 0xBB, 0xBF };
    DWORD wrote = 0;
    WriteFile(h, bom, 3, &wrote, nullptr);
    std::string utf8 = ToUtf8(text);
    WriteFile(h, utf8.data(), (DWORD)utf8.size(), &wrote, nullptr);
    CloseHandle(h);

    SetWindowTextW(g_status, (L"清单已导出：" + out).c_str());
}

static void FillRows() {
    size_t count;
    {
        std::lock_guard<std::mutex> guard(g_lock);
        count = g_rows.size();
    }
    ListView_DeleteAllItems(g_list);
    ListView_SetItemCount(g_list, (int)count);

    std::lock_guard<std::mutex> guard(g_lock);
    for (size_t i = 0; i < g_rows.size(); ++i) {
        const Doc& d = g_docs[g_rows[i]];
        LVITEMW item{};
        item.mask = LVIF_TEXT | LVIF_PARAM;
        item.iItem = (int)i;
        item.lParam = (LPARAM)g_rows[i];
        std::wstring group = std::to_wstring(d.group);
        item.pszText = (LPWSTR)group.c_str();
        int row = ListView_InsertItem(g_list, &item);

        ListView_SetItemText(g_list, row, 1, (LPWSTR)d.name.c_str());
        std::wstring size = SizeText(d.bytes);
        ListView_SetItemText(g_list, row, 2, (LPWSTR)size.c_str());
        std::wstring chars = d.chars ? (std::to_wstring(d.chars / 1000) + L" 千字") : L"—";
        ListView_SetItemText(g_list, row, 3, (LPWSTR)chars.c_str());
        ListView_SetItemText(g_list, row, 4, (LPWSTR)d.reason.c_str());
        ListView_SetItemText(g_list, row, 5, (LPWSTR)DirOf(d.rel).c_str());

        // 该删的默认勾上，但「书名相似」这条证据弱，留给人自己看
        bool weak = d.reason.find(L"书名相似") != std::wstring::npos;
        ListView_SetCheckState(g_list, row, (!d.keep && !weak) ? TRUE : FALSE);
    }
}

static void ShowSummary() {
    size_t total, dup, groups = 0;
    int lastGroup = -1;
    {
        std::lock_guard<std::mutex> guard(g_lock);
        total = g_docs.size();
        dup = g_rows.size();
        for (int idx : g_rows) {
            if (g_docs[idx].group != lastGroup) { lastGroup = g_docs[idx].group; ++groups; }
        }
    }
    wchar_t buf[256];
    swprintf_s(buf, L"扫描 %zu 个 txt，%zu 组重复，涉及 %zu 个文件", total, groups, dup);
    SetWindowTextW(g_status, buf);
}

/// 收集勾上的行
static std::vector<int> CheckedDocs() {
    std::vector<int> out;
    int count = ListView_GetItemCount(g_list);
    for (int i = 0; i < count; ++i) {
        if (!ListView_GetCheckState(g_list, i)) continue;
        LVITEMW item{};
        item.mask = LVIF_PARAM;
        item.iItem = i;
        if (ListView_GetItem(g_list, &item)) out.push_back((int)item.lParam);
    }
    return out;
}

static void SetAllChecks(BOOL on) {
    int count = ListView_GetItemCount(g_list);
    for (int i = 0; i < count; ++i) ListView_SetCheckState(g_list, i, on);
}

/// 移到扫描根下的「_重复」文件夹，保留相对路径。
/// 默认走这条而不是删除：判错了还能搬回来。
static void MoveChecked() {
    std::vector<int> picked = CheckedDocs();
    if (picked.empty()) return;

    std::wstring root;
    {
        std::lock_guard<std::mutex> guard(g_lock);
        if (g_roots.empty()) return;
        root = g_roots[0];
    }
    std::wstring bin = Join(root, L"_重复");

    wchar_t ask[256];
    swprintf_s(ask, L"把勾选的 %zu 个文件移动到\n%s\n\n继续吗？", picked.size(), bin.c_str());
    if (MessageBoxW(g_main, ask, L"查重", MB_OKCANCEL | MB_ICONQUESTION) != IDOK) return;

    size_t moved = 0;
    {
        std::lock_guard<std::mutex> guard(g_lock);
        for (int idx : picked) {
            const Doc& d = g_docs[idx];
            std::wstring dst = Join(bin, d.rel);
            SHCreateDirectoryExW(nullptr, DirOf(dst).c_str(), nullptr);
            // 同名就往后加序号，别把上一次挪进去的覆盖掉
            std::wstring target = dst;
            for (int n = 2; GetFileAttributesW(target.c_str()) != INVALID_FILE_ATTRIBUTES; ++n) {
                size_t dot = dst.find_last_of(L'.');
                target = dst.substr(0, dot) + L" (" + std::to_wstring(n) + L")" + dst.substr(dot);
            }
            if (MoveFileW(d.path.c_str(), target.c_str())) ++moved;
        }
    }

    wchar_t done[128];
    swprintf_s(done, L"移动了 %zu 个文件，重新扫描一下看看结果", moved);
    SetWindowTextW(g_status, done);
}

/// 删到回收站，不是直接删——SHFileOperation 加 FOF_ALLOWUNDO
static void RecycleChecked() {
    std::vector<int> picked = CheckedDocs();
    if (picked.empty()) return;

    wchar_t ask[256];
    swprintf_s(ask, L"把勾选的 %zu 个文件删到回收站？", picked.size());
    if (MessageBoxW(g_main, ask, L"查重", MB_OKCANCEL | MB_ICONWARNING) != IDOK) return;

    // SHFileOperation 要的是一串以 \0 分隔、末尾再一个 \0 的路径
    std::wstring buffer;
    {
        std::lock_guard<std::mutex> guard(g_lock);
        for (int idx : picked) {
            buffer += g_docs[idx].path;
            buffer.push_back(L'\0');
        }
    }
    buffer.push_back(L'\0');

    SHFILEOPSTRUCTW op{};
    op.hwnd = g_main;
    op.wFunc = FO_DELETE;
    op.pFrom = buffer.c_str();
    op.fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_NOERRORUI;
    int rc = SHFileOperationW(&op);

    wchar_t done[128];
    swprintf_s(done, rc == 0 ? L"已删到回收站 %zu 个" : L"删除中断（错误 %d）",
               rc == 0 ? picked.size() : (size_t)rc);
    SetWindowTextW(g_status, done);
}

static void StartScan() {
    {
        std::lock_guard<std::mutex> guard(g_lock);
        if (g_roots.empty()) {
            MessageBoxW(g_main, L"先添加要扫描的文件夹。", L"查重", MB_ICONINFORMATION);
            return;
        }
    }
    if (g_scanning) return;
    g_cancel = false;
    g_scanning = true;
    UpdateButtons();
    SetWindowTextW(g_status, L"扫描中…");
    CloseHandle(CreateThread(nullptr, 0, ScanThread, nullptr, 0, nullptr));
}

static void AddRoot(const std::wstring& dir) {
    std::lock_guard<std::mutex> guard(g_lock);
    for (const std::wstring& r : g_roots) if (r == dir) return;
    g_roots.push_back(dir);
}

static void RefreshRootLabel() {
    std::wstring text;
    {
        std::lock_guard<std::mutex> guard(g_lock);
        if (g_roots.empty()) {
            text = L"把要查重的文件夹拖进来";
        } else {
            text = L"已选 " + std::to_wstring(g_roots.size()) + L" 个文件夹：" + g_roots[0];
            if (g_roots.size() > 1) text += L" 等";
        }
    }
    SetWindowTextW(g_status, text.c_str());
}

static void Layout(HWND hwnd) {
    RECT rc;
    GetClientRect(hwnd, &rc);
    const int W = rc.right, H = rc.bottom;
    const int pad = 12, row = 30, gap = 8;

    int x = pad, y = pad;
    auto place = [&](HWND h, int w) { MoveWindow(h, x, y, w, row, TRUE); x += w + gap; };
    place(g_btnAdd, 108);
    place(g_btnClear, 84);
    place(g_btnScan, 84);
    place(g_btnStop, 72);

    // 相似度阈值贴在右边
    MoveWindow(GetDlgItem(hwnd, ID_SIM_LABEL), W - pad - 60 - gap - 150, y + 5, 150, 22, TRUE);
    MoveWindow(g_simEdit, W - pad - 60, y, 60, row, TRUE);

    y += row + gap;
    int bottom = H - pad - row - gap - 16 - gap;
    MoveWindow(g_list, pad, y, W - pad * 2, max(80, bottom - y), TRUE);

    y = H - pad - row - gap - 16;
    MoveWindow(g_progress, pad, y, W - pad * 2, 16, TRUE);

    y = H - pad - row;
    x = pad;
    place(g_btnCheckAll, 108);
    place(g_btnUncheckAll, 96);
    place(g_btnExport, 96);
    MoveWindow(g_status, x, y + 5, max(60, W - x - pad - 248), 22, TRUE);
    MoveWindow(g_btnMove, W - pad - 116 - gap - 116, y, 116, row, TRUE);
    MoveWindow(g_btnRecycle, W - pad - 116, y, 116, row, TRUE);
}

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_CREATE: {
        g_main = hwnd;
        NONCLIENTMETRICSW ncm{ sizeof(ncm) };
        SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof(ncm), &ncm, 0);
        g_font = CreateFontIndirectW(&ncm.lfMessageFont);

        auto button = [&](const wchar_t* text, int id) {
            HWND h = CreateWindowExW(0, L"BUTTON", text, WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
                                     0, 0, 0, 0, hwnd, (HMENU)(INT_PTR)id, nullptr, nullptr);
            SendMessageW(h, WM_SETFONT, (WPARAM)g_font, TRUE);
            return h;
        };
        g_btnAdd = button(L"添加文件夹", ID_ADD_FOLDER);
        g_btnClear = button(L"清空", ID_CLEAR);
        g_btnScan = button(L"开始查重", ID_SCAN);
        g_btnStop = button(L"停止", ID_STOP);
        g_btnCheckAll = button(L"全选重复项", ID_CHECK_ALL);
        g_btnUncheckAll = button(L"全不选", ID_UNCHECK_ALL);
        g_btnExport = button(L"导出清单", ID_EXPORT);
        g_btnMove = button(L"移到 _重复", ID_MOVE);
        g_btnRecycle = button(L"删到回收站", ID_RECYCLE);

        HWND label = CreateWindowExW(0, L"STATIC", L"正文相似度容差（0-16）：",
            WS_CHILD | WS_VISIBLE | SS_RIGHT, 0, 0, 0, 0, hwnd,
            (HMENU)ID_SIM_LABEL, nullptr, nullptr);
        SendMessageW(label, WM_SETFONT, (WPARAM)g_font, TRUE);

        g_simEdit = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"3",
            WS_CHILD | WS_VISIBLE | ES_NUMBER | ES_CENTER, 0, 0, 0, 0, hwnd,
            (HMENU)ID_SIM_EDIT, nullptr, nullptr);
        SendMessageW(g_simEdit, WM_SETFONT, (WPARAM)g_font, TRUE);

        g_progress = CreateWindowExW(0, PROGRESS_CLASSW, nullptr, WS_CHILD | WS_VISIBLE,
            0, 0, 0, 0, hwnd, (HMENU)ID_PROGRESS, nullptr, nullptr);

        g_status = CreateWindowExW(0, L"STATIC", L"把要查重的文件夹拖进来",
            WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, hwnd, (HMENU)ID_STATUS, nullptr, nullptr);
        SendMessageW(g_status, WM_SETFONT, (WPARAM)g_font, TRUE);

        g_list = CreateWindowExW(WS_EX_CLIENTEDGE, WC_LISTVIEWW, nullptr,
            WS_CHILD | WS_VISIBLE | LVS_REPORT | LVS_SHOWSELALWAYS,
            0, 0, 0, 0, hwnd, (HMENU)ID_LIST, nullptr, nullptr);
        SendMessageW(g_list, WM_SETFONT, (WPARAM)g_font, TRUE);
        ListView_SetExtendedListViewStyle(g_list,
            LVS_EX_FULLROWSELECT | LVS_EX_CHECKBOXES | LVS_EX_DOUBLEBUFFER | LVS_EX_GRIDLINES);

        const wchar_t* cols[] = { L"组", L"文件名", L"大小", L"字数", L"判定依据", L"目录" };
        const int widths[] = { 48, 340, 80, 90, 260, 200 };
        for (int i = 0; i < 6; ++i) {
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

    case WM_SIZE:      Layout(hwnd); return 0;
    case WM_GETMINMAXINFO: ((MINMAXINFO*)lp)->ptMinTrackSize = { 900, 520 }; return 0;

    case WM_DROPFILES: {
        HDROP drop = (HDROP)wp;
        UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
        for (UINT i = 0; i < count; ++i) {
            wchar_t path[MAX_PATH];
            DragQueryFileW(drop, i, path, MAX_PATH);
            AddRoot(IsDir(path) ? path : DirOf(path));
        }
        DragFinish(drop);
        RefreshRootLabel();
        return 0;
    }

    case MSG_PROGRESS: {
        size_t done = (size_t)wp, total = (size_t)lp;
        SendMessageW(g_progress, PBM_SETRANGE32, 0, (LPARAM)max(1, (int)total));
        SendMessageW(g_progress, PBM_SETPOS, (WPARAM)done, 0);
        wchar_t buf[128];
        swprintf_s(buf, L"正在算指纹 %zu / %zu", done, total);
        SetWindowTextW(g_status, buf);
        return 0;
    }

    case MSG_SCANNED:
        UpdateButtons();
        FillRows();
        ShowSummary();
        SendMessageW(g_progress, PBM_SETPOS, 0, 0);
        return 0;

    case WM_COMMAND:
        switch (LOWORD(wp)) {
        case ID_ADD_FOLDER: {
            BROWSEINFOW bi{};
            bi.hwndOwner = hwnd;
            bi.lpszTitle = L"选择要查重的文件夹";
            bi.ulFlags = BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE;
            LPITEMIDLIST idl = SHBrowseForFolderW(&bi);
            if (idl) {
                wchar_t path[MAX_PATH] = L"";
                SHGetPathFromIDListW(idl, path);
                CoTaskMemFree(idl);
                if (path[0]) { AddRoot(path); RefreshRootLabel(); }
            }
            return 0;
        }
        case ID_CLEAR: {
            {
                std::lock_guard<std::mutex> guard(g_lock);
                g_roots.clear();
                g_docs.clear();
                g_rows.clear();
            }
            ListView_DeleteAllItems(g_list);
            RefreshRootLabel();
            return 0;
        }
        case ID_SCAN:        StartScan(); return 0;
        case ID_STOP:        g_cancel = true; return 0;
        case ID_CHECK_ALL:   SetAllChecks(TRUE); return 0;
        case ID_UNCHECK_ALL: SetAllChecks(FALSE); return 0;
        case ID_EXPORT:      ExportList(); return 0;
        case ID_MOVE:        MoveChecked(); return 0;
        case ID_RECYCLE:     RecycleChecked(); return 0;
        }
        return 0;

    case WM_CLOSE:
        g_cancel = true;
        DestroyWindow(hwnd);
        return 0;

    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

/// 命令行上带的文件夹直接当扫描根，方便从资源管理器拖到 exe 图标上
static void AddFromCommandLine() {
    int count = 0;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &count);
    if (!argv) return;
    for (int i = 1; i < count; ++i) {
        AddRoot(IsDir(argv[i]) ? argv[i] : DirOf(argv[i]));
    }
    LocalFree(argv);
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE, PWSTR, int show) {
    SetProcessDPIAware();
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

    INITCOMMONCONTROLSEX icc{ sizeof(icc),
        ICC_LISTVIEW_CLASSES | ICC_PROGRESS_CLASS | ICC_STANDARD_CLASSES };
    InitCommonControlsEx(&icc);

    WNDCLASSEXW wc{ sizeof(wc) };
    wc.lpfnWndProc = WndProc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
    wc.lpszClassName = L"TxtDedupWindow";
    wc.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
    RegisterClassExW(&wc);

    HWND hwnd = CreateWindowExW(WS_EX_ACCEPTFILES, wc.lpszClassName,
        L"查重 —— 找出重复的小说 txt",
        WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 1120, 640,
        nullptr, nullptr, inst, nullptr);
    if (!hwnd) return 1;

    AddFromCommandLine();
    RefreshRootLabel();

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
