import Foundation

/// 切分出来的一章。
struct ParsedChapter {
    /// 目录里显示的标题
    var title: String
    /// 这一章的全文。
    ///
    /// 正文里本来就有标题行的（小说 txt 基本都有），第一行就是那行标题——
    /// 从目录点进来，得能一眼看见自己在第几章，光有正文是认不出来的。
    ///
    /// 反过来，标题是我们自己编号编出来的（整本没有章节标记、只能按字数
    /// 硬切的那种），就不往里塞。那是我们的记账，不是书的内容，写进去等于
    /// 把人的文件改脏了——之前那一版正是这么干的，「第 1 节」「第 2 节」
    /// 现在还留在那些 txt 里。
    var text: String
}

/// TXT 章节切分。
enum ChapterSplitter {

    /// 分章规则的版本。规则改了就 +1，旧书会被重新拆一遍（见 BookLibrary）。
    ///
    /// 1：第一版真正能用的规则。在这之前整个正则编译不过（见下），所有书
    ///    其实都是按字数硬切的，标题全是「第 N 节」。
    /// 2：标题行留在正文里，从目录点进来能看见自己在第几章；
    ///    我们自己编的号不再写进文件。
    static let version = 2

    /// 常见中文章节标题：第一章 / 第1节 / 序章 / 楔子 / 番外 / Chapter 1。
    /// 限制标题长度是为了避免把正文里出现的「第一次」这类词误判成标题。
    ///
    /// 全角空格写 \\u3000 而不是 \\u{3000}。后者是 **Swift** 的转义写法，
    /// 而这里是双反斜杠——字符串里装的是字面的那六个字符，最后交给正则
    /// 引擎的也是它们。ICU 只认 \\uhhhh 四位十六进制，碰上 \\u{ 直接判
    /// 「转义不完整」，整个模式编译失败。而构造那儿是 try?，错误被吞掉
    /// 返回 nil，于是一个标题都找不到，每本书都掉进下面那条按字数硬切的
    /// 兜底路——分章从来就没生效过。
    private static let pattern = """
    ^[ \\t\\u3000]{0,8}\
    (?:\
    第[0-9０-９一二三四五六七八九十百千零两]{1,12}[章节節回卷篇集部幕]\
    |[序楔]\\s*[章子]\
    |楔子|引子|前言|序言|后记|後記|尾声|尾聲|终章|終章|番外[^\\n]{0,10}\
    |Chapter\\s+[0-9IVXivx]{1,6}\
    )\
    [ \\t\\u3000]*[^\\n]{0,40}$
    """

    /// 一本书里章节太少（比如整本一坨），就按固定字数切，
    /// 否则单章几十万字，分页和滚动都会卡。
    private static let fallbackChunkSize = 4000
    private static let minChapterCount = 2

    static func split(_ text: String) -> [ParsedChapter] {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return [] }

        let matches = headingRanges(in: normalized)
        if matches.count >= minChapterCount {
            return chapters(from: normalized, headings: matches)
        }
        return chunk(normalized)
    }

    // MARK: 归一化

    /// 统一换行、去掉零宽字符、压掉过多空行
    private static func normalize(_ text: String) -> String {
        var s = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\u{200B}", with: "")
        // 连着三个以上的换行一律压成两个，一次正则扫完。
        // 原来是 while contains("\n\n\n") 反复替换：每轮都要把整串扫一遍再
        // 复制一遍，碰上连着几十个空行的文件就得来回复制几十次。
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)

        // 清掉上一版塞进文件的编号行。
        //
        // 那时候整本书按字数硬切，生成的「第 1 节」被当成标题写进了 txt，
        // 而原文件导入后就删了——盘上那份是唯一一份，等于把人的书改脏了。
        // 认的是我们自己那个带空格的格式：小说里写章节是「第一节」「第1节」，
        // 不会在数字两边留空格，所以不会误伤作者的标题。
        s = s.replacingOccurrences(of: "^第 [0-9]+ [章节]$\n?", with: "",
                                   options: [.regularExpression])

        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 找标题行

    private static func headingRanges(in text: String) -> [Range<String.Index>] {
        // 不要 .allowCommentsAndWhitespace。
        //
        // 这个模式是靠行尾续行拼成一行的，里面本来就没有换行、也没有注释，
        // 开着那个选项什么都不多做，坏处却实打实：ICU 在那个模式下连字符类
        // 里的空格都一起吃掉，于是缩进用普通空格的标题行会匹配不上。
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.anchorsMatchLines]
        ) else { return [] }

        let ns = text as NSString
        let all = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        return all.compactMap { Range($0.range, in: text) }
    }

    private static func chapters(from text: String, headings: [Range<String.Index>]) -> [ParsedChapter] {
        var result: [ParsedChapter] = []

        // 第一个标题之前的内容（作者的话、简介之类）单独作为一章
        if let first = headings.first, first.lowerBound > text.startIndex {
            let intro = String(text[text.startIndex..<first.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if intro.count > 30 {
                result.append(ParsedChapter(title: "开篇", text: intro))
            }
        }

        for (i, heading) in headings.enumerated() {
            // 从标题那一行开始，不是从标题之后。
            //
            // 一章的第一行就该是它的标题——目录点进来，正文劈头就是内容的话，
            // 人根本认不出这是不是自己要的那一章。
            let start = heading.lowerBound
            let end = i + 1 < headings.count ? headings[i + 1].lowerBound : text.endIndex
            guard start <= end else { continue }

            let title = String(text[heading]).trimmingCharacters(in: .whitespacesAndNewlines)
            let whole = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(ParsedChapter(title: title.isEmpty ? "第 \(i + 1) 章" : title,
                                        text: whole))
        }
        return result
    }

    // MARK: 没有章节标题时按字数切

    private static func chunk(_ text: String) -> [ParsedChapter] {
        guard text.count > fallbackChunkSize else {
            return [ParsedChapter(title: "正文", text: text)]
        }

        var result: [ParsedChapter] = []
        var cursor = text.startIndex
        var index = 1

        while cursor < text.endIndex {
            let hardEnd = text.index(cursor, offsetBy: fallbackChunkSize, limitedBy: text.endIndex) ?? text.endIndex
            // 尽量断在段落边界上，别把句子劈开
            var end = hardEnd
            if hardEnd < text.endIndex,
               let breakPoint = text[cursor..<hardEnd].lastIndex(of: "\n") {
                let candidate = text.index(after: breakPoint)
                if text.distance(from: cursor, to: candidate) > fallbackChunkSize / 2 {
                    end = candidate
                }
            }
            let body = String(text[cursor..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                // 编号只当目录里的标签，不写进正文——这本书本来就没有章节标题，
                // 凭空塞一行进去就是在改人的文件
                result.append(ParsedChapter(title: "第 \(index) 节", text: body))
                index += 1
            }
            cursor = end
        }
        return result
    }
}
