import Foundation
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 前後の文脈として表示する文
nonisolated struct ContextSentence: Identifiable, Hashable, Sendable {
    /// 文書内の文番号（0 始まり）
    let id: Int
    let text: String
}

/// 読み上げ・セーブ・コピーなどアプリ全体の状態を管理する。
@Observable
final class ReaderModel {
    static let manualSaveLimit = 100
    /// オートセーブは文書ごとに 1 件。保持する文書数の上限。
    static let autoSaveLimit = 30
    /// 現在の文の前後に表示する文の数
    static let contextCount = 3
    /// 読み上げ速度の範囲と刻み（声の標準の速さに対する倍率）
    static let rateRange: ClosedRange<Double> = 0.5...2.0
    static let rateStep = 0.1

    private enum DefaultsKey {
        /// 速度の倍率。以前は `say -r` の語/分を "speechRate" に保存していたが、意味が違うので別のキーにする。
        static let rate = "speechRateMultiplier"
        static let voice = "voiceName"
        static let retainsDocuments = "retainsDocuments"
        static let showsDocumentNameOnLockScreen = "showsDocumentNameOnLockScreen"
    }

    private(set) var document: ReaderDocument? {
        didSet { playbackStateDidChange() }
    }
    private(set) var currentIndex = 0 {
        didSet { playbackStateDidChange() }
    }
    private(set) var isPlaying = false {
        didSet { playbackStateDidChange() }
    }
    private(set) var saves: [SavePoint] = []
    private(set) var voices: [SpeechVoice] = []
    private(set) var statusMessage: String?
    private(set) var isLoading = false {
        didSet { playbackStateDidChange() }
    }
    private(set) var isClearingData = false {
        didSet { playbackStateDidChange() }
    }
    private(set) var dataDeletionMessage: String?
    private(set) var dataDeletionError: String?
    var errorMessage: String?
    var isImporterPresented = false

    private var storedVoice: String?
    private var storedRate: Double
    private var storedRetainsDocuments: Bool
    private var storedShowsDocumentNameOnLockScreen: Bool
    private var currentDocumentIsStored = false

    @ObservationIgnored private let speaker: SpeechPlayer
    @ObservationIgnored private let storage: Storage
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var lifecycleGeneration = 0
    @ObservationIgnored private var reachedEnd = false
    #if os(iOS)
    /// 電話などの割り込みで止めたか。割り込みが終わったら読み上げを再開するために使う。
    @ObservationIgnored private var resumesAfterInterruption = false
    @ObservationIgnored private lazy var nowPlaying = NowPlayingController(actions: .init(
        play: { [weak self] in self?.play() },
        pause: { [weak self] in self?.stop() },
        togglePlayPause: { [weak self] in self?.togglePlayback() },
        next: { [weak self] in self?.step(by: 1) },
        previous: { [weak self] in self?.step(by: -1) }
    ))
    #endif

    /// 読み上げに使う声（`SpeechVoice.id`、nil ならシステム既定）。読み上げ中に変えると次の文から反映される。
    var selectedVoice: String? {
        get { storedVoice }
        set {
            storedVoice = newValue
            defaults.set(newValue, forKey: DefaultsKey.voice)
            prefetchNextSentence()
        }
    }

    /// 読み上げ速度（声の標準の速さに対する倍率）。読み上げ中に変えるとすぐ反映される。
    var rate: Double {
        get { storedRate }
        set {
            storedRate = Self.normalizedRate(newValue)
            defaults.set(storedRate, forKey: DefaultsKey.rate)
            speaker.playbackRate = Float(storedRate)
        }
    }

    /// オフにすると、新しい本文と読み上げ位置を保存しない。既存データは明示的な削除まで保持する。
    var retainsDocuments: Bool {
        get { storedRetainsDocuments }
        set {
            storedRetainsDocuments = newValue
            defaults.set(newValue, forKey: DefaultsKey.retainsDocuments)
        }
    }

    var showsDocumentNameOnLockScreen: Bool {
        get { storedShowsDocumentNameOnLockScreen }
        set {
            storedShowsDocumentNameOnLockScreen = newValue
            defaults.set(newValue, forKey: DefaultsKey.showsDocumentNameOnLockScreen)
            playbackStateDidChange()
        }
    }

    init(storage: Storage = Storage(), speaker: SpeechPlayer = SpeechPlayer(),
         defaults: UserDefaults = .standard, loadsVoices: Bool = true) {
        self.storage = storage
        self.speaker = speaker
        self.defaults = defaults
        storedVoice = defaults.string(forKey: DefaultsKey.voice)
        let savedRate = defaults.double(forKey: DefaultsKey.rate)
        storedRate = savedRate > 0 ? Self.normalizedRate(savedRate) : 1
        storedRetainsDocuments = defaults.object(forKey: DefaultsKey.retainsDocuments) as? Bool ?? true
        storedShowsDocumentNameOnLockScreen = defaults.bool(forKey: DefaultsKey.showsDocumentNameOnLockScreen)
        speaker.playbackRate = Float(storedRate)

        do {
            saves = try storage.loadSaves()
            // 正常に読み込めたときだけ、参照されていない本文キャッシュを整理する
            storage.removeDocuments(notReferencedBy: Set(saves.map(\.documentID)))
        } catch {
            saves = []
            errorMessage = Self.loadFailureMessage(for: error)
        }
        if retainsDocuments { restoreLastSession() }

        #if os(iOS)
        speaker.onAudioSessionEvent = { [weak self] event in
            self?.handleAudioSessionEvent(event)
        }
        #endif

        if loadsVoices {
            Task { [weak self] in
                let voices = await SpeechSynthesizer.availableVoices()
                self?.voices = voices
            }
        }
    }

    // MARK: - Derived state

    var autoSaves: [SavePoint] {
        saves.filter { $0.kind == .auto }.sorted { $0.createdAt > $1.createdAt }
    }

    var manualSaves: [SavePoint] {
        saves.filter { $0.kind == .manual }.sorted { $0.createdAt > $1.createdAt }
    }

    var sentenceCount: Int { document?.sentences.count ?? 0 }

    /// 選んでいる声の表示名（nil ならシステム既定の声）
    var selectedVoiceName: String? {
        guard let selectedVoice else { return nil }
        return voices.first { $0.id == selectedVoice }?.name ?? selectedVoice
    }

    var currentSentence: String? {
        guard let document, document.sentences.indices.contains(currentIndex) else { return nil }
        return document.sentences[currentIndex]
    }

    var previousContext: [ContextSentence] {
        guard let document, currentIndex > 0 else { return [] }
        let lower = max(0, currentIndex - Self.contextCount)
        return (lower..<currentIndex).map { ContextSentence(id: $0, text: document.sentences[$0]) }
    }

    var nextContext: [ContextSentence] {
        guard let document, currentIndex + 1 < document.sentences.count else { return [] }
        let upper = min(document.sentences.count, currentIndex + 1 + Self.contextCount)
        return (currentIndex + 1..<upper).map { ContextSentence(id: $0, text: document.sentences[$0]) }
    }

    var isBusy: Bool { isLoading || isClearingData }
    var savesCurrentDocument: Bool { retainsDocuments && currentDocumentIsStored }
    var canStepBackward: Bool { !isBusy && document != nil && currentIndex > 0 }
    var canStepForward: Bool { !isBusy && currentIndex + 1 < sentenceCount }
    /// 任意セーブは停止中のみ
    var canSaveManually: Bool { !isBusy && document != nil && !isPlaying && savesCurrentDocument }
    /// コピーは停止（一時停止）中のみ
    var canCopy: Bool { !isBusy && currentSentence != nil && !isPlaying }

    // MARK: - File

    func openFile(at url: URL) async {
        guard !isBusy else { return }
        isLoading = true
        defer { isLoading = false }
        let generation = lifecycleGeneration
        let text: String
        let newDocument: ReaderDocument
        do {
            (text, newDocument) = try await Task.detached(priority: .userInitiated) {
                let text = try TextFileLoader.read(from: url)
                return (text, ReaderDocument(title: url.lastPathComponent, text: text))
            }.value
        } catch {
            if generation == lifecycleGeneration {
                errorMessage = "Could not open the file: \(error.localizedDescription)"
            }
            return
        }
        guard generation == lifecycleGeneration else { return }
        guard !newDocument.sentences.isEmpty else {
            errorMessage = "“\(url.lastPathComponent)” has no text to read aloud."
            return
        }

        // 読み上げ中なら止めて、それまでの文書の位置をオートセーブする
        stop()

        currentDocumentIsStored = false
        if retainsDocuments {
            do {
                try storage.storeDocumentText(text, id: newDocument.id)
                currentDocumentIsStored = true
            } catch {
                errorMessage = "Could not store the document text. History will not be saved for this document: \(error.localizedDescription)"
            }
        }
        document = newDocument
        reachedEnd = false
        if retainsDocuments, let autosave = autoSaves.first(where: { $0.documentID == newDocument.id }) {
            currentIndex = clampedIndex(autosave.sentenceIndex, in: newDocument)
            statusMessage = "Ready to resume at sentence \(currentIndex + 1)."
        } else {
            currentIndex = 0
            statusMessage = "Opened “\(newDocument.title)”. Total sentences: \(newDocument.sentences.count)."
        }
    }

    // MARK: - Playback

    func togglePlayback() {
        #if os(iOS)
        // 利用者が操作したら、割り込み後の自動再開はしない
        resumesAfterInterruption = false
        #endif
        if isPlaying {
            stop()
        } else {
            play()
        }
    }

    func play() {
        guard !isBusy, let document, !document.sentences.isEmpty, !isPlaying else { return }
        if reachedEnd {
            currentIndex = 0
            reachedEnd = false
        }
        isPlaying = true
        statusMessage = nil
        speakCurrentSentence()
    }

    /// 読み上げを止め、その位置をオートセーブする。
    func stop() {
        guard isPlaying else { return }
        speaker.stop()
        isPlaying = false
        do {
            try autosave()
            statusMessage = "Paused at sentence \(currentIndex + 1)."
                + (savesCurrentDocument ? " Position auto-saved." : " History will not be saved.")
        } catch {
            statusMessage = "Paused at sentence \(currentIndex + 1)."
            reportError("Playback paused, but the position could not be auto-saved: \(error.localizedDescription)")
        }
    }

    func step(by delta: Int) {
        jump(to: currentIndex + delta)
    }

    /// 指定した文へ移動する。読み上げ中ならその文から読み直す。
    func jump(to index: Int) {
        guard !isBusy, let document, document.sentences.indices.contains(index) else { return }
        reachedEnd = false
        currentIndex = index
        if isPlaying {
            speakCurrentSentence()
        }
    }

    private func speakCurrentSentence() {
        guard isPlaying, let sentence = currentSentence else { return }
        speaker.speak(sentence, voice: selectedVoice) { [weak self] result in
            self?.sentenceDidFinish(result)
        }
        // 読んでいる間に次の文を合成しておき、文間の待ち時間を短くする
        prefetchNextSentence()
    }

    /// 次の文があれば、現在の声で先に合成しておく（読み上げ中のみ）。
    private func prefetchNextSentence() {
        guard isPlaying, let document, document.sentences.indices.contains(currentIndex + 1) else { return }
        speaker.prefetch(document.sentences[currentIndex + 1], voice: selectedVoice)
    }

    private func sentenceDidFinish(_ result: Result<Void, Error>) {
        guard isPlaying else { return }
        if case let .failure(error) = result {
            isPlaying = false
            reportError("Could not read aloud: \(error.localizedDescription)" + autosaveResultSuffix())
            return
        }
        if currentIndex + 1 < sentenceCount {
            currentIndex += 1
            speakCurrentSentence()
        } else {
            isPlaying = false
            reachedEnd = true
            do {
                try autosave()
                statusMessage = "Finished reading. Press Play to start again from the beginning."
            } catch {
                statusMessage = "Finished reading."
                reportError("Finished reading, but the position could not be auto-saved: \(error.localizedDescription)")
            }
        }
    }

    /// オートセーブを試み、その結果をエラーメッセージの末尾に付ける文言で返す。
    private func autosaveResultSuffix() -> String {
        guard savesCurrentDocument else { return " (History will not be saved.)" }
        do {
            try autosave()
            return " (Position auto-saved at sentence \(currentIndex + 1).)"
        } catch {
            return " (The position also could not be auto-saved: \(error.localizedDescription))"
        }
    }

    // MARK: - Saves

    /// 任意セーブ（停止中のみ）
    func saveManually() {
        guard canSaveManually, let document else { return }
        guard manualSaves.count < Self.manualSaveLimit else {
            errorMessage = "You can keep up to \(Self.manualSaveLimit) saved positions. Delete a saved position to make room."
            return
        }
        do {
            try commitSaves(saves + [makeSavePoint(kind: .manual, document: document)])
            statusMessage = "Saved position at sentence \(currentIndex + 1) (\(manualSaves.count)/\(Self.manualSaveLimit))."
        } catch {
            reportError("Could not save the position: \(error.localizedDescription)")
        }
    }

    /// セーブした位置を読み込む（再生ボタンでその位置から再開）。
    func load(_ save: SavePoint) {
        guard !isBusy else { return }
        stop()
        guard let text = storage.loadDocumentText(id: save.documentID) else {
            reportError("The text for “\(save.documentTitle)” could not be found. Open the original file again.")
            return
        }
        apply(save, text: text)
        statusMessage = "Loaded “\(save.documentTitle)” at sentence \(currentIndex + 1). Press Play to resume."
    }

    func delete(_ save: SavePoint) {
        guard !isBusy else { return }
        do {
            try commitSaves(saves.filter { $0.id != save.id })
        } catch {
            // 一覧の保存に失敗したら、一覧も本文キャッシュもそのままにする
            reportError("Could not delete the saved position: \(error.localizedDescription)")
            return
        }
        var referenced = Set(saves.map(\.documentID))
        if let document {
            referenced.insert(document.id)
        }
        storage.removeDocuments(notReferencedBy: referenced)
    }

    // MARK: - Copy

    /// フォーカス中（大写し）の文をクリップボードにコピーする（停止中のみ）。
    func copyCurrentSentence() {
        guard canCopy, let sentence = currentSentence else { return }
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(sentence, forType: .string)
        #else
        UIPasteboard.general.string = sentence
        #endif
        statusMessage = "Copied the current sentence."
    }

    // MARK: - Lifecycle

    /// 文書を閉じてから削除し、終了通知や合成完了通知によるデータの再生成を防ぐ。
    func deleteAllStoredData() async {
        guard !isBusy else { return }
        isClearingData = true
        defer { isClearingData = false }
        dataDeletionMessage = nil
        dataDeletionError = nil
        errorMessage = nil
        lifecycleGeneration &+= 1
        #if os(iOS)
        resumesAfterInterruption = false
        #endif
        isPlaying = false
        document = nil
        currentIndex = 0
        currentDocumentIsStored = false
        reachedEnd = false
        statusMessage = nil

        // 一方が失敗しても、もう一方の削除を試みる。
        var failures: [String] = []
        do {
            try await speaker.clearTemporaryFiles()
        } catch {
            failures.append("Generated audio: \(error.localizedDescription)")
        }
        do {
            try storage.removeAllData()
            saves = []
        } catch {
            failures.append("Document text and history: \(error.localizedDescription)")
            saves = (try? storage.loadSaves()) ?? []
        }
        if failures.isEmpty {
            dataDeletionMessage = "All saved data has been deleted."
            statusMessage = dataDeletionMessage
        } else {
            dataDeletionError = "Some data could not be deleted. Please try again.\n" + failures.joined(separator: "\n")
        }
    }

    /// ウィンドウを閉じる・アプリ終了時に、読み上げを止めて位置をオートセーブする。
    func prepareForTermination() {
        lifecycleGeneration &+= 1
        if isPlaying {
            speaker.stop()
            isPlaying = false
        }
        speaker.removeTemporaryFiles()
        // 終了処理中はアラートを表示できないため、失敗は無視する
        try? autosave()
    }

    /// アプリがバックグラウンドに入るときに、読み上げは続けたまま現在の位置をオートセーブする。
    /// iOS ではバックグラウンドのアプリが終了通知なしに終了させられることがあるため。
    func saveProgress() {
        guard document != nil else { return }
        try? autosave()
    }

    #if os(iOS)
    /// 電話・他のアプリの再生・ヘッドフォンの取り外しなどで読み上げを止める（ヒューマンインターフェイスガイドラインの
    /// 「割り込みが終わって再開してよいとシステムが示したら再開する」「出力先がなくなったら一時停止する」に従う）。
    private func handleAudioSessionEvent(_ event: SpeechPlayer.AudioSessionEvent) {
        switch event {
        case .interruptionBegan:
            guard isPlaying else { return }
            resumesAfterInterruption = true
            stop()
        case let .interruptionEnded(shouldResume):
            let resumes = resumesAfterInterruption && shouldResume
            resumesAfterInterruption = false
            if resumes {
                play()
            }
        case .outputDeviceRemoved:
            resumesAfterInterruption = false
            stop()
        case .mediaServicesReset:
            // 読み上げ中の文は中断されているので、一時停止の状態にそろえる。再開は利用者に任せる
            resumesAfterInterruption = false
            stop()
        }
    }
    #endif

    /// 読み上げの状態が変わったら、ロック画面などの「再生中」表示を更新する。
    private func playbackStateDidChange() {
        #if os(iOS)
        guard let document else {
            nowPlaying.update(nil)
            return
        }
        nowPlaying.update(.init(
            title: showsDocumentNameOnLockScreen ? document.title : "SimpleTTS",
            sentenceIndex: currentIndex,
            sentenceCount: document.sentences.count,
            isPlaying: isPlaying,
            canStepBackward: canStepBackward,
            canStepForward: canStepForward
        ))
        #endif
    }

    // MARK: - Private

    private func restoreLastSession() {
        guard let latest = autoSaves.first,
              let text = storage.loadDocumentText(id: latest.documentID) else { return }
        apply(latest, text: text)
        statusMessage = "Restored “\(latest.documentTitle)” at sentence \(currentIndex + 1)."
    }

    private func apply(_ save: SavePoint, text: String) {
        let restored = ReaderDocument(title: save.documentTitle, text: text)
        guard !restored.sentences.isEmpty else { return }
        document = restored
        currentDocumentIsStored = true
        currentIndex = clampedIndex(save.sentenceIndex, in: restored)
        reachedEnd = false
    }

    private func clampedIndex(_ index: Int, in document: ReaderDocument) -> Int {
        min(max(0, index), document.sentences.count - 1)
    }

    /// 現在の文書の位置をオートセーブする（文書ごとに 1 件、上限を超えた古いものは削除）。
    /// 書き込みに失敗した場合はメモリ上のセーブ一覧も変更しない。
    private func autosave() throws {
        guard !isClearingData, savesCurrentDocument, let document else { return }
        var updated = saves.filter { !($0.kind == .auto && $0.documentID == document.id) }
        updated.append(makeSavePoint(kind: .auto, document: document))

        let autos = updated.filter { $0.kind == .auto }.sorted { $0.createdAt > $1.createdAt }
        if autos.count > Self.autoSaveLimit {
            let overflow = Set(autos.dropFirst(Self.autoSaveLimit).map(\.id))
            updated.removeAll { overflow.contains($0.id) }
        }
        try commitSaves(updated)
    }

    private func makeSavePoint(kind: SavePoint.Kind, document: ReaderDocument) -> SavePoint {
        SavePoint(
            id: UUID(),
            kind: kind,
            documentID: document.id,
            documentTitle: document.title,
            sentenceIndex: currentIndex,
            sentenceCount: document.sentences.count,
            excerpt: String((currentSentence ?? "").prefix(80)),
            createdAt: Date()
        )
    }

    /// セーブ一覧をディスクに書き込み、成功したときだけメモリ上の一覧に反映する。
    private func commitSaves(_ updated: [SavePoint]) throws {
        try storage.writeSaves(updated)
        saves = updated
    }

    /// エラーを表示する。表示待ちのエラーがあれば消さずに追記する。
    private func reportError(_ message: String) {
        if let existing = errorMessage, !existing.isEmpty {
            errorMessage = existing + "\n\n" + message
        } else {
            errorMessage = message
        }
    }

    /// 速度を範囲内に収め、刻みに丸める（スライダーの値には 1.0000000000000002 のような誤差が乗る）。
    private static func normalizedRate(_ value: Double) -> Double {
        // 刻みを掛けると 0.30000000000000004 のような誤差が残るので、刻みの逆数で割る
        let stepped = (value / rateStep).rounded() / (1 / rateStep)
        return min(max(stepped, rateRange.lowerBound), rateRange.upperBound)
    }

    private static func loadFailureMessage(for error: Error) -> String {
        guard case let StorageError.savesUnreadable(underlying, backupURL) = error else {
            return "Could not load saved positions: \(error.localizedDescription)"
        }
        if let backupURL {
            return "Could not load saved positions. The original data has been moved to “\(backupURL.lastPathComponent)”, and document text has been kept: \(underlying.localizedDescription)"
        }
        return "Could not load or move the saved data. Saving is disabled for this session to protect the original data: \(underlying.localizedDescription)"
    }
}
