import AVFoundation
import Foundation

/// 文ごとにファイルへ合成し、1 本の `AVAudioEngine` で連続再生する。
///
/// 合成は `SpeechSynthesizer` が行う。macOS では `say -o`、iOS では `AVSpeechSynthesizer.write` を使う。
///
/// - 合成は再生とは別に背景で行い、次の文を先読み（`prefetch`）して文間の待ち時間を短くする。
/// - 読み上げ中はエンジンを止めず、文と文の間も無音を流し続ける。出力デバイスの IO が文ごとに
///   止まったり起きたりしないので、デバイス側の立ち上がりで文頭が欠けることもない。
/// - 停止・移動は短いフェードアウトのあとに止める（合成エンジンのライブ再生を途中で切るとクリックになる）。
/// - 速度は `AVAudioUnitTimePitch` で音程を保ったまま変える。合成は常に声の標準の速さで行うので、
///   速度を変えても合成し直さず、読み上げ中の文にもすぐ反映される。
///
/// `onFinish` は「その文を最後まで再生した」か「合成・再生に失敗した」ときだけ呼ばれる。
/// `stop()` や次の `speak` で中断した文については呼ばれない。
final class SpeechPlayer {
    /// エンジン起動直後、最初の文の前に流す無音。出力デバイスが起き上がる時間を確保する。
    static let leadInDuration: TimeInterval = 0.3
    /// 前の文を最後まで読んだあと、次の文の前に置く間。`say -o` の波形には文末の間がほとんど含まれない。
    static let sentenceGapDuration: TimeInterval = 0.35
    /// 停止・移動で前の文を中断したあと、次の文の前に置く間
    static let interruptedGapDuration: TimeInterval = 0.1
    /// 停止時のフェードアウトの長さと段数
    static let fadeOutDuration: TimeInterval = 0.032
    static let fadeOutSteps = 4

    // iOS でメディアサービスがリセットされたら作り直すので var にしている
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var timePitch = AVAudioUnitTimePitch()
    private let format = AVAudioFormat(standardFormatWithSampleRate: SpeechSynthesizer.sampleRate, channels: 1)!
    private var areNodesAttached = false

    /// 再生速度（1 が声の標準の速さ）。読み上げ中に変えるとすぐ反映される。
    var playbackRate: Float = 1 {
        didSet { applyPlaybackRate() }
    }

    /// 合成済み（または合成中）のファイル。現在の文と先読みした次の文だけを保持する。
    private var synthesisTasks: [SpeechRequest: Task<URL, Error>] = [:]
    /// キャッシュから外したあとも、合成の終了とファイル削除を待っている処理。
    private var retiringSynthesisTasks: [UUID: Task<Void, Never>] = [:]
    private var temporaryFilesCleanup: Task<Void, Error>?
    private let cacheDirectory: URL

    /// 再生中（合成待ちを含む）の文
    private var current: Utterance?
    /// `speak`・`stop` のたびに進める世代番号。古い完了通知を捨てるために使う。
    private var generation = 0
    /// 再生を開始（または流し直し）するたびに進める番号。`AVAudioPlayerNode.stop()` は未再生分の完了通知も
    /// 呼ぶので、同じ文を流し直したときに古い試行の通知を読了と取り違えないように、世代番号とは別に持つ。
    private var playbackAttempt = 0
    /// 進行中のフェードアウト。次の文はこれが終わってから流す。
    private var fadeOut: Task<Void, Never>?
    /// 次の文の前に置く無音
    private var pendingGap: Gap = .leadIn
    private var configurationObserver: NSObjectProtocol?

    #if os(iOS)
    /// オーディオセッションの割り込み（電話など）や出力先の変化。読み上げを止めるかどうかは受け取り側が決める。
    enum AudioSessionEvent {
        /// 電話などの割り込みで、システムがオーディオセッションを無効にした
        case interruptionBegan
        /// システムが再開の可否を示した。`shouldResume` は再開してよいと示しているか
        case interruptionEnded(shouldResume: Bool)
        /// ヘッドフォンが外されるなど、使っていた出力先がなくなった
        case outputDeviceRemoved
        /// メディアサービスがリセットされた。読み上げ中の文は中断され、エンジンは作り直してある
        case mediaServicesReset
    }

    /// オーディオセッションのイベント。メインスレッドで呼ばれる。
    var onAudioSessionEvent: ((AudioSessionEvent) -> Void)?
    private var sessionObservers: [NSObjectProtocol] = []
    #endif

    private enum Gap {
        /// エンジン起動直後。出力デバイスが起き上がる時間なので、速度によらず実時間で確保する。
        case leadIn
        /// 前の文を最後まで読んだあと。読み上げの間合いなので、速度に合わせて縮める。
        case sentence
        /// 停止・移動で前の文を中断したあと。速度によらず実時間で確保する。
        case interrupted
    }

    private struct Utterance {
        let token: Int
        let request: SpeechRequest
        var fileURL: URL?
        let onFinish: (Result<Void, Error>) -> Void
    }

    init(temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        #if os(macOS)
        // 終了済みの say の stdin に書き込んでもアプリが落ちないようにする
        signal(SIGPIPE, SIG_IGN)
        #endif

        let base = temporaryDirectory
        cacheDirectory = base.appending(
            path: "Speech-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)
        Self.removeStaleCacheDirectories(in: base, keeping: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        applyPlaybackRate()

        observeEngineConfiguration()
        #if os(iOS)
        observeAudioSession()
        #endif
    }

    private func observeEngineConfiguration() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.engineConfigurationDidChange()
            }
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        #if os(iOS)
        for observer in sessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        #endif
    }

    // MARK: - Public

    /// `text` を読み上げる。再生中の文があれば中断する。
    func speak(
        _ text: String,
        voice: String?,
        onFinish: @escaping (Result<Void, Error>) -> Void
    ) {
        guard temporaryFilesCleanup == nil else {
            onFinish(.failure(CancellationError()))
            return
        }
        interruptCurrent()
        generation &+= 1
        let token = generation
        let request = SpeechRequest(text: text, voice: voice)
        current = Utterance(token: token, request: request, fileURL: nil, onFinish: onFinish)

        let synthesis = synthesisTask(for: request)
        discardSynthesisTasks(except: [request])

        Task { [weak self] in
            var result: Result<URL, Error>
            do {
                result = .success(try await synthesis.value)
            } catch {
                result = .failure(error)
            }
            guard let self, self.generation == token else { return }
            // 前の文のフェードアウトが終わるのを待ってから流す
            if let fadeOut = self.fadeOut {
                await fadeOut.value
            }
            guard self.generation == token, var utterance = self.current, utterance.token == token else { return }
            #if os(iOS)
            if case .success = result, !self.engine.isRunning {
                do {
                    try await self.activateAudioSession()
                } catch {
                    result = .failure(error)
                }
                // 有効になるのを待つあいだに停止・移動されていたら流さない
                guard self.generation == token, self.current?.token == token else { return }
            }
            #endif
            switch result {
            case let .success(url):
                utterance.fileURL = url
                self.current = utterance
                self.play(utterance)
            case let .failure(error):
                self.current = nil
                self.stopEngineIfIdle()
                utterance.onFinish(.failure(error))
            }
        }
    }

    /// 次に読む見込みの文を先に合成しておく。
    func prefetch(_ text: String, voice: String?) {
        guard temporaryFilesCleanup == nil else { return }
        let request = SpeechRequest(text: text, voice: voice)
        _ = synthesisTask(for: request)
        var keep: Set<SpeechRequest> = [request]
        if let current {
            keep.insert(current.request)
        }
        discardSynthesisTasks(except: keep)
    }

    /// 再生を止める。合成済みのファイルは再開に備えて残す。
    func stop() {
        interruptCurrent()
        generation &+= 1
        let token = generation
        if let fadeOut {
            Task { [weak self] in
                await fadeOut.value
                guard let self, self.generation == token else { return }
                self.stopEngineIfIdle()
            }
        } else {
            stopEngineIfIdle()
        }
    }

    /// アプリ終了時に、合成ファイルの一時ディレクトリを削除する。
    func removeTemporaryFiles() {
        discardSynthesisTasks(except: [])
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    /// 明示的なデータ消去。合成が終わるまで待ち、消去後に古い音声が書き戻されるのを防ぐ。
    /// 終了時と異なり、削除に失敗した場合は呼び出し側へ通知する。
    func clearTemporaryFiles() async throws {
        if let temporaryFilesCleanup {
            try await temporaryFilesCleanup.value
            return
        }
        let cleanup = Task { @MainActor in
            stop()
            let activeTasks = Array(synthesisTasks.values)
            synthesisTasks.removeAll()
            for task in activeTasks {
                task.cancel()
            }
            // 先読みの差し替えなどで既に辞書から外れた合成も、ファイルを書き終えるまで待つ。
            let retiringTasks = Array(retiringSynthesisTasks.values)
            for task in activeTasks {
                _ = await task.result
            }
            for task in retiringTasks {
                await task.value
            }
            if let fadeOut {
                await fadeOut.value
            }
            stopEngineIfIdle()

            let fileManager = FileManager.default
            let base = cacheDirectory.deletingLastPathComponent()
            let directories = try Self.cacheDirectories(in: base)
            for directory in directories {
                try fileManager.removeItem(at: directory)
            }
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
        temporaryFilesCleanup = cleanup
        defer { temporaryFilesCleanup = nil }
        try await cleanup.value
    }

    // MARK: - Synthesis cache

    private func synthesisTask(for request: SpeechRequest) -> Task<URL, Error> {
        if let existing = synthesisTasks[request] {
            return existing
        }
        let url = cacheDirectory.appending(path: "\(UUID().uuidString).wav", directoryHint: .notDirectory)
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            // ウィンドウを閉じた後も同じプレイヤーを使う場合、終了処理が消した保存先を作り直す。
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await SpeechSynthesizer.synthesize(request, to: url)
            return url
        }
        synthesisTasks[request] = task
        // 失敗した合成はキャッシュに残さない（残すと同じ文の再生が合成し直されずに失敗し続ける）
        Task { [weak self] in
            guard (try? await task.value) == nil else { return }
            guard let self, self.synthesisTasks[request] == task else { return }
            self.synthesisTasks.removeValue(forKey: request)
        }
        return task
    }

    /// `keep` 以外の合成をキャンセルし、ファイルを削除する。
    private func discardSynthesisTasks(except keep: Set<SpeechRequest>) {
        for (request, task) in synthesisTasks where !keep.contains(request) {
            synthesisTasks.removeValue(forKey: request)
            task.cancel()
            let identifier = UUID()
            let cleanup = Task.detached(priority: .utility) {
                // 合成済みなら URL が返るので削除する。キャンセル・失敗時は synthesize 側が削除している。
                if let url = try? await task.value {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            retiringSynthesisTasks[identifier] = cleanup
            Task { [weak self] in
                await cleanup.value
                self?.retiringSynthesisTasks.removeValue(forKey: identifier)
            }
        }
    }

    // MARK: - Playback

    private func play(_ utterance: Utterance) {
        guard let fileURL = utterance.fileURL else { return }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: fileURL)
            try startEngineIfNeeded(for: file.processingFormat)
            if !player.isPlaying {
                try player.playAudio()
            }
        } catch {
            current = nil
            stopEngineIfIdle()
            utterance.onFinish(.failure(error))
            return
        }

        let token = utterance.token
        playbackAttempt &+= 1
        let attempt = playbackAttempt
        scheduleSilence(duration: silenceDuration(for: pendingGap))
        pendingGap = .sentence
        if file.length > 0 {
            player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.utteranceDidPlayBack(token: token, attempt: attempt)
                }
            }
        } else {
            // 空のファイル（記号だけの文など）は再生せずに終わったことにする
            Task { @MainActor [weak self] in
                self?.utteranceDidPlayBack(token: token, attempt: attempt)
            }
        }
    }

    private func utteranceDidPlayBack(token: Int, attempt: Int) {
        guard attempt == playbackAttempt else { return }
        guard let utterance = current, utterance.token == token, generation == token else { return }
        current = nil
        utterance.onFinish(.success(()))
        // 続けて次の文の speak が呼ばれていなければ、エンジンを止める
        if generation == token {
            stopEngineIfIdle()
        }
    }

    /// 再生中の文を中断する（フェードアウトしてから止める）。
    private func interruptCurrent() {
        guard let utterance = current else { return }
        current = nil
        guard utterance.fileURL != nil, engine.isRunning else {
            // まだ合成待ちなら音は出ていない
            pendingGap = engine.isRunning ? .interrupted : .leadIn
            return
        }
        pendingGap = .interrupted
        let player = player
        let previousFade = fadeOut
        fadeOut = Task { @MainActor in
            if let previousFade {
                await previousFade.value
            }
            let stepDuration = Self.fadeOutDuration / Double(Self.fadeOutSteps)
            for step in stride(from: Self.fadeOutSteps - 1, through: 0, by: -1) {
                player.volume = Float(step) / Float(Self.fadeOutSteps)
                try? await Task.sleep(for: .seconds(stepDuration))
            }
            player.stop()
            player.volume = 1
        }
    }

    private func startEngineIfNeeded(for fileFormat: AVAudioFormat) throws {
        if !areNodesAttached {
            engine.attach(player)
            engine.attach(timePitch)
            try engine.connectNode(player, to: timePitch, format: format)
            try engine.connectNode(timePitch, to: engine.mainMixerNode, format: format)
            areNodesAttached = true
        }
        // 合成フォーマットは固定しているが、万一違うファイルが来たら接続を合わせる
        let connected = player.outputFormat(forBus: 0)
        if connected.sampleRate != fileFormat.sampleRate || connected.channelCount != fileFormat.channelCount {
            player.stop()
            engine.disconnectNodeOutput(player)
            engine.disconnectNodeOutput(timePitch)
            try engine.connectNode(player, to: timePitch, format: fileFormat)
            try engine.connectNode(timePitch, to: engine.mainMixerNode, format: fileFormat)
        }
        guard !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
        pendingGap = .leadIn
    }

    private func stopEngineIfIdle() {
        guard current == nil, engine.isRunning else { return }
        player.stop()
        engine.stop()
        pendingGap = .leadIn
        #if os(iOS)
        // 止めたことを他のアプリに知らせ、一時停止していた音楽などを再開できるようにする。
        // 同期版の setActive(false) はメインスレッドを止めることがあるので、非同期版を使う
        AVAudioSession.sharedInstance().deactivate(options: .notifyOthersOnDeactivation) { _, _ in }
        #endif
    }

    private func applyPlaybackRate() {
        timePitch.rate = playbackRate
        // 1 倍では素通しにして、合成した波形をそのまま流す（通すと 1 倍でも波形がわずかに変わる）
        timePitch.bypass = abs(playbackRate - 1) < 0.001
    }

    /// 無音として流す素材の長さ。素材は `timePitch` で縮むので、実時間で確保したい間はその分伸ばしておく。
    private func silenceDuration(for gap: Gap) -> TimeInterval {
        switch gap {
        case .leadIn: Self.leadInDuration * Double(playbackRate)
        case .sentence: Self.sentenceGapDuration
        case .interrupted: Self.interruptedGapDuration * Double(playbackRate)
        }
    }

    private func scheduleSilence(duration: TimeInterval) {
        let playerFormat = player.outputFormat(forBus: 0)
        let frames = AVAudioFrameCount(duration * playerFormat.sampleRate)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: playerFormat, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        // AVAudioPCMBuffer は確保時にゼロ初期化されるので、そのまま無音として使える
        player.scheduleBuffer(buffer)
    }

    /// 出力デバイスの切り替えなどでエンジンが止まったら、再生中の文を頭から流し直す。
    private func engineConfigurationDidChange() {
        guard let utterance = current, utterance.fileURL != nil else { return }
        // stop() が呼ぶ古い試行の完了通知を、流し直した文の読了と取り違えないようにする
        playbackAttempt &+= 1
        player.stop()
        engine.stop()
        play(utterance)
    }

    #if os(iOS)
    // MARK: - Audio session

    /// 読み上げ用にオーディオセッションを設定して有効にする。
    /// `.playback` なので消音スイッチがオンでも鳴り、バックグラウンドでも読み上げを続けられる
    /// （Info.plist の `UIBackgroundModes` に `audio` が必要）。`.spokenAudio` は読み上げコンテンツ向けのモードで、
    /// 他のアプリの読み上げと重なったときにシステムが適切に扱う。
    /// 有効化には時間がかかり、同期版の setActive(true) はメインスレッドを止めることがあるので、非同期版を使う。
    private func activateAudioSession() async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try await session.activate(options: [])
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        // システムによる無効化だけを割り込みとして扱う。自分で `setActive(false)` したときにも届くので、それは無視する。
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.didBecomeInactiveNotification, object: session, queue: .main
        ) { [weak self] notification in
            let context = notification.userInfo?[AVAudioSession.deactivationContextKey]
                as? AVAudioSession.DeactivationContext
            let isSystemDeactivation = context?.source == .system
            MainActor.assumeIsolated {
                guard let self, isSystemDeactivation else { return }
                self.onAudioSessionEvent?(.interruptionBegan)
            }
        })
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.resumptionRecommendationNotification, object: session, queue: .main
        ) { [weak self] notification in
            let context = notification.userInfo?[AVAudioSession.resumptionContextKey]
                as? AVAudioSession.ResumptionContext
            let shouldResume = context?.recommendation == .shouldResume
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onAudioSessionEvent?(.interruptionEnded(shouldResume: shouldResume))
            }
        })
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] notification in
            let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let isDeviceRemoved = reasonValue.flatMap(AVAudioSession.RouteChangeReason.init) == .oldDeviceUnavailable
            MainActor.assumeIsolated {
                guard let self, isDeviceRemoved else { return }
                self.onAudioSessionEvent?(.outputDeviceRemoved)
            }
        })
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.mediaServicesWereReset()
            }
        })
    }

    /// メディアサービスのリセット後は、それまでのエンジンとノードは使えない。読み上げ中の文を捨て、作り直す。
    /// 合成済みのファイルはそのまま使えるので残す。セッションの設定は次の `activateAudioSession()` でやり直される。
    private func mediaServicesWereReset() {
        current = nil
        generation &+= 1
        playbackAttempt &+= 1
        fadeOut?.cancel()
        fadeOut = nil

        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        timePitch = AVAudioUnitTimePitch()
        areNodesAttached = false
        pendingGap = .leadIn
        applyPlaybackRate()
        observeEngineConfiguration()

        onAudioSessionEvent?(.mediaServicesReset)
    }
    #endif

    // MARK: - Cache directory

    /// 以前の起動（異常終了など）が残した一時ディレクトリを削除する。
    private static func removeStaleCacheDirectories(in base: URL, keeping current: URL) {
        let fileManager = FileManager.default
        guard let items = try? cacheDirectories(in: base) else { return }
        for item in items where item != current {
            try? fileManager.removeItem(at: item)
        }
    }

    private static func cacheDirectories(in base: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil).filter {
            let name = $0.lastPathComponent
            guard name.hasPrefix("Speech-") else { return false }
            let identifier = name.dropFirst("Speech-".count)
            return !identifier.isEmpty && identifier.allSatisfy(\.isNumber)
        }
    }
}
