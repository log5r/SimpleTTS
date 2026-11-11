import Foundation

private enum PrivacyTestFailure: Error { case failed(String) }

/// Deliberately continues until released, even after cancellation, to model a late file write.
private actor SynthesisGate {
    private var continuations: [String: CheckedContinuation<Void, Never>] = [:]

    func wait(_ name: String) async {
        await withCheckedContinuation { continuations[name] = $0 }
    }

    func entered(_ name: String) -> Bool { continuations[name] != nil }
    func release(_ name: String) { continuations.removeValue(forKey: name)?.resume() }
}

/// The real player and model are compiled with this synthetic engine; tests never play audio or run say.
nonisolated enum SpeechSynthesizer {
    static let sampleRate: Double = 48_000
    fileprivate static let gate = SynthesisGate()

    static func availableVoices() async -> [SpeechVoice] { [] }

    static func synthesize(_ request: SpeechRequest, to url: URL) async throws {
        await gate.wait(request.text)
        try Data("synthetic audio fixture".utf8).write(to: url)
    }
}

@MainActor
private final class PrivacyFixture {
    let root: URL
    let storageURL: URL
    let audioURL: URL
    let sourceURL: URL
    let defaults: UserDefaults
    let defaultsSuite = "SimpleTTS-PrivacyTests-\(UUID().uuidString)"
    let text = "保存を確認するための合成文です。次の文も合成文です。"

    var documentURL: URL {
        storageURL.appending(path: "Documents/\(ReaderDocument.digest(of: text)).txt")
    }
    var savesURL: URL { storageURL.appending(path: "saves.json") }
    var notesURL: URL {
        storageURL.appending(path: "Notes/\(ReaderDocument.notesID(for: sourceURL)).json")
    }
    var currentAudioURL: URL { audioURL.appending(path: "Speech-\(ProcessInfo.processInfo.processIdentifier)") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "SimpleTTS-PrivacyTests-\(UUID().uuidString)")
        storageURL = root.appending(path: "Storage")
        audioURL = root.appending(path: "Audio")
        sourceURL = root.appending(path: "fixture.txt")
        defaults = UserDefaults(suiteName: defaultsSuite)!
        defaults.removePersistentDomain(forName: defaultsSuite)
        try FileManager.default.createDirectory(at: audioURL, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: sourceURL)
    }

    func model() -> ReaderModel {
        ReaderModel(storage: Storage(baseURL: storageURL), speaker: SpeechPlayer(temporaryDirectory: audioURL),
                    defaults: defaults, loadsVoices: false)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: root)
    }
}

@main
struct ReaderModelPrivacyTests {
    @MainActor
    static func main() async throws {
        try await privateReadingDoesNotPersist()
        try await retainedReadingRestoresOnlyWhenEnabled()
        try await completeErasureSurvivesLifecycleCallbacks()
        try await mediaErasureWaitsForEveryWriter()
        try await mediaCacheRecreatesAfterWindowClose()
        try await notesFollowTheDocument()
        try await notesAreIndependentPerFile()
        try await notesRespectPrivacyAndErasure()
        try await unattachedNotesAreListedAndDeletable()
        try await legacySavesKeepPositionAndNotes()
        try await searchFindsAndJumpsToSentences()
        print("PASS: private reading, opt-in transitions, session restore, complete erasure, lifecycle callbacks, audio cleanup races, window reopening, sentence notes, and sentence search")
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw PrivacyTestFailure.failed(message) }
    }

    @MainActor
    private static func privateReadingDoesNotPersist() async throws {
        let fixture = try PrivacyFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        try require(model.retainsDocuments, "Normal saving must remain enabled by default")
        try require(!model.showsDocumentNameOnLockScreen, "Document names must be hidden by default")
        model.retainsDocuments = false
        await model.openFile(at: fixture.sourceURL)
        try require(model.document != nil && model.errorMessage == nil, "Private document did not open")
        try require(!model.canSaveManually, "Private document enabled manual saving")
        model.saveManually()
        model.saveProgress()
        model.prepareForTermination()
        try require(!FileManager.default.fileExists(atPath: fixture.documentURL.path), "Private body was stored")
        try require(!FileManager.default.fileExists(atPath: fixture.savesURL.path), "Private history was stored")
        try require(model.saves.isEmpty, "Private history leaked into the model")

        // Turning saving on must not retroactively retain a document opened privately.
        model.retainsDocuments = true
        model.saveProgress()
        model.saveManually()
        model.prepareForTermination()
        try require(!model.canSaveManually, "Opt-in retroactively enabled saving of a private document")
        try require(!FileManager.default.fileExists(atPath: fixture.documentURL.path), "Opt-in retroactively wrote the body")
        try require(!FileManager.default.fileExists(atPath: fixture.savesURL.path), "Opt-in retroactively wrote history")

        await model.openFile(at: fixture.sourceURL)
        model.saveProgress()
        try require(model.canSaveManually, "Explicit reopening did not enable saving")
        try require(FileManager.default.fileExists(atPath: fixture.documentURL.path), "Reopened body not stored")
        try require(Storage(baseURL: fixture.storageURL).loadSaves().count == 1, "Reopened document not autosaved")
    }

    @MainActor
    private static func retainedReadingRestoresOnlyWhenEnabled() async throws {
        let fixture = try PrivacyFixture()
        defer { fixture.cleanUp() }
        let original = fixture.model()
        await original.openFile(at: fixture.sourceURL)
        original.jump(to: 1)
        original.saveProgress()
        original.saveManually()
        try require(original.saves.count == 2, "Normal manual and automatic saving failed")

        original.retainsDocuments = false
        let privateStartup = fixture.model()
        try require(privateStartup.document == nil, "Retention-off startup restored a private document")
        try require(privateStartup.saves.count == 2, "Disabling retention unexpectedly deleted existing saves")
        privateStartup.saveProgress()
        privateStartup.prepareForTermination()

        privateStartup.retainsDocuments = true
        let restored = fixture.model()
        try require(restored.document?.id == ReaderDocument.digest(of: fixture.text), "Normal session did not restore")
        try require(restored.currentIndex == 1, "Restored reading position changed")
        try require(restored.currentSentence == "次の文も合成文です。", "Restored document text changed")
    }

    @MainActor
    private static func completeErasureSurvivesLifecycleCallbacks() async throws {
        let fixture = try PrivacyFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        await model.openFile(at: fixture.sourceURL)
        model.saveProgress()
        model.saveManually()
        let quarantined = fixture.storageURL.appending(path: "saves.corrupted-fixture.json")
        try Data("private recovery fixture".utf8).write(to: quarantined)
        try Data("private audio fixture".utf8).write(to: fixture.currentAudioURL.appending(path: "fixture.wav"))

        await model.deleteAllStoredData()
        try require(model.document == nil && model.saves.isEmpty && !model.isPlaying, "Erasure retained current state")
        try require(!model.isBusy && model.dataDeletionError == nil && model.dataDeletionMessage != nil,
                    "Successful deletion was not reported")
        try require(!FileManager.default.fileExists(atPath: quarantined.path), "Recovery backup survived erasure")
        try require(!FileManager.default.fileExists(atPath: fixture.documentURL.path), "Body survived erasure")
        try require(!FileManager.default.fileExists(atPath: fixture.savesURL.path), "History survived erasure")
        try require(FileManager.default.contentsOfDirectory(atPath: fixture.currentAudioURL.path).isEmpty,
                    "Generated audio survived erasure")
        try require(String(contentsOf: fixture.sourceURL, encoding: .utf8) == fixture.text, "Erasure modified the source file")

        model.saveProgress()
        model.saveManually()
        model.prepareForTermination()
        try require(!FileManager.default.fileExists(atPath: fixture.savesURL.path), "Lifecycle callback recreated deleted history")
        try require(!FileManager.default.fileExists(atPath: fixture.documentURL.path), "Lifecycle callback recreated deleted body")
        let relaunched = fixture.model()
        try require(relaunched.document == nil && relaunched.saves.isEmpty, "Deleted document restored at next launch")
        await relaunched.openFile(at: fixture.sourceURL)
        relaunched.saveProgress()
        try require(Storage(baseURL: fixture.storageURL).loadSaves().count == 1, "Saving stopped working after erasure")
    }

    @MainActor
    private static func mediaErasureWaitsForEveryWriter() async throws {
        let fixture = try PrivacyFixture()
        defer { fixture.cleanUp() }
        let player = SpeechPlayer(temporaryDirectory: fixture.audioURL)
        player.prefetch("retiring", voice: nil)
        try await waitForWorker("retiring")
        player.prefetch("active", voice: nil)
        try await waitForWorker("active")
        var completed = false
        let firstClear = Task { @MainActor in
            try await player.clearTemporaryFiles()
            completed = true
        }
        try await Task.sleep(for: .milliseconds(20))
        let secondClear = Task { try await player.clearTemporaryFiles() }
        player.prefetch("must not start", voice: nil)
        let unwantedStarted = await SpeechSynthesizer.gate.entered("must not start")
        try require(!unwantedStarted && !completed, "New work was accepted or erase returned before synthesis finished")
        await SpeechSynthesizer.gate.release("active")
        try await Task.sleep(for: .milliseconds(20))
        try require(!completed, "Erasure did not wait for an already-retiring synthesis")
        await SpeechSynthesizer.gate.release("retiring")
        try await firstClear.value
        try await secondClear.value
        try require(FileManager.default.contentsOfDirectory(atPath: fixture.currentAudioURL.path).isEmpty,
                    "Canceled synthesis wrote audio after erasure")
    }

    private static func waitForWorker(_ name: String) async throws {
        for _ in 0..<400 {
            if await SpeechSynthesizer.gate.entered(name) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw PrivacyTestFailure.failed("Synthetic worker did not start: \(name)")
    }

    @MainActor
    private static func mediaCacheRecreatesAfterWindowClose() async throws {
        let fixture = try PrivacyFixture()
        defer { fixture.cleanUp() }
        let player = SpeechPlayer(temporaryDirectory: fixture.audioURL)
        player.removeTemporaryFiles()
        try require(!FileManager.default.fileExists(atPath: fixture.currentAudioURL.path),
                    "Window-close fixture did not remove the audio directory")

        // A Settings window can keep the model alive while the reader window is closed and reopened.
        player.prefetch("window-reopen", voice: nil)
        try await waitForWorker("window-reopen")
        await SpeechSynthesizer.gate.release("window-reopen")
        var audioWasWritten = false
        for _ in 0..<400 {
            if (try? FileManager.default.contentsOfDirectory(atPath: fixture.currentAudioURL.path).count) == 1 {
                audioWasWritten = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        try require(audioWasWritten, "Reopening a window did not recreate the audio cache")
        try await player.clearTemporaryFiles()
        try require(FileManager.default.contentsOfDirectory(atPath: fixture.currentAudioURL.path).isEmpty,
                    "Reopened audio cache could not be cleared")
    }

    @MainActor
    private static func notesFollowTheDocument() async throws {
        let fixture = try PrivacyFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        await model.openFile(at: fixture.sourceURL)
        try require(model.canEditNotes && model.notes.isEmpty, "A saved document should accept notes")

        model.beginEditingNote()
        guard let first = model.noteEditorRequest else { throw PrivacyTestFailure.failed("Note editor did not open") }
        try require(first.sentenceIndex == 0 && first.isNew, "Editor did not target the current sentence")
        try model.saveNote("  一行目\n二行目\n  ", for: first)
        try require(model.currentNote?.text == "一行目\n二行目", "Multi-line note was not saved")
        try require(FileManager.default.fileExists(atPath: fixture.notesURL.path), "Note was not written to disk")

        // 編集中に読み上げ位置が変わっても、編集を始めた文に保存する
        model.jump(to: 1)
        try model.saveNote("一行目\n二行目（修正）", for: first)
        try require(model.note(at: 0)?.text == "一行目\n二行目（修正）" && model.note(at: 1) == nil,
                    "Note was saved to the wrong sentence")
        guard let second = model.makeNoteEditorRequest(at: 1) else { throw PrivacyTestFailure.failed("No request") }
        try model.saveNote("二文目のメモ", for: second)
        let firstDate = model.note(at: 0)!.updatedAt
        try model.saveNote("一行目\n二行目（修正）", for: model.makeNoteEditorRequest(at: 0)!)
        try require(model.note(at: 0)?.updatedAt == firstDate, "Unchanged note updated its date")

        let csv = String(decoding: model.exportedNotes(format: .csv).dropFirst(3), as: UTF8.self)
        try require(csv.contains("\"一行目\n二行目（修正）\"") && csv.contains("二文目のメモ"), "Export lacked notes")

        // 開き直すと（再起動後も）同じメモが読み込まれる
        model.saveProgress()
        let relaunched = fixture.model()
        try require(relaunched.notes.map(\.text) == ["一行目\n二行目（修正）", "二文目のメモ"], "Restored session lost notes")
        let reopened = fixture.model()
        await reopened.openFile(at: fixture.sourceURL)
        try require(reopened.notes.count == 2, "Reopening the file did not load notes")

        // 別の文書を開いた後は、古い編集内容を保存しない
        let otherURL = fixture.root.appending(path: "other.txt")
        try Data("別の文書の文です。".utf8).write(to: otherURL)
        await model.openFile(at: otherURL)
        try require(model.notes.isEmpty, "Notes leaked to another document")
        do {
            try model.saveNote("混ざってはいけない", for: second)
            throw PrivacyTestFailure.failed("Stale note request was saved to another document")
        } catch NoteEditingError.documentClosed {}

        // 空にすると削除され、最後の 1 件を消すとファイルも消える
        await model.openFile(at: fixture.sourceURL)
        try model.saveNote(" \n ", for: model.makeNoteEditorRequest(at: 1)!)
        try model.deleteNote(at: 0, documentID: model.document!.notesID)
        try require(model.notes.isEmpty, "Notes were not deleted")
        try require(!FileManager.default.fileExists(atPath: fixture.notesURL.path), "Empty notes file was kept")
    }

    @MainActor
    private static func notesAreIndependentPerFile() async throws {
        let fixture = try PrivacyFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        await model.openFile(at: fixture.sourceURL)
        let request = model.makeNoteEditorRequest(at: 0)!
        try model.saveNote("original", for: request)
        let copy = fixture.root.appending(path: "copy.txt")
        try Data(fixture.text.utf8).write(to: copy)
        await model.openFile(at: copy)
        try require(model.notes.isEmpty, "Identical files shared notes")
        do {
            try model.saveNote("wrong file", for: request)
            throw PrivacyTestFailure.failed("Identical file accepted stale editor")
        } catch NoteEditingError.documentClosed {}
        try model.saveNote("copy", for: model.makeNoteEditorRequest(at: 0)!)
        model.saveProgress()
        let restoredCopy = fixture.model()
        try require(restoredCopy.notes.first?.text == "copy", "Restoring identical content used another file's notes")
        await model.openFile(at: fixture.sourceURL)
        try require(model.notes.first?.text == "original", "Original notes were overwritten")
        try Data(("追加文。" + fixture.text).utf8).write(to: fixture.sourceURL)
        await model.openFile(at: fixture.sourceURL)
        try require(model.note(at: 1)?.text == "original" && model.note(at: 0) == nil,
                    "Edited file did not reattach matching sentence")
        try Data("置き換えた文。".utf8).write(to: fixture.sourceURL)
        await model.openFile(at: fixture.sourceURL)
        try require(model.notes.isEmpty, "Missing sentence attached to unrelated text")
        try require(model.noteListEntries.map(\.text) == ["original"] && model.noteListEntries[0].sentenceIndex == nil,
                    "Unattached note was not listed")
        try model.saveNote("replacement", for: model.makeNoteEditorRequest(at: 0)!)
        try Data(fixture.text.utf8).write(to: fixture.sourceURL)
        await model.openFile(at: fixture.sourceURL)
        try require(model.note(at: 0)?.text == "original", "Unattached note was lost on save")
    }

    @MainActor
    private static func unattachedNotesAreListedAndDeletable() async throws {
        let fixture = try PrivacyFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        await model.openFile(at: fixture.sourceURL)
        try model.saveNote("消える文のメモ", for: model.makeNoteEditorRequest(at: 0)!)
        try model.saveNote("=1+1", for: model.makeNoteEditorRequest(at: 1)!)
        try Data("次の文も合成文です。新しい文です。".utf8).write(to: fixture.sourceURL)
        await model.openFile(at: fixture.sourceURL)

        let entries = model.noteListEntries
        try require(entries.map(\.sentenceIndex) == [0, nil], "Moved and missing notes were not listed in order")
        try require(model.currentNote?.text == "=1+1" && model.note(at: 1) == nil,
                    "Unattached note appeared on the reader")
        let csv = String(decoding: model.exportedNotes(format: .csv).dropFirst(3), as: UTF8.self)
        try require(csv.contains("\r\n1,次の文も合成文です。,'=1+1,") && csv.contains("\r\n,保存を確認するための合成文です。,消える文のメモ,"),
                    "Export lacked the unattached note or formula protection: \(csv.debugDescription)")

        let documentID = model.document!.notesID
        try model.deleteNote(entries[1], documentID: documentID)
        try require(model.noteListEntries.map(\.text) == ["=1+1"], "Unattached note was not deleted")
        let reopened = fixture.model()
        await reopened.openFile(at: fixture.sourceURL)
        try require(reopened.noteListEntries.map(\.text) == ["=1+1"], "Deleted unattached note came back")

        // 読み込めない状態では削除できない
        model.retainsDocuments = false
        do {
            try model.deleteNote(model.noteListEntries[0], documentID: documentID)
            throw PrivacyTestFailure.failed("Note was deleted while saving was off")
        } catch NoteEditingError.notEditable {}
    }

    /// メモ機能より前のセーブ（notesID なし）でも、ファイルを開くと位置を再開でき、
    /// そのセーブから復元した文書で書いたメモもファイルに引き継ぐ。
    @MainActor
    private static func legacySavesKeepPositionAndNotes() async throws {
        let fixture = try PrivacyFixture()
        defer { fixture.cleanUp() }
        let first = fixture.model()
        await first.openFile(at: fixture.sourceURL)
        first.jump(to: 1)
        first.saveProgress()
        let data = try Data(contentsOf: fixture.savesURL)
        var saves = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        for index in saves.indices { saves[index].removeValue(forKey: "notesID") }
        try JSONSerialization.data(withJSONObject: saves).write(to: fixture.savesURL)

        let restored = fixture.model()
        try require(restored.document?.notesAreKeyedByContent == true && restored.currentIndex == 1,
                    "Legacy session was not restored")
        try restored.saveNote("場所の分からないメモ", for: restored.makeNoteEditorRequest(at: 1)!)
        let contentKeyedURL = fixture.storageURL.appending(path: "Notes/\(ReaderDocument.digest(of: fixture.text)).json")
        try require(FileManager.default.fileExists(atPath: contentKeyedURL.path), "Content-keyed note was not saved")

        await restored.openFile(at: fixture.sourceURL)
        try require(restored.currentIndex == 1, "Legacy autosave position was not resumed")
        try require(restored.note(at: 1)?.text == "場所の分からないメモ", "Content-keyed note was not adopted")
        try require(FileManager.default.fileExists(atPath: fixture.notesURL.path)
                    && !FileManager.default.fileExists(atPath: contentKeyedURL.path),
                    "Adopted note was not moved to the file's notes")
        restored.saveProgress()
        try require(restored.autoSaves.count == 1 && restored.autoSaves[0].notesID == ReaderDocument.notesID(for: fixture.sourceURL),
                    "Legacy autosave was duplicated instead of replaced")

        // 同じ本文の別のファイルには付けない
        let copy = fixture.root.appending(path: "copy.txt")
        try Data(fixture.text.utf8).write(to: copy)
        await restored.openFile(at: copy)
        try require(restored.noteListEntries.isEmpty, "Adopted note leaked to another file")
    }

    private static func notesRespectPrivacyAndErasure() async throws {
        let fixture = try PrivacyFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        model.retainsDocuments = false
        await model.openFile(at: fixture.sourceURL)
        try require(!model.canEditNotes && model.makeNoteEditorRequest(at: 0) == nil,
                    "Private document accepted notes")
        model.beginEditingNote()
        try require(model.noteEditorRequest == nil, "Private document opened the note editor")

        model.retainsDocuments = true
        await model.openFile(at: fixture.sourceURL)
        try model.saveNote("消されるメモ", for: model.makeNoteEditorRequest(at: 0)!)
        model.retainsDocuments = false
        try require(!model.canEditNotes, "Disabling saving kept notes editable")
        try require(model.notes.count == 1, "Existing notes should stay visible")

        model.retainsDocuments = true
        model.isNotesListPresented = true
        await model.deleteAllStoredData()
        try require(model.notes.isEmpty && !model.isPresentingNotes, "Erasure kept notes on screen")
        try require(!FileManager.default.fileExists(atPath: fixture.notesURL.path), "Notes survived erasure")
        await model.openFile(at: fixture.sourceURL)
        try require(model.notes.isEmpty && model.canEditNotes, "Erased notes came back")

        // 壊れたメモは退避して、新しいメモを書けるようにする
        try Data("broken".utf8).write(to: fixture.notesURL)
        let recovered = fixture.model()
        await recovered.openFile(at: fixture.sourceURL)
        try require(recovered.errorMessage != nil && recovered.canEditNotes, "Corrupted notes were not reported")
        let backups = try FileManager.default.contentsOfDirectory(atPath: fixture.notesURL.deletingLastPathComponent().path)
            .filter { $0.contains(".corrupted-") }
        try require(backups.count == 1, "Corrupted notes were not quarantined")
    }

    @MainActor
    private static func searchFindsAndJumpsToSentences() async throws {
        let fixture = try PrivacyFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        model.beginSearch()
        try require(model.searchFocusRequest == 0, "Search was requested without a document")
        model.searchQuery = "合成"
        try require(model.isSearching && model.searchResults.isEmpty, "Search without a document returned results")

        await model.openFile(at: fixture.sourceURL)
        model.beginSearch()
        model.beginSearch()
        try require(model.searchFocusRequest == 2, "Repeated Find commands were ignored")
        try await waitForSearch(model)
        try require(model.searchResults.map(\.sentenceIndex) == [0, 1], "Opening a document did not re-run the search")
        model.searchQuery = "  次の  "
        try await waitForSearch(model)
        try require(model.searchResults.map(\.sentenceIndex) == [1] && model.searchMatchCount == 1, "Partial match failed")
        model.goToSearchResult(model.searchResults[0])
        try require(model.currentIndex == 1, "Choosing a result did not move to the sentence")

        model.searchQuery = "   "
        try require(!model.isSearching && model.searchResults.isEmpty, "A blank query was searched")
        model.searchQuery = "存在しない語"
        try await waitForSearch(model)
        try require(model.searchResults.isEmpty && model.searchMatchCount == 0, "A missing word matched")

        // 入力の連続変更では最後の語だけを反映し、古い結果を選べないようにする。
        model.searchQuery = "合成"
        model.searchQuery = "次の"
        try require(model.isSearchPending && model.searchResults.isEmpty, "Stale results remained selectable")
        try await waitForSearch(model)
        try require(model.searchResults.map(\.sentenceIndex) == [1], "An older query replaced the latest results")
        let oldResult = model.searchResults[0]

        // 大きな文書の走査中でも MainActor から入力を変更できる。文書切り替え・消去後に結果を復活させない。
        let largeURL = fixture.root.appending(path: "large.txt")
        try Data(String(repeating: "検索速度を確認する文章です。", count: 200_000).utf8).write(to: largeURL)
        await model.openFile(at: largeURL)
        model.searchQuery = "文章"
        try await Task.sleep(for: .milliseconds(180))
        model.searchQuery = "次の"
        await model.openFile(at: fixture.sourceURL)
        try await waitForSearch(model)
        try require(model.searchResults.map(\.sentenceIndex) == [1], "Results from the previous document were published")

        model.searchQuery = "合成"
        model.searchQuery = ""
        try await Task.sleep(for: .milliseconds(250))
        try require(!model.isSearchPending && model.searchResults.isEmpty, "Clearing search allowed a late result")
        model.searchQuery = "合成"
        await model.deleteAllStoredData()
        try await Task.sleep(for: .milliseconds(250))
        try require(!model.isSearchPending && model.searchResults.isEmpty, "Erasure allowed a late search result")
        model.goToSearchResult(oldResult)
        try require(model.currentIndex == 0, "A stale result moved a closed document")

        // Case and width are ignored; voiced marks are not.
        let sentences = ["Hello World.", "ＨＥＬＬＯ again.", "ｶﾀｶﾅ と カタカナ。", "はし と ばし。"]
        try require(SentenceSearch.search("hello", in: sentences).results.map(\.sentenceIndex) == [0, 1], "Case or width folding failed")
        try require(SentenceSearch.matchRanges(of: "カタカナ", in: sentences[2]).count == 2, "Half-width katakana did not match")
        try require(SentenceSearch.matchRanges(of: "ば", in: sentences[3]).count == 1, "Voiced marks were ignored")
        let capped = SentenceSearch.search("a", in: Array(repeating: "a", count: 5), limit: 3)
        try require(capped.results.count == 3 && capped.totalCount == 5, "Result limit was not applied")
    }

    @MainActor
    private static func waitForSearch(_ model: ReaderModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.isSearchPending, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(!model.isSearchPending, "Search did not finish")
    }
}
