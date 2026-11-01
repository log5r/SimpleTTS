import CryptoKit
import Foundation

/// 読み込んだテキストファイルを文単位に分割したもの。
/// `id` は本文の SHA-256 で、セーブデータと本文キャッシュの紐付けに使う。
nonisolated struct ReaderDocument: Identifiable, Sendable {
    let id: String
    let title: String
    let sentences: [String]

    init(title: String, text: String) {
        self.id = Self.digest(of: text)
        self.title = title
        self.sentences = SentenceSplitter.split(text)
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
