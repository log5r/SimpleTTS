import Darwin
import Foundation

private enum TestFailure: Error { case failed(String) }

@main
struct StorageAndImportTests {
    @MainActor
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SimpleTTS-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try testFileImports(in: root)
        try testStorage(in: root)
        try testNotesStorage(in: root)
        try testNotesAttachment()
        try testNotesExport()
        try testNotesFilter()
        try testNotesImport(in: root)
        try testNotesImportMatching()
        print("PASS: local text validation, size limits, encodings, storage recovery, backup exclusion, complete erasure, notes storage, notes export, and notes filtering")
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw TestFailure.failed(message) }
    }

    private static func reject(_ url: URL, matching expected: TextFileError) throws {
        do {
            _ = try TextFileLoader.read(from: url)
            throw TestFailure.failed("Accepted rejected file: \(url.lastPathComponent)")
        } catch let error as TextFileError {
            try require(error == expected, "Wrong import rejection: \(error)")
        }
    }

    private static func testFileImports(in root: URL) throws {
        try reject(URL(string: "https://example.invalid/private.txt")!, matching: .localFileRequired)
        try reject(URL(string: "data:text/plain,hello")!, matching: .localFileRequired)

        let text = "日本語のテキストです。\n次の行です。"
        let plain = root.appending(path: "sample.txt")
        for encoding in [String.Encoding.utf8, .utf16, .shiftJIS, .japaneseEUC] {
            guard let data = text.data(using: encoding) else { throw TestFailure.failed("Encoding fixture failed") }
            try data.write(to: plain)
            try require(TextFileLoader.read(from: plain) == text, "Encoding import failed: \(encoding)")
        }

        let folder = root.appending(path: "directory.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try reject(folder, matching: .regularFileRequired)
        let symbolicLink = root.appending(path: "linked.txt")
        try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: plain)
        try reject(symbolicLink, matching: .regularFileRequired)
        let fifo = root.appending(path: "pipe.txt")
        try require(mkfifo(fifo.path, 0o600) == 0, "FIFO fixture failed")
        try reject(fifo, matching: .regularFileRequired)

        let unsupported = root.appending(path: "sample.pdf")
        try Data("%PDF-1.7".utf8).write(to: unsupported)
        try reject(unsupported, matching: .unsupportedFileType)
        try Data([0, 1, 2, 3]).write(to: plain)
        try reject(plain, matching: .invalidText)
        try Data("kill -9 \0<\0PID\0>\0 を使う。".utf8).write(to: plain)
        try require(TextFileLoader.read(from: plain) == "kill -9 <PID> を使う。", "Embedded NUL was not removed")
        try Data("A\0B\u{1B}C".utf8).write(to: plain)
        try reject(plain, matching: .invalidText)

        try Data(repeating: 65, count: TextFileLoader.maximumByteCount).write(to: plain)
        try require(TextFileLoader.read(from: plain).utf8.count == TextFileLoader.maximumByteCount, "Limit-sized file rejected")
        try Data(repeating: 65, count: TextFileLoader.maximumByteCount + 1).write(to: plain)
        try reject(plain, matching: .fileTooLarge)
    }

    @MainActor
    private static func testStorage(in root: URL) throws {
        let base = root.appending(path: "ApplicationSupport")
        let documents = base.appending(path: "Documents")
        let body = "保存と削除を検証するための合成テキスト。"
        let id = ReaderDocument.digest(of: body)
        let document = documents.appending(path: "\(id).txt")
        let savesURL = base.appending(path: "saves.json")
        let storage = Storage(baseURL: base)

        try require(storage.loadSaves().isEmpty, "New storage should have no saves")
        try require(base.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true,
                    "Storage root must be excluded from backup")
        try storage.storeDocumentText(body, id: id)
        let save = SavePoint(id: UUID(), kind: .auto, documentID: id, documentTitle: "fixture.txt",
                             sentenceIndex: 0, sentenceCount: 1, excerpt: "合成テキスト", createdAt: Date())
        try storage.writeSaves([save])
        try require(storage.loadSaves().first?.id == save.id, "Save round trip failed")
        try require(storage.loadDocumentText(id: id) == body, "Document round trip failed")
        for url in [document, savesURL] {
            try require(url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true,
                        "Written file must be excluded from backup")
        }

        // 以前のバージョンで除外されていなかった保存先を、読み込み時に移行する。
        var mutableBase = base
        var included = URLResourceValues()
        included.isExcludedFromBackup = false
        try mutableBase.setResourceValues(included)
        _ = try Storage(baseURL: base).loadSaves()
        try require(base.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true,
                    "Existing storage must be excluded on migration")

        do {
            try storage.storeDocumentText("must not escape", id: "../../outside")
            throw TestFailure.failed("Invalid document ID accepted")
        } catch StorageError.invalidDocumentID {}
        try require(storage.loadDocumentText(id: "../../outside") == nil, "Invalid document ID read allowed")

        try Data("broken JSON containing fixture-only text".utf8).write(to: savesURL)
        do {
            _ = try storage.loadSaves()
            throw TestFailure.failed("Corrupted save accepted")
        } catch StorageError.savesUnreadable(_, let backupURL) {
            try require(backupURL != nil, "Corrupted save should be quarantined")
        }
        storage.removeDocuments(notReferencedBy: [])
        try require(FileManager.default.fileExists(atPath: document.path), "Recovery should retain body")

        try storage.removeAllData()
        try require(storage.loadSaves().isEmpty, "Explicit erase must clear saves")
        try require(storage.loadDocumentText(id: id) == nil, "Explicit erase must clear body")
        let files = try FileManager.default.contentsOfDirectory(atPath: base.path)
        try require(files.sorted() == ["Documents", "Notes"], "Explicit erase must also clear quarantined files")
        try storage.storeDocumentText(body, id: id)
        try storage.writeSaves([save])
        try require(storage.loadSaves().count == 1, "Saving after erase should work")

        // 保存先が通常ファイルの場合、初期化失敗を成功として扱わない。
        let invalidBase = root.appending(path: "not-a-directory")
        try Data("fixture".utf8).write(to: invalidBase)
        do {
            _ = try Storage(baseURL: invalidBase).loadSaves()
            throw TestFailure.failed("Invalid storage directory accepted")
        } catch StorageError.unsafeStorageDirectory {}
    }

    @MainActor
    private static func testNotesStorage(in root: URL) throws {
        let base = root.appending(path: "NotesStorage")
        let storage = Storage(baseURL: base)
        let id = ReaderDocument.digest(of: "メモの保存を検証する本文。")
        let otherID = ReaderDocument.digest(of: "別の文書。")
        let notesFile = base.appending(path: "Notes/\(id).json")
        let note = SentenceNote(sentenceIndex: 0, sentence: "メモの保存を検証する本文。",
                                text: "1 行目\n2 行目, \"引用\"", updatedAt: Date(timeIntervalSince1970: 1_800_000_000))

        try require(storage.loadNotes(documentID: id) == nil, "New storage should have no notes")
        try storage.writeNotes(DocumentNotes(documentID: id, documentTitle: "fixture.txt", notes: [note]))
        try require(storage.loadNotes(documentID: id)?.notes == [note], "Notes round trip failed (including newlines)")
        try require(storage.loadNotes(documentID: otherID) == nil, "Notes leaked to another document")
        try require(notesFile.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true,
                    "Notes must be excluded from backup")

        // メモがなくなったらファイルを残さない
        try storage.writeNotes(DocumentNotes(documentID: id, documentTitle: "fixture.txt", notes: []))
        try require(!FileManager.default.fileExists(atPath: notesFile.path), "Empty notes file was kept")
        try storage.writeNotes(DocumentNotes(documentID: id, documentTitle: "fixture.txt", notes: []))

        do {
            try storage.writeNotes(DocumentNotes(documentID: "../../outside", documentTitle: "x", notes: [note]))
            throw TestFailure.failed("Invalid notes document ID accepted")
        } catch StorageError.invalidDocumentID {}
        do {
            _ = try storage.loadNotes(documentID: "../../outside")
            throw TestFailure.failed("Invalid notes document ID read allowed")
        } catch StorageError.invalidDocumentID {}

        // 壊れたメモは退避し、元のファイルを上書きしない
        try Data("broken notes fixture".utf8).write(to: notesFile)
        do {
            _ = try storage.loadNotes(documentID: id)
            throw TestFailure.failed("Corrupted notes accepted")
        } catch StorageError.notesUnreadable(_, let backupURL) {
            guard let backupURL else { throw TestFailure.failed("Corrupted notes should be quarantined") }
            try require(String(contentsOf: backupURL, encoding: .utf8) == "broken notes fixture",
                        "Quarantined notes changed")
        }
        try require(storage.loadNotes(documentID: id) == nil, "Quarantined notes were not moved away")

        // 別の文書のメモとして書かれたファイルは受け付けない
        try storage.writeNotes(DocumentNotes(documentID: otherID, documentTitle: "other.txt", notes: [note]))
        try FileManager.default.copyItem(at: base.appending(path: "Notes/\(otherID).json"), to: notesFile)
        do {
            _ = try storage.loadNotes(documentID: id)
            throw TestFailure.failed("Mismatched notes accepted")
        } catch StorageError.notesUnreadable {}

        try storage.removeAllData()
        try require(storage.loadNotes(documentID: otherID) == nil, "Explicit erase must clear notes")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: base.appending(path: "Notes").path)
        try require(leftovers.isEmpty, "Explicit erase must clear quarantined notes")
    }

    private static func testNotesAttachment() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let sentences = ["一つ目。", "二つ目。", "三つ目。"]
        let missing = SentenceNote(sentenceIndex: 9, sentence: "見つからない。", text: "残す", updatedAt: date)
        let older = SentenceNote(sentenceIndex: 0, sentence: "一つ目。", text: "古い", updatedAt: date.addingTimeInterval(-60))
        let (notes, unattached) = DocumentNotes(documentID: String(repeating: "a", count: 64), documentTitle: "t", notes: [
            SentenceNote(sentenceIndex: 0, sentence: "一つ目。", text: "そのまま", updatedAt: date),
            SentenceNote(sentenceIndex: 5, sentence: "三つ目。", text: "付け直し", updatedAt: date),
            missing,
            older,
        ]).partitioned(for: sentences)
        try require(notes.map(\.sentenceIndex) == [0, 2], "Notes were not attached by index and text")
        try require(notes.map(\.text) == ["そのまま", "付け直し"], "Duplicate notes were not resolved by date")
        try require(Set(unattached) == [missing, older], "Unattached notes were not returned unchanged")

        let entries = NoteListEntry.entries(attached: notes, unattached: unattached)
        try require(entries.map(\.sentenceIndex) == [0, 2, nil, nil], "Unattached notes should follow attached notes")
        try require(entries.map(\.text) == ["そのまま", "付け直し", "残す", "古い"], "Unattached notes should be newest first")
        try require(Set(entries.map(\.id)).count == entries.count, "List entry IDs must be unique")
        try require(entries[2].sortNumber > entries[1].sortNumber, "Unattached notes should sort last")
    }

    private static func testNotesFilter() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = NoteListEntry.entries(attached: [
            SentenceNote(sentenceIndex: 0, sentence: "Apple pie.", text: "おいしい", updatedAt: date),
            SentenceNote(sentenceIndex: 1, sentence: "はしる。", text: "line 1\nＡＰＰＬＥ", updatedAt: date),
            SentenceNote(sentenceIndex: 11, sentence: "ばしょ。", text: "メモ", updatedAt: date),
        ], unattached: [
            SentenceNote(sentenceIndex: 1, sentence: "消えた文。", text: "残す", updatedAt: date),
        ])
        func numbers(_ query: String) -> [Int?] { NoteListEntry.filtered(entries, by: query).map(\.sentenceIndex) }

        try require(numbers("") == [0, 1, 11, nil], "An empty query must keep every note in order")
        try require(numbers("  \n") == [0, 1, 11, nil], "A blank query must keep every note")
        // 文とメモの両方を、大文字・小文字と全角・半角を区別せずに探す
        try require(numbers("apple") == [0, 1], "Case- and width-insensitive match in sentences and notes failed")
        try require(numbers(" おいし ") == [0], "Query should be trimmed and match note text")
        // 濁点は区別する（「は」で「ば」は一致しない）
        try require(numbers("は") == [1], "Voiced marks must be distinguished")
        // 文番号は完全一致。付け先の見つからないメモ（元の文番号 2）は文番号で一致しない
        try require(numbers("12") == [11], "Sentence number should match exactly")
        try require(numbers("１２") == [11], "Full-width sentence numbers should match")
        try require(numbers("2") == [1], "Unattached notes must not match by their old sentence number")
        try require(numbers("消えた") == [nil], "Unattached notes should match by sentence text")
        try require(numbers("not found").isEmpty, "Unmatched queries must return no notes")
    }

    private static func testNotesExport() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)  // 2027-01-15 08:00:00 UTC
        let notes = NoteListEntry.entries(attached: [
            SentenceNote(sentenceIndex: 0, sentence: "Hello, \"world\".", text: "line 1\nline 2", updatedAt: date),
            SentenceNote(sentenceIndex: 2, sentence: "Tab\there", text: "plain", updatedAt: date),
        ], unattached: [])
        let headers = ["No.", "Sentence", "Note", "Last Modified"]
        let utc = TimeZone(identifier: "UTC")!
        let csv = NotesExport.table(notes, format: .csv, headers: headers, timeZone: utc)
        try require(csv == "No.,Sentence,Note,Last Modified\r\n"
                    + "1,\"Hello, \"\"world\"\".\",\"line 1\nline 2\",2027-01-15 08:00:00\r\n"
                    + "3,Tab\there,plain,2027-01-15 08:00:00\r\n",
                    "CSV escaping failed: \(csv.debugDescription)")
        let tsv = NotesExport.table(notes, format: .tsv, headers: headers, timeZone: utc)
        try require(tsv == "No.\tSentence\tNote\tLast Modified\r\n"
                    + "1\t\"Hello, \"\"world\"\".\"\t\"line 1\nline 2\"\t2027-01-15 08:00:00\r\n"
                    + "3\t\"Tab\there\"\tplain\t2027-01-15 08:00:00\r\n",
                    "TSV escaping failed: \(tsv.debugDescription)")

        // 付け先の文が見つからないメモは文番号を空にし、数式として解釈される欄の先頭に ' を付ける
        let risky = NoteListEntry.entries(attached: [
            SentenceNote(sentenceIndex: 0, sentence: "=HYPERLINK(\"http://example.invalid\",\"x\")", text: "+1", updatedAt: date),
            SentenceNote(sentenceIndex: 1, sentence: "-2", text: "@SUM(A1)", updatedAt: date),
            SentenceNote(sentenceIndex: 2, sentence: "a=b", text: "safe - text", updatedAt: date),
        ], unattached: [
            SentenceNote(sentenceIndex: 7, sentence: "消えた文。", text: "\t=1", updatedAt: date),
        ])
        let riskyCSV = NotesExport.table(risky, format: .csv, headers: headers, timeZone: utc)
        try require(riskyCSV == "No.,Sentence,Note,Last Modified\r\n"
                    + "1,\"'=HYPERLINK(\"\"http://example.invalid\"\",\"\"x\"\")\",'+1,2027-01-15 08:00:00\r\n"
                    + "2,'-2,'@SUM(A1),2027-01-15 08:00:00\r\n"
                    + "3,a=b,safe - text,2027-01-15 08:00:00\r\n"
                    + ",消えた文。,'\t=1,2027-01-15 08:00:00\r\n",
                    "Formula neutralization or unattached rows failed: \(riskyCSV.debugDescription)")
        let riskyTSV = NotesExport.table(risky, format: .tsv, headers: headers, timeZone: utc)
        try require(riskyTSV.contains("\r\n\t消えた文。\t\"'\t=1\"\t"), "TSV unattached row failed: \(riskyTSV.debugDescription)")

        let data = NotesExport.data(for: csv)
        try require(data.starts(with: [0xEF, 0xBB, 0xBF]) && data.dropFirst(3) == Data(csv.utf8),
                    "Export must be UTF-8 with BOM")
    }

    private static func testNotesImport(in root: URL) throws {
        let utc = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = NoteListEntry.entries(attached: [
            SentenceNote(sentenceIndex: 2, sentence: "Hello, \"world\".", text: "one\r\ntwo\nthree\tfour", updatedAt: date),
            SentenceNote(sentenceIndex: 3, sentence: "=1", text: "@a", updatedAt: date),
        ], unattached: [SentenceNote(sentenceIndex: 9, sentence: "消えた文。", text: "保管する", updatedAt: date)])
        for format in NotesExport.Format.allCases {
            for headers in [["Sentence No.", "Sentence", "Note", "Last Modified"], ["文番号", "文", "メモ", "最終更新日"]] {
                let table = NotesExport.table(entries, format: format, headers: headers, timeZone: utc)
                let parsed = try NotesImport.parse("\u{FEFF}" + table, format: format, timeZone: utc)
                try require(parsed.map(\.sentence) == entries.map(\.sentence), "Sentence round trip failed")
                try require(parsed.map(\.text) == entries.map(\.text), "Quoted or formula-prefixed notes did not round trip")
                try require(parsed.map(\.sentenceIndex) == [2, 3, nil], "Sentence numbers did not round trip")
                try require(parsed.allSatisfy { $0.updatedAt == date }, "Dates did not round trip")
                let url = root.appending(path: "notes.\(format.fileExtension)")
                try NotesExport.data(for: table).write(to: url)
                try require(NotesImport.read(from: url).map(\.text) == entries.map(\.text), "Exported file could not be imported")
            }
        }
        let reordered = try NotesImport.parse("Note,Extra,Sentence\n\"first\nsecond\",unused,文。")
        try require(reordered.count == 1 && reordered[0].text == "first\nsecond" && reordered[0].updatedAt == nil,
                    "Reordered or optional columns failed")
        let minimal = root.appending(path: "minimal.csv")
        for encoding in [String.Encoding.utf16, .shiftJIS] {
            try "文,メモ\r\n本文。,注釈".data(using: encoding)!.write(to: minimal)
            try require(NotesImport.read(from: minimal).first?.text == "注釈", "CSV encoding failed")
        }
        for csv in [
            "Sentence,Note\n\"unclosed,note", "Sentence,Note\na\"b,note", "Sentence,Note\n\"a\"oops,note",
            "Sentence,Sentence,Note\na,b,c", "Wrong,Columns\na,b", "Sentence,Note\n", "Sentence,Note\na,",
            "Sentence,Note\na,note,extra", "Sentence No.,Sentence,Note\n0,a,note",
            "Sentence No.,Sentence,Note\nno,a,note", "Sentence,Note,Last Modified\na,note,2026-02-30 12:00:00",
        ] {
            do {
                _ = try NotesImport.parse(csv)
                throw TestFailure.failed("Accepted invalid CSV: \(csv)")
            } catch is NotesImportError {}
        }
    }

    private static func testNotesImportMatching() throws {
        let document = ReaderDocument(title: "matching.txt", text: "最初。重複。重複。最後。")
        let imported = [
            ImportedNote(id: 2, sentenceIndex: 0, sentence: "最後。", text: "moved", updatedAt: nil),
            ImportedNote(id: 3, sentenceIndex: 0, sentence: "重複。", text: "ambiguous", updatedAt: nil),
            ImportedNote(id: 4, sentenceIndex: 2, sentence: "重複。", text: "exact", updatedAt: nil),
            ImportedNote(id: 5, sentenceIndex: 0, sentence: "変更前。", text: "missing", updatedAt: nil),
        ]
        var plan = NoteImportPlan(document: document, notes: [], unattached: [], imported: imported)
        try require(plan.items.map(\.match) == [.moved, .ambiguous, .exact, .missing], "Text was not checked before matching")
        try require(plan.items.map(\.targetIndex) == [3, nil, 2, nil] && !plan.canImport, "Ambiguous or missing text was guessed")
        plan.items[1].assignment = .sentence(1)
        plan.items[3].assignment = .skip
        try require(plan.canImport, "Resolved plan was rejected")
        plan.items[1].assignment = .sentence(2)
        try require(!plan.canImport && plan.hasDuplicateTarget(plan.items[1]), "Duplicate destinations were accepted")
        plan.items[1].assignment = .sentence(100)
        try require(!plan.canImport, "Out-of-range destination was accepted")

        let existing = SentenceNote(sentenceIndex: 3, sentence: "最後。", text: "original", updatedAt: Date())
        var conflict = NoteImportPlan(document: document, notes: [existing], unattached: [], imported: [imported[0]])
        try require(!conflict.canImport && conflict.needsReplacementConfirmation(conflict.items[0]), "Existing note would be silently overwritten")
        conflict.items[0].replacesExisting = true
        try require(conflict.canImport, "Confirmed replacement was rejected")
        conflict.items[0].assignment = .skip
        try require(!conflict.canImport, "All-skipped import should be disabled")
    }
}
