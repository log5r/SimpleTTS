import Foundation

/// 1 つの文に付けたメモ。文書内の文番号と、その時点の文の本文を一緒に保存する。
/// 本文も保存しておくのは、文の分割方法が将来変わっても付け先を探し直せるようにするため。
nonisolated struct SentenceNote: Codable, Identifiable, Hashable, Sendable {
    /// 文書内の文番号（0 始まり）
    var sentenceIndex: Int
    /// メモを付けた文の本文
    var sentence: String
    /// メモの本文（改行を含められる）
    var text: String
    var updatedAt: Date

    var id: Int { sentenceIndex }
    /// 表示用の文番号（1 始まり）。表の並べ替えにも使う。
    var sentenceNumber: Int { sentenceIndex + 1 }
}

/// 1 つの文書（ファイル）に付けたメモの集まり。`Notes/<文書 ID>.json` に保存する。
nonisolated struct DocumentNotes: Codable, Hashable, Sendable {
    var documentID: String
    var documentTitle: String
    var notes: [SentenceNote]

    /// 今の本文の文にメモを振り分ける。本文が一致する文だけに付け、位置が変わって候補が複数ある場合は推測しない。
    /// 同じ文に複数のメモが付く場合は、最終更新日が新しいものを付ける。
    /// 付けられなかったメモ（`unattached`）は元の内容のまま返す。呼び出し側で一覧に出し、保存時にも失わない。
    func partitioned(for sentences: [String]) -> (attached: [SentenceNote], unattached: [SentenceNote]) {
        var byIndex: [Int: SentenceNote] = [:]
        var unattached: [SentenceNote] = []
        for original in notes.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            var note = original
            if !(sentences.indices.contains(note.sentenceIndex) && sentences[note.sentenceIndex] == note.sentence) {
                let candidates = sentences.indices.filter { sentences[$0] == note.sentence }
                guard candidates.count == 1, let index = candidates.first else {
                    unattached.append(original)
                    continue
                }
                note.sentenceIndex = index
            }
            guard byIndex[note.sentenceIndex] == nil else {
                unattached.append(original)
                continue
            }
            byIndex[note.sentenceIndex] = note
        }
        return (byIndex.values.sorted { $0.sentenceIndex < $1.sentenceIndex }, unattached)
    }
}

/// メモ一覧の 1 行。今の本文の文に付いたメモに加え、本文が変わって付け先の文が見つからなくなったメモも含める。
nonisolated struct NoteListEntry: Identifiable, Hashable, Sendable {
    enum ID: Hashable, Sendable {
        /// 今の本文の文番号（0 始まり）
        case attached(Int)
        /// 付け先の見つからないメモの通し番号
        case unattached(Int)
    }

    let id: ID
    let note: SentenceNote

    /// 今の本文での文番号（0 始まり）。付け先の文が見つからないメモは nil。
    var sentenceIndex: Int? {
        if case let .attached(index) = id { return index }
        return nil
    }

    /// 表示・書き出し用の文番号（1 始まり）。付け先の文が見つからないメモは空。
    var sentenceNumberText: String { sentenceIndex.map { String($0 + 1) } ?? "" }
    /// 並べ替え用の文番号。付け先の文が見つからないメモは末尾に並べる。
    var sortNumber: Int { sentenceIndex.map { $0 + 1 } ?? .max }
    var sentence: String { note.sentence }
    var text: String { note.text }
    var updatedAt: Date { note.updatedAt }

    /// 文番号順のメモに続けて、付け先の文が見つからないメモを新しい順に並べる。
    static func entries(attached: [SentenceNote], unattached: [SentenceNote]) -> [NoteListEntry] {
        attached
            .sorted { $0.sentenceIndex < $1.sentenceIndex }
            .map { NoteListEntry(id: .attached($0.sentenceIndex), note: $0) }
        + unattached.enumerated()
            .sorted { $0.element.updatedAt > $1.element.updatedAt }
            .map { NoteListEntry(id: .unattached($0.offset), note: $0.element) }
    }
}

/// メモ一覧を表計算ソフトなどで開ける形式に書き出す。
nonisolated enum NotesExport {
    enum Format: String, CaseIterable, Identifiable, Sendable {
        case csv
        case tsv

        var id: String { rawValue }
        var fileExtension: String { rawValue }
        var separator: String { self == .csv ? "," : "\t" }
    }

    /// 見出し行を含む表を作る。
    ///
    /// - 区切り文字・ダブルクォート・改行を含む欄はダブルクォートで囲み、中のダブルクォートは 2 つ重ねる（RFC 4180）。
    ///   TSV でも同じ規則にして、メモ中の改行やタブで行・列がずれないようにする。
    /// - 行末は CRLF。Excel で文字化けしないよう、CSV・TSV とも先頭に UTF-8 の BOM を付ける（`data(for:)`）。
    /// - 文やメモは外部のファイルに由来するため、表計算ソフトで数式として実行されないよう `neutralizingFormula` を通す。
    /// - 付け先の文が見つからないメモは、文番号を空欄にする。
    static func table(
        _ entries: [NoteListEntry],
        format: Format,
        headers: [String],
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var rows = [headers]
        for entry in entries {
            rows.append([
                entry.sentenceNumberText,
                neutralizingFormula(entry.sentence),
                neutralizingFormula(entry.text),
                formatter.string(from: entry.updatedAt),
            ])
        }
        return rows
            .map { row in row.map { escape($0, format: format) }.joined(separator: format.separator) }
            .joined(separator: "\r\n") + "\r\n"
    }

    static func data(for table: String) -> Data {
        Data([0xEF, 0xBB, 0xBF]) + Data(table.utf8)
    }

    /// 数式の始まりと解釈される文字（= + - @ タブ CR）で始まる欄の先頭に ' を付け、表計算ソフトで文字列として扱わせる
    /// （OWASP の CSV Injection 対策）。
    static func neutralizingFormula(_ field: String) -> String {
        guard let first = field.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first) else { return field }
        return "'" + field
    }

    static func escape(_ field: String, format: Format) -> String {
        let needsQuotes = field.contains { character in
            character == "\"" || character.isNewline || String(character) == format.separator
        }
        guard needsQuotes else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
