import Foundation
import UniformTypeIdentifiers

nonisolated enum NotesImportError: LocalizedError {
    case invalidCSV
    case invalidHeaders
    case noNotes
    case invalidRow(Int)
    case unresolvedAssignments
    case notesChanged

    var errorDescription: String? {
        switch self {
        case .invalidCSV:
            String(localized: "The CSV contains an unclosed quote or an invalid quoted field.")
        case .invalidHeaders:
            String(localized: "The file must have Sentence and Note columns. Use a CSV or TSV exported by SimpleTTS.")
        case .noNotes:
            String(localized: "The file contains no notes to import.")
        case .invalidRow(let row):
            String(localized: "Row \(row) has missing fields, an empty sentence or note, an invalid sentence number, or an invalid date.")
        case .unresolvedAssignments:
            String(localized: "Choose a sentence or skip each row. Each sentence can receive one note, and replacing an existing note requires confirmation.")
        case .notesChanged:
            String(localized: "The notes have changed since this import was opened. Cancel and import the file again.")
        }
    }
}

nonisolated struct ImportedNote: Identifiable, Hashable, Sendable {
    /// 見出しを 1 行目としたレコード番号。引用符内の改行は数えない。
    let id: Int
    let sentenceIndex: Int?
    let sentence: String
    let text: String
    let updatedAt: Date?
}

/// 書き出しと同じ引用規則を使う。列の順序と日英の見出しの両方に対応する。
nonisolated enum NotesImport {
    static func read(from url: URL) throws -> [ImportedNote] {
        let text = try TextFileLoader.read(from: url, allowedContentTypes: [.commaSeparatedText, .tabSeparatedText], normalizingLineEndings: false)
        return try parse(text, format: url.pathExtension.lowercased() == "tsv" ? .tsv : .csv)
    }

    static func parse(_ text: String, format: NotesExport.Format = .csv, timeZone: TimeZone = .current) throws -> [ImportedNote] {
        let records = try records(in: text, separator: format.separator.unicodeScalars.first!)
        guard let headers = records.first else { throw NotesImportError.noNotes }
        let names = headers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        func column(_ aliases: [String]) throws -> Int? {
            let found = names.indices.filter { aliases.contains(names[$0]) }
            guard found.count <= 1 else { throw NotesImportError.invalidHeaders }
            return found.first
        }
        guard let sentenceColumn = try column(["sentence", "文"]),
              let noteColumn = try column(["note", "メモ"]) else { throw NotesImportError.invalidHeaders }
        let numberColumn = try column(["sentence no.", "no.", "文番号"])
        let dateColumn = try column(["last modified", "最終更新日"])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.isLenient = false

        var notes: [ImportedNote] = []
        for (offset, fields) in records.dropFirst().enumerated() {
            try Task.checkCancellation()
            let row = offset + 2
            if fields == [""] { continue }
            guard fields.count == headers.count else { throw NotesImportError.invalidRow(row) }
            let sentence = restoringFormulaPrefix(fields[sentenceColumn])
            let note = restoringFormulaPrefix(fields[noteColumn])
            guard !sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NotesImportError.invalidRow(row) }
            var index: Int?
            if let numberColumn {
                let value = fields[numberColumn].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    guard let number = Int(value), number > 0 else { throw NotesImportError.invalidRow(row) }
                    index = number - 1
                }
            }
            var date: Date?
            if let dateColumn {
                let value = fields[dateColumn].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    guard let parsed = formatter.date(from: value), formatter.string(from: parsed) == value else {
                        throw NotesImportError.invalidRow(row)
                    }
                    date = parsed
                }
            }
            notes.append(ImportedNote(id: row, sentenceIndex: index, sentence: sentence, text: note, updatedAt: date))
        }
        guard !notes.isEmpty else { throw NotesImportError.noNotes }
        return notes
    }

    /// 書き出し時に付けた数式対策用の ' を戻す。
    private static func restoringFormulaPrefix(_ field: String) -> String {
        guard field.first == "'" else { return field }
        let suffix = String(field.dropFirst())
        return NotesExport.neutralizingFormula(suffix) == field ? suffix : field
    }

    private enum FieldState { case start, unquoted, quoted, closed }

    private static func records(in text: String, separator: Unicode.Scalar) throws -> [[String]] {
        var scalars = text.unicodeScalars[...]
        if scalars.first == "\u{FEFF}" { scalars = scalars.dropFirst() }
        var records: [[String]] = []
        var row: [String] = []
        var field = ""
        var state = FieldState.start
        var followsCR = false
        for scalar in scalars {
            if followsCR && scalar == "\n" { followsCR = false; continue }
            followsCR = false
            if state == .quoted {
                if scalar == "\"" { state = .closed }
                else { field.unicodeScalars.append(scalar) }
            } else if state == .closed && scalar == "\"" {
                field.append("\"")
                state = .quoted
            } else if scalar == separator || scalar == "\r" || scalar == "\n" {
                row.append(field)
                field = ""
                state = .start
                if scalar != separator {
                    records.append(row)
                    row = []
                    followsCR = scalar == "\r"
                }
            } else if scalar == "\"" && state == .start {
                state = .quoted
            } else {
                guard state != .closed, scalar != "\"" else { throw NotesImportError.invalidCSV }
                field.unicodeScalars.append(scalar)
                state = .unquoted
            }
        }
        guard state != .quoted else { throw NotesImportError.invalidCSV }
        if !row.isEmpty || !field.isEmpty || state != .start {
            row.append(field)
            records.append(row)
        }
        return records
    }
}

nonisolated struct NoteImportItem: Identifiable, Sendable {
    enum Match: Sendable { case exact, moved, ambiguous, missing }
    enum Assignment: Hashable, Sendable { case unresolved, skip, sentence(Int) }

    let source: ImportedNote
    let match: Match
    var assignment: Assignment
    var replacesExisting = false
    var id: Int { source.id }
    var targetIndex: Int? {
        if case .sentence(let index) = assignment { return index }
        return nil
    }
}

/// 確認中の文書とメモを固定し、別の文書や更新後のメモへの誤保存を防ぐ。
nonisolated struct NoteImportPlan: Identifiable, Sendable {
    let id = UUID()
    let documentID: String
    let contentID: String
    let sentences: [String]
    let existingNotes: [SentenceNote]
    let unattachedNotes: [SentenceNote]
    var items: [NoteImportItem]

    init(document: ReaderDocument, notes: [SentenceNote], unattached: [SentenceNote], imported: [ImportedNote]) {
        let sentences = document.sentences
        documentID = document.notesID
        contentID = document.id
        self.sentences = sentences
        existingNotes = notes
        unattachedNotes = unattached
        let positions = Dictionary(grouping: sentences.indices, by: { sentences[$0] })
        items = imported.map { source in
            let match: NoteImportItem.Match
            let target: Int?
            if let index = source.sentenceIndex, sentences.indices.contains(index), sentences[index] == source.sentence {
                match = .exact
                target = index
            } else {
                let candidates = positions[source.sentence] ?? []
                target = candidates.count == 1 ? candidates.first : nil
                match = target != nil ? .moved : (candidates.isEmpty ? .missing : .ambiguous)
            }
            return NoteImportItem(source: source, match: match, assignment: target.map { .sentence($0) } ?? .unresolved)
        }
    }

    var selectedCount: Int { items.filter { $0.targetIndex != nil }.count }
    var unresolvedCount: Int { items.filter { $0.assignment == .unresolved }.count }

    func existingNote(for item: NoteImportItem) -> SentenceNote? {
        existingNotes.first { $0.sentenceIndex == item.targetIndex }
    }

    func needsReplacementConfirmation(_ item: NoteImportItem) -> Bool {
        guard let existing = existingNote(for: item) else { return false }
        return existing.text != item.source.text
    }

    func hasDuplicateTarget(_ item: NoteImportItem) -> Bool {
        guard let target = item.targetIndex else { return false }
        return items.contains { $0.id != item.id && $0.targetIndex == target }
    }

    var canImport: Bool {
        let existing = Dictionary(uniqueKeysWithValues: existingNotes.map { ($0.sentenceIndex, $0.text) })
        var targets: Set<Int> = []
        for item in items {
            if item.assignment == .unresolved { return false }
            guard let target = item.targetIndex else { continue }
            guard sentences.indices.contains(target), targets.insert(target).inserted else { return false }
            if let text = existing[target], text != item.source.text, !item.replacesExisting { return false }
        }
        return !targets.isEmpty
    }
}
