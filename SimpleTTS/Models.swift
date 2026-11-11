import CryptoKit
import Foundation

/// 読み込んだテキストファイルを文単位に分割したもの。
/// `id` は本文の SHA-256 で、セーブデータと本文キャッシュの紐付けに使う。
nonisolated struct ReaderDocument: Identifiable, Sendable {
    let id: String
    let title: String
    /// メモの保存先の ID。ファイルから開いた文書はファイルパスの SHA-256（`notesID(for:)`）。
    /// ファイルの場所が分からない文書（場所を記録していない旧形式のセーブから復元した文書など）は `id` と同じ。
    let notesID: String
    let sentences: [String]

    /// メモを本文の ID で保存している（ファイルの場所が分からない）か
    var notesAreKeyedByContent: Bool { notesID == id }

    init(title: String, text: String, notesID: String? = nil) {
        self.id = Self.digest(of: text)
        self.notesID = notesID ?? self.id
        self.title = title
        self.sentences = SentenceSplitter.split(text)
    }

    static func notesID(for url: URL) -> String {
        digest(of: url.standardizedFileURL.path)
    }

    static func digest(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// 読み上げ位置のセーブデータ（オートセーブ／任意セーブ共通）。
nonisolated struct SavePoint: Codable, Identifiable, Hashable, Sendable {
    nonisolated enum Kind: String, Codable, Sendable {
        case auto
        case manual
    }

    var id: UUID
    var kind: Kind
    var documentID: String
    var documentTitle: String
    var sentenceIndex: Int
    var sentenceCount: Int
    var excerpt: String
    var createdAt: Date
    /// 文書の `notesID`。メモ機能より前のセーブでは nil。
    var notesID: String? = nil

    /// ファイルの場所を記録していない（旧形式の、またはそうしたセーブから復元した文書の）セーブか
    var isKeyedByContent: Bool { notesID == nil || notesID == documentID }

    /// 文書の位置として使えるセーブか。ファイルの場所を記録していないセーブは、同じ本文のどのファイルにも当てる。
    func belongs(to document: ReaderDocument) -> Bool {
        documentID == document.id && (isKeyedByContent || notesID == document.notesID)
    }
}

/// 本文を「読み上げ・表示の単位」となる文に分割する。
nonisolated enum SentenceSplitter {
    /// 文末とみなす記号
    private static let terminators: Set<Character> = ["。", "｡", "．", "！", "？", "!", "?"]
    /// 文末記号の直後に続く閉じ括弧類（文に含める）
    private static let closers: Set<Character> = [
        "」", "』", "）", ")", "】", "〉", "》", "〕", "］", "]", "”", "’", "\"", "'",
    ]
    /// 長すぎる文を区切ってよい位置
    private static let softBreaks: Set<Character> = ["、", "，", ",", "；", ";", "：", ":", " ", "　"]

    /// - Parameters:
    ///   - softLimit: この文字数を超えたら読点や空白で区切る
    ///   - hardLimit: この文字数に達したら強制的に区切る
    static func split(_ text: String, softLimit: Int = 120, hardLimit: Int = 240) -> [String] {
        let chars = Array(text)
        var result: [String] = []
        var buffer = ""
        var count = 0

        func flush() {
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                result.append(trimmed)
            }
            buffer = ""
            count = 0
        }

        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isNewline {
                // 改行は段落の区切りとして扱う
                flush()
                i += 1
                continue
            }

            buffer.append(c)
            count += 1

            var isSentenceEnd = terminators.contains(c)
            if c == "." {
                // 3.14 や e.g. の途中では区切らない（後ろが空白・閉じ括弧・末尾のときだけ文末）
                let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
                if let next {
                    isSentenceEnd = next.isWhitespace || closers.contains(next)
                } else {
                    isSentenceEnd = true
                }
            }

            if isSentenceEnd {
                // 「！？」「。」」などの連続をまとめて同じ文に含める
                while i + 1 < chars.count {
                    let next = chars[i + 1]
                    guard terminators.contains(next) || closers.contains(next) || next == "." else { break }
                    i += 1
                    buffer.append(next)
                }
                flush()
            } else if count >= hardLimit || (count >= softLimit && softBreaks.contains(c)) {
                flush()
            }
            i += 1
        }
        flush()
        return result
    }
}

/// 検索語を含む文（検索結果の 1 行）
nonisolated struct SentenceSearchResult: Identifiable, Hashable, Sendable {
    /// 文書内の文番号（0 始まり）
    let sentenceIndex: Int
    let sentence: String

    var id: Int { sentenceIndex }
}

/// 文書の文から、検索語を部分一致で含むものを探す。
nonisolated enum SentenceSearch {
    /// 大文字と小文字、全角と半角（「ＡＢＣ」と「ABC」、「ｶﾅ」と「カナ」）を区別しない。
    /// 濁点・半濁点は区別したいので（「は」と「ば」は別の語）、`.diacriticInsensitive` は付けない。
    static let options: String.CompareOptions = [.caseInsensitive, .widthInsensitive]
    /// 一覧に出す件数の上限。一致する文が非常に多いとき、一覧の更新で入力が遅れないようにする。
    static let resultLimit = 1000

    /// 前後の空白と改行を除いた検索語。空なら nil（検索しない）。
    static func normalizedQuery(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 検索語を含む文を文書の順に返す（最大 `limit` 件）。`totalCount` は上限を超えた分も含めた一致数。
    static func search(_ query: String, in sentences: [String], limit: Int = resultLimit) -> (results: [SentenceSearchResult], totalCount: Int) {
        guard let query = normalizedQuery(query) else { return ([], 0) }
        var results: [SentenceSearchResult] = []
        var totalCount = 0
        for (index, sentence) in sentences.enumerated() {
            // 入力変更や文書の切り替えで不要になった走査を速やかに止める。
            if Task.isCancelled { return ([], 0) }
            guard sentence.range(of: query, options: options) != nil else { continue }
            totalCount += 1
            if results.count < limit {
                results.append(SentenceSearchResult(sentenceIndex: index, sentence: sentence))
            }
        }
        return (results, totalCount)
    }

    /// 文の中で検索語に一致するすべての範囲（強調表示に使う）
    static func matchRanges(of query: String, in text: String) -> [Range<String.Index>] {
        guard let query = normalizedQuery(query) else { return [] }
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: query, options: options, range: searchStart..<text.endIndex),
              !range.isEmpty {
            ranges.append(range)
            searchStart = range.upperBound
        }
        return ranges
    }
}

/// テキストファイルの文字コードを推定して文字列化する。
nonisolated enum TextDecoding {
    static func decode(_ data: Data) -> String? {
        let raw: String?
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            raw = String(data: data.dropFirst(3), encoding: .utf8)
        } else if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            raw = String(data: data, encoding: .utf16)
        } else {
            let candidates: [String.Encoding] = [.utf8, .shiftJIS, .japaneseEUC, .isoLatin1]
            raw = candidates.lazy.compactMap { String(data: data, encoding: $0) }.first
        }
        return raw?
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
