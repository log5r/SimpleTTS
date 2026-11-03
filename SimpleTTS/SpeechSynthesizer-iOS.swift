#if os(iOS)
import AVFoundation
import Foundation

nonisolated enum SpeechSynthesisError: LocalizedError {
    /// 選んだ声がこの端末にない（削除された・別の端末で選んだなど）
    case voiceUnavailable
    /// 一定時間、合成から波形も完了通知も届かなかった
    case timedOut
    /// 合成した音声を再生用のフォーマットに変換できなかった
    case conversionFailed(underlying: Error?)
    /// 合成した音声をファイルに書き出せなかった
    case unwritableOutput(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .voiceUnavailable:
            return "The selected voice is not available on this device. Download it in Settings under Accessibility, or choose another voice."
        case .timedOut:
            return "Speech synthesis stopped responding."
        case let .conversionFailed(underlying):
            if let underlying {
                return "Could not convert the generated audio: \(underlying.localizedDescription)"
            }
            return "Could not convert the generated audio."
        case let .unwritableOutput(underlying):
            return "Could not save the generated audio: \(underlying.localizedDescription)"
        }
    }
}

/// `AVSpeechSynthesizer` で 1 文をファイルに合成する（iOS 版）。
///
/// iOS には `say` がないので、OS 標準の `AVSpeechSynthesizer` を使う。ただし `speak(_:)` で
/// 直接再生させず、`write(_:toBufferCallback:)` で波形だけを受け取ってファイルにし、再生は macOS と同じ
/// `SpeechPlayer`（`AVAudioEngine`）で行う。理由は次のとおり。
///
/// - macOS では、合成エンジンにライブ再生させる経路で文頭に不連続（「プツッ」）が入り、
///   合成と再生を分けると消えた（`docs/speech-start-noise-investigation.md`）。
///   `speak(_:)` も合成エンジンが文ごとに再生を始める経路なので、同じ問題を避けられる構成にそろえる。
/// - 文と文の間もエンジンを止めずに無音を流すので、出力の立ち上がりで文頭が欠けない。
/// - 速度を `AVAudioUnitTimePitch` で変える仕組み・先読み・停止時のフェードアウトを macOS と共有できる。
///
/// 合成した波形は 48 kHz / Float32 / モノラルに変換してから書き出す。声によってサンプルレートや
/// サンプル形式が違っても、`SpeechPlayer` の再生フォーマットを切り替えずに済む。
nonisolated enum SpeechSynthesizer {
    /// 書き出すサンプルレート。`SpeechPlayer` の再生フォーマットと一致させる。
    static let sampleRate: Double = 48000

    /// 選べる声の一覧（日本語の声が先頭）。ノベルティ音声（効果音のような声）は除く。
    /// `speechVoices()` は内部で同期的に待つので、Swift Concurrency のスレッドではなく GCD のキューで呼ぶ
    /// （協調スレッドで呼ぶと「unsafeForcedSync called from Swift Concurrent context」と警告される）。
    static func availableVoices() async -> [SpeechVoice] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let voices = AVSpeechSynthesisVoice.speechVoices()
                    .filter { !$0.voiceTraits.contains(.isNoveltyVoice) }
                    .map { voice in
                        SpeechVoice(id: voice.identifier, name: displayName(of: voice), locale: voice.language)
                    }
                continuation.resume(returning: SpeechVoice.sortedForDisplay(voices))
            }
        }
    }

    /// 同じ名前の声が品質違いで複数入っていることがあるので、品質を名前に添える。
    private static func displayName(of voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: "\(voice.name) Premium"
        case .enhanced: "\(voice.name) Enhanced"
        default: voice.name
        }
    }

    /// `request` を `url` に 48 kHz / Float32 / モノラルの WAV として合成する。
    /// タスクがキャンセルされたら合成を止め、`CancellationError` を投げる。
    /// 失敗時・キャンセル時は `url` のファイルを残さない。
    static func synthesize(_ request: SpeechRequest, to url: URL) async throws {
        let utterance = AVSpeechUtterance(string: request.text)
        if let identifier = request.voice, !identifier.isEmpty {
            guard let voice = await voice(withIdentifier: identifier) else {
                throw SpeechSynthesisError.voiceUnavailable
            }
            utterance.voice = voice
        }
        // 速度は再生側（SpeechPlayer）で変えるので、合成は常に声の標準の速さで行う。
        // 文の前後の間も再生側で入れる。
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0

        do {
            let buffers = try await BufferCollector.collect(utterance)
            try Task.checkCancellation()
            try writeResampled(buffers, to: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// 声を探す処理も `speechVoices()` と同じく内部で同期的に待つので、GCD のキューで行う。
    private static func voice(withIdentifier identifier: String) async -> AVSpeechSynthesisVoice? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: AVSpeechSynthesisVoice(identifier: identifier))
            }
        }
    }

    /// 合成した波形を 48 kHz / Float32 / モノラルに変換して `url` に書き出す。
    /// 波形が空（記号だけの文など）でも、長さ 0 の WAV を書き出す（`SpeechPlayer` は読了として扱う）。
    private static func writeResampled(_ buffers: [AVAudioPCMBuffer], to url: URL) throws {
        guard let outputFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw SpeechSynthesisError.conversionFailed(underlying: nil)
        }
        let file: AVAudioFile
        do {
            // 拡張子 .wav から WAV として書き出される
            file = try AVAudioFile(
                forWriting: url,
                settings: outputFormat.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw SpeechSynthesisError.unwritableOutput(underlying: error)
        }
        defer { file.close() }

        guard let inputFormat = buffers.first?.format else { return }
        guard buffers.allSatisfy({ $0.format == inputFormat }),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw SpeechSynthesisError.conversionFailed(underlying: nil)
        }
        converter.downmix = inputFormat.channelCount > 1

        let source = BufferQueue(buffers)
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else {
                throw SpeechSynthesisError.conversionFailed(underlying: nil)
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                if let next = source.next() {
                    inputStatus.pointee = .haveData
                    return next
                }
                inputStatus.pointee = .endOfStream
                return nil
            }
            if status == .error {
                throw SpeechSynthesisError.conversionFailed(underlying: conversionError)
            }
            if output.frameLength > 0 {
                do {
                    try file.write(from: output)
                } catch {
                    throw SpeechSynthesisError.unwritableOutput(underlying: error)
                }
            }
            if status == .endOfStream {
                return
            }
        }
    }
}

/// `AVAudioConverter` の入力ブロックに、受け取ったバッファを順に渡す。
private nonisolated final class BufferQueue: @unchecked Sendable {
    private var buffers: [AVAudioPCMBuffer]
    private var index = 0

    init(_ buffers: [AVAudioPCMBuffer]) {
        self.buffers = buffers
    }

    func next() -> AVAudioPCMBuffer? {
        guard index < buffers.count else { return nil }
        defer { index += 1 }
        return buffers[index]
    }
}

/// `AVSpeechSynthesizer.write(_:toBufferCallback:)` で 1 文分の波形を集める。
///
/// 完了は次のどちらかで判断する。
/// - 長さ 0 のバッファ: 合成の終わりとして、波形と同じ順序で届く。こちらを優先する。
/// - デリゲートの `didFinish`: 波形とは別のキューで届き、最後の波形より先に来ることがあり得るので、
///   少し待ってから完了にする（長さ 0 のバッファが届かない OS への備え）。
///
/// どちらも届かないまま一定時間たったら失敗にする（合成サービスが応答しなくなったときに止まらないように）。
private nonisolated final class BufferCollector: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    /// `didFinish` のあと、残りの波形を待つ時間
    private static let finishGracePeriod: Duration = .milliseconds(300)
    /// 合成から何も届かないまま、この時間たったら失敗にする
    private static let inactivityTimeout: TimeInterval = 15

    private let lock = NSLock()
    private let synthesizer = AVSpeechSynthesizer()
    private var buffers: [AVAudioPCMBuffer] = []
    private var continuation: CheckedContinuation<[AVAudioPCMBuffer], Error>?
    private var isCompleted = false
    private var lastActivity = Date()

    static func collect(_ utterance: AVSpeechUtterance) async throws -> [AVAudioPCMBuffer] {
        let collector = BufferCollector()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                collector.start(utterance, continuation: continuation)
            }
        } onCancel: {
            collector.complete(with: .failure(CancellationError()))
        }
    }

    private func start(
        _ utterance: AVSpeechUtterance,
        continuation: CheckedContinuation<[AVAudioPCMBuffer], Error>
    ) {
        lock.lock()
        if isCompleted {
            // 開始前にキャンセルされた
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lastActivity = Date()
        lock.unlock()

        synthesizer.delegate = self
        synthesizer.write(utterance) { [weak self] buffer in
            self?.receive(buffer)
        }
        startWatchdog()
    }

    private func receive(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        if pcm.frameLength == 0 {
            complete(with: nil)
            return
        }
        // 合成側がバッファを使い回しても影響しないよう、複製して持つ
        let copy = Self.copy(pcm)
        lock.lock()
        defer { lock.unlock() }
        guard !isCompleted else { return }
        lastActivity = Date()
        if let copy {
            buffers.append(copy)
        }
    }

    /// 完了させる。`result` が nil なら集めた波形で成功にする。2 回目以降は何もしない。
    private func complete(with result: Result<[AVAudioPCMBuffer], Error>?) {
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return
        }
        isCompleted = true
        let continuation = continuation
        self.continuation = nil
        let collected = buffers
        buffers = []
        lock.unlock()

        if case .failure = result {
            synthesizer.stopSpeaking(at: .immediate)
        }
        continuation?.resume(with: result ?? .success(collected))
    }

    private func startWatchdog() {
        Task.detached(priority: .utility) { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let (isCompleted, idle) = self.activityStatus()
                if isCompleted { return }
                if idle > Self.inactivityTimeout {
                    self.complete(with: .failure(SpeechSynthesisError.timedOut))
                    return
                }
            }
        }
    }

    /// 完了済みかどうかと、最後に波形を受け取ってからの経過秒数。
    /// `NSLock` は非同期コンテキストから直接使えないので、同期関数に切り出している。
    private func activityStatus() -> (isCompleted: Bool, idle: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        return (isCompleted, Date().timeIntervalSince(lastActivity))
    }

    private static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else {
            return nil
        }
        copy.frameLength = source.frameLength
        let sourceList = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let copyList = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(sourceList, copyList) {
            guard let fromData = from.mData, let toData = to.mData else { continue }
            memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task.detached(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(for: Self.finishGracePeriod)
            self?.complete(with: nil)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        complete(with: .failure(CancellationError()))
    }
}
#endif
