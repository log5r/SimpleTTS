#if os(macOS)
import AVFoundation
import Foundation

/// macOS 標準コマンド `/usr/bin/say` に関するユーティリティ
nonisolated enum SayCommand {
    static let executableURL = URL(fileURLWithPath: "/usr/bin/say")

    /// インストール済みの音声一覧を取得する（日本語音声を先頭に並べる）。
    static func availableVoices() async -> [SpeechVoice] {
        await Task.detached(priority: .utility) { () -> [SpeechVoice] in
            let process = Process()
            process.executableURL = SayCommand.executableURL
            process.arguments = ["-v", "?"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return []
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return SayCommand.parseVoiceList(String(decoding: data, as: UTF8.self))
        }.value
    }

    /// `say -v ?` の出力（例: `Kyoko               ja_JP    # こんにちは…`）を解析する。
    static func parseVoiceList(_ output: String) -> [SpeechVoice] {
        var voices: [SpeechVoice] = []
        var seen = Set<String>()
        for line in output.split(whereSeparator: \.isNewline) {
            let head = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let tokens = head.split(whereSeparator: \.isWhitespace)
            guard tokens.count >= 2, let locale = tokens.last else { continue }
            let name = tokens.dropLast().joined(separator: " ")
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            // `say -v` には音声名を渡すので、名前をそのまま ID にする
            voices.append(SpeechVoice(id: name, name: name, locale: String(locale)))
        }
        return SpeechVoice.sortedForDisplay(voices)
    }
}

nonisolated enum SpeechSynthesisError: LocalizedError {
    /// `say` が 0 以外の終了コードで終わった
    case commandFailed(status: Int32)
    /// `say` は正常終了したが、読み込める音声ファイルが残らなかった
    case unreadableOutput(underlying: Error?)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(status):
            return "say コマンドが異常終了しました（終了コード \(status)）。音声の設定を確認してください。"
        case let .unreadableOutput(underlying):
            if let underlying {
                return "合成した音声ファイルを読み込めませんでした: \(underlying.localizedDescription)"
            }
            return "合成した音声ファイルを読み込めませんでした。"
        }
    }
}

/// `say -o` で 1 文をファイルに合成する。
///
/// `say` にそのまま再生させる（ライブ再生）と、既定の声では各文の冒頭約 38 ms で振幅が 1 サンプルで
/// ほぼ 0 まで落ちて 2 ms かけて戻る不連続が毎回入り、「プツッ」というノイズになる
/// （`docs/speech-start-noise-investigation.md`）。ファイルに合成した波形にはこの不連続がないので、
/// 合成と再生を分け、再生はアプリ内の `SpeechPlayer` が `AVAudioEngine` で行う。
///
/// 速度（`say -r`）は指定せず、声の標準の速さで合成する。`-r` の効き方は声によって大きく違い、
/// 既定の声では 180〜400 語/分の間で長さがほとんど変わらない。速度は再生側で変える。
nonisolated enum SpeechSynthesizer {
    /// 合成するサンプルレート。`SpeechPlayer` の再生フォーマットと一致させる。
    static let sampleRate: Double = 48000

    /// 選べる声の一覧（日本語の声が先頭）
    static func availableVoices() async -> [SpeechVoice] {
        await SayCommand.availableVoices()
    }

    /// `request` を `url` に 48 kHz / Float32 / モノラルの WAV として合成する。
    /// タスクがキャンセルされたら `say` を終了し、`CancellationError` を投げる。
    /// 失敗時・キャンセル時は `url` のファイルを残さない。
    static func synthesize(_ request: SpeechRequest, to url: URL) async throws {
        var arguments: [String] = []
        if let voice = request.voice, !voice.isEmpty {
            arguments += ["-v", voice]
        }
        arguments += [
            "-o", url.path,
            "--file-format=WAVE",
            "--data-format=LEF32@\(Int(sampleRate))",
            // 本文は標準入力から渡す（"-" で始まる文がオプション扱いされるのを防ぐ）
            "-f", "-",
        ]

        do {
            let status = try await runSay(arguments: arguments, input: Data(request.text.utf8))
            // キャンセルで say を終了した場合も終了コードは返ってくるので、ここで区別する
            try Task.checkCancellation()
            guard status == 0 else {
                throw SpeechSynthesisError.commandFailed(status: status)
            }
            // 終了コードが 0 でも空のファイルになることがあるので、読み込めるか確かめる
            do {
                _ = try AVAudioFile(forReading: url)
            } catch {
                throw SpeechSynthesisError.unreadableOutput(underlying: error)
            }
        } catch {
            // 途中で終了した say が書きかけのファイルを残していても、失敗・キャンセル時は必ず消す
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// `say` を起動して標準入力に `input` を渡し、終了コードを返す。
    private static func runSay(arguments: [String], input: Data) async throws -> Int32 {
        let launcher = ProcessLauncher(executableURL: SayCommand.executableURL, arguments: arguments, input: input)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                launcher.launch { result in
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            launcher.cancel()
        }
    }
}

/// `Process` の起動・終了待ち・キャンセルをロックで保護する。
/// `Process.terminate()` は起動前に呼ぶと例外になるため、起動とキャンセルの順序をここで調停する。
private nonisolated final class ProcessLauncher: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let input: Data
    private var isCancelled = false
    private var isLaunched = false

    init(executableURL: URL, arguments: [String], input: Data) {
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        self.input = input
    }

    func launch(completion: @escaping @Sendable (Result<Int32, Error>) -> Void) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            completion(.failure(CancellationError()))
            return
        }
        let pipe = Pipe()
        process.standardInput = pipe
        process.terminationHandler = { finished in
            completion(.success(finished.terminationStatus))
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            lock.unlock()
            completion(.failure(error))
            return
        }
        isLaunched = true
        lock.unlock()

        // 1 文は SentenceSplitter で最大数百文字に制限しているので、パイプのバッファに収まる
        let writer = pipe.fileHandleForWriting
        try? writer.write(contentsOf: input)
        try? writer.close()
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        isCancelled = true
        if isLaunched, process.isRunning {
            process.terminate()
        }
    }
}
#endif
