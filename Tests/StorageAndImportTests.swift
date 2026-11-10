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
        print("PASS: local text validation, size limits, encodings, storage recovery, backup exclusion, and complete erasure")
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
        try require(files == ["Documents"], "Explicit erase must also clear quarantined files")
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
}
