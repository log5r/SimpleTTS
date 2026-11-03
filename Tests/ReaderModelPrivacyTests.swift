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
        print("PASS: private reading, opt-in transitions, session restore, complete erasure, lifecycle callbacks, audio cleanup races, and window reopening")
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
}
