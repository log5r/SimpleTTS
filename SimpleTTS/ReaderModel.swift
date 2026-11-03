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
    var errorMessage: String?
    var isImporterPresented = false

    private var storedVoice: String?
    private var storedRate: Double

    @ObservationIgnored private let speaker = SpeechPlayer()
    @ObservationIgnored private let storage = Storage()
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
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.voice)
            prefetchNextSentence()
        }
    }

    /// 読み上げ速度（声の標準の速さに対する倍率）。読み上げ中に変えるとすぐ反映される。
    var rate: Double {
        get { storedRate }
        set {
            storedRate = Self.normalizedRate(newValue)
            UserDefaults.standard.set(storedRate, forKey: DefaultsKey.rate)
            speaker.playbackRate = Float(storedRate)
        }
    }

    init() {
        let defaults = UserDefaults.standard
        storedVoice = defaults.string(forKey: DefaultsKey.voice)
        let savedRate = defaults.double(forKey: DefaultsKey.rate)
        storedRate = savedRate > 0 ? Self.normalizedRate(savedRate) : 1
        speaker.playbackRate = Float(storedRate)

        do {
            saves = try storage.loadSaves()
            // 正常に読み込めたときだけ、参照されていない本文キャッシュを整理する
            storage.removeDocuments(notReferencedBy: Set(saves.map(\.documentID)))
        } catch {
            saves = []
            errorMessage = Self.loadFailureMessage(for: error)
        }
        restoreLastSession()

        #if os(iOS)
        speaker.onAudioSessionEvent = { [weak self] event in
            self?.handleAudioSessionEvent(event)
        }
        #endif

        Task { [weak self] in
            let voices = await SpeechSynthesizer.availableVoices()
            self?.voices = voices
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

    var canStepBackward: Bool { document != nil && currentIndex > 0 }
    var canStepForward: Bool { currentIndex + 1 < sentenceCount }
    /// 任意セーブは停止中のみ
    var canSaveManually: Bool { document != nil && !isPlaying }
    /// コピーは停止（一時停止）中のみ
    var canCopy: Bool { currentSentence != nil && !isPlaying }

    // MARK: - File

    func openFile(at url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }

        let text: String
        do {
            let data = try Data(contentsOf: url)
            guard let decoded = TextDecoding.decode(data) else {
                errorMessage = "「\(url.lastPathComponent)」の文字コードを判別できませんでした。"
                return
            }
            text = decoded
        } catch {
            errorMessage = "ファイルを読み込めませんでした: \(error.localizedDescription)"
            return
        }

        let newDocument = ReaderDocument(title: url.lastPathComponent, text: text)
        guard !newDocument.sentences.isEmpty else {
            errorMessage = "「\(url.lastPathComponent)」には読み上げる文章がありません。"
            return
        }

        do {
            try storage.storeDocumentText(text, id: newDocument.id)
        } catch {
            errorMessage = "本文の保存に失敗しました。セーブから再開できない可能性があります: \(error.localizedDescription)"
        }

        // 読み上げ中なら止めて、それまでの文書の位置をオートセーブする
        stop()

        document = newDocument
        reachedEnd = false
        if let autosave = autoSaves.first(where: { $0.documentID == newDocument.id }) {
            currentIndex = clampedIndex(autosave.sentenceIndex, in: newDocument)
            statusMessage = "前回停止した位置（\(currentIndex + 1)文目）から再開できます。"
        } else {
            currentIndex = 0
            statusMessage = "「\(newDocument.title)」を開きました（全\(newDocument.sentences.count)文）。"
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
        guard let document, !document.sentences.isEmpty, !isPlaying else { return }
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
            statusMessage = "一時停止しました（\(currentIndex + 1)文目）。位置をオートセーブしました。"
        } catch {
            statusMessage = "一時停止しました（\(currentIndex + 1)文目）。"
            reportError("一時停止しました（オートセーブに失敗）: \(error.localizedDescription)")
        }
    }

    func step(by delta: Int) {
        jump(to: currentIndex + delta)
    }

    /// 指定した文へ移動する。読み上げ中ならその文から読み直す。
    func jump(to index: Int) {
        guard let document, document.sentences.indices.contains(index) else { return }
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
            reportError("読み上げに失敗しました: \(error.localizedDescription)" + autosaveResultSuffix())
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
                statusMessage = "最後まで読み上げました。もう一度再生すると最初から読み上げます。"
            } catch {
                statusMessage = "最後まで読み上げました。"
                reportError("最後まで読み上げましたが、位置のオートセーブに失敗しました: \(error.localizedDescription)")
            }
        }
    }

    /// オートセーブを試み、その結果をエラーメッセージの末尾に付ける文言で返す。
    private func autosaveResultSuffix() -> String {
        do {
            try autosave()
            return "（\(currentIndex + 1)文目をオートセーブしました）"
        } catch {
            return "（位置のオートセーブにも失敗しました: \(error.localizedDescription)）"
        }
    }

    // MARK: - Saves

    /// 任意セーブ（停止中のみ）
    func saveManually() {
        guard let document, !isPlaying else { return }
        guard manualSaves.count < Self.manualSaveLimit else {
            errorMessage = "セーブは最大\(Self.manualSaveLimit)件までです。不要なセーブを削除してください。"
            return
        }
        do {
            try commitSaves(saves + [makeSavePoint(kind: .manual, document: document)])
            statusMessage = "\(currentIndex + 1)文目をセーブしました（\(manualSaves.count)/\(Self.manualSaveLimit)）。"
        } catch {
            reportError("セーブに失敗しました: \(error.localizedDescription)")
        }
    }

    /// セーブした位置を読み込む（再生ボタンでその位置から再開）。
    func load(_ save: SavePoint) {
        stop()
        guard let text = storage.loadDocumentText(id: save.documentID) else {
            reportError("「\(save.documentTitle)」の本文が見つかりません。ファイルを開き直してください。")
            return
        }
        apply(save, text: text)
        statusMessage = "「\(save.documentTitle)」の\(currentIndex + 1)文目を読み込みました。再生で続きから読み上げます。"
    }

    func delete(_ save: SavePoint) {
        do {
            try commitSaves(saves.filter { $0.id != save.id })
        } catch {
            // 一覧の保存に失敗したら、一覧も本文キャッシュもそのままにする
            reportError("セーブを削除できませんでした: \(error.localizedDescription)")
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
        guard !isPlaying, let sentence = currentSentence else { return }
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(sentence, forType: .string)
        #else
        UIPasteboard.general.string = sentence
        #endif
        statusMessage = "フォーカス中の文章をコピーしました。"
    }

    // MARK: - Lifecycle

    /// ウィンドウを閉じる・アプリ終了時に、読み上げを止めて位置をオートセーブする。
    func prepareForTermination() {
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
            title: document.title,
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
        statusMessage = "前回の「\(latest.documentTitle)」（\(currentIndex + 1)文目）を復元しました。"
    }

    private func apply(_ save: SavePoint, text: String) {
        let restored = ReaderDocument(title: save.documentTitle, text: text)
        guard !restored.sentences.isEmpty else { return }
        document = restored
        currentIndex = clampedIndex(save.sentenceIndex, in: restored)
        reachedEnd = false
    }

    private func clampedIndex(_ index: Int, in document: ReaderDocument) -> Int {
        min(max(0, index), document.sentences.count - 1)
    }

    /// 現在の文書の位置をオートセーブする（文書ごとに 1 件、上限を超えた古いものは削除）。
    /// 書き込みに失敗した場合はメモリ上のセーブ一覧も変更しない。
    private func autosave() throws {
        guard let document else { return }
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
            return "セーブデータを読み込めませんでした: \(error.localizedDescription)"
        }
        if let backupURL {
            return "セーブデータを読み込めませんでした。元のデータは「\(backupURL.lastPathComponent)」に退避し、本文は保持しています: \(underlying.localizedDescription)"
        }
        return "セーブデータを読み込めず、退避もできませんでした。元のデータを守るため、このセッションではセーブを書き込みません: \(underlying.localizedDescription)"
    }
}
