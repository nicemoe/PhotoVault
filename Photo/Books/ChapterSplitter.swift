import Foundation

/// 切分出来的一章：标题 + 正文
struct ParsedChapter {
    var title: String
    var body: String
}

/// TXT 章节切分。
enum ChapterSplitter {

    /// 分章规则的版本。规则改了就 +1，旧书会被重新拆一遍（见 BookLibrary）。
    ///
    /// 1：第一版真正能用的规则。在这之前整个正则编译不过（见下），所有书
    ///    其实都是按字数硬切的，标题全是「第 N 节」，得整体重来一次。
    static let version = 1

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
                result.append(ParsedChapter(title: "开篇", body: intro))
            }
        }

        for (i, heading) in headings.enumerated() {
            let bodyStart = heading.upperBound
            let bodyEnd = i + 1 < headings.count ? headings[i + 1].lowerBound : text.endIndex
            guard bodyStart <= bodyEnd else { continue }

            let title = String(text[heading]).trimmingCharacters(in: .whitespacesAndNewlines)
            let body = String(text[bodyStart..<bodyEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(ParsedChapter(title: title.isEmpty ? "第 \(i + 1) 章" : title, body: body))
        }
        return result
    }

    // MARK: 没有章节标题时按字数切

    private static func chunk(_ text: String) -> [ParsedChapter] {
        guard text.count > fallbackChunkSize else {
            return [ParsedChapter(title: "正文", body: text)]
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
                result.append(ParsedChapter(title: "第 \(index) 节", body: body))
                index += 1
            }
            cursor = end
        }
        return result
    }
}
