#if os(macOS)
import AVFoundation
import AppKit
import Foundation

/// macOS 標準コマンド `/usr/bin/say` に関するユーティリティ
nonisolated enum SayCommand {
    static let executableURL = URL(fileURLWithPath: "/usr/bin/say")

    /// `say` の既定の声。新しいニューラル音声では AppKit の ID が空になるため、
    /// その場合だけ「読み上げコンテンツ」の設定を参照する。AVFoundation の既定声とは一致しない。
    static func defaultVoiceName() -> String? {
        let identifier = NSSpeechSynthesizer.defaultVoice
        if !identifier.rawValue.isEmpty {
            return NSSpeechSynthesizer.attributes(forVoice: identifier)[.name] as? String
        }
        let selections = CFPreferencesCopyAppValue(
            "SpokenContentDefaultVoiceSelectionsByLanguage" as CFString,
            "com.apple.Accessibility" as CFString
        ) as? [Any] ?? []
        return configuredVoiceName(in: selections, preferredLanguages: Locale.preferredLanguages)
    }

    /// この設定の形式は公開 API ではない。解釈できない場合は推測せず nil を返す。
    static func configuredVoiceName(in selections: [Any], preferredLanguages: [String]) -> String? {
        let voices = selections.compactMap { $0 as? [String: Any] }
        for language in preferredLanguages {
            let base = language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
            guard let selection = voices.first(where: { ($0["boundLanguage"] as? String) == language })
                ?? voices.first(where: { ($0["boundLanguage"] as? String) == base }),
                  let identifier = selection["voiceId"] as? String else { continue }
            if let voice = AVSpeechSynthesisVoice(identifier: identifier) { return voice.name }
            // say の一覧にも AVFoundation にも出ない Gryphon 音声の識別子。
            let pattern = #"^com\.apple\.ttsbundle\.gryphon-neural_(.+)_[a-z]{2,3}-[A-Z]{2}_(premium|enhanced|compact)$"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: identifier, range: NSRange(identifier.startIndex..., in: identifier)),
                  let range = Range(match.range(at: 1), in: identifier),
                  let qualityRange = Range(match.range(at: 2), in: identifier) else { return nil }
            let name = String(identifier[range])
            switch identifier[qualityRange] {
            case "premium": return String(localized: "\(name) Premium")
            case "enhanced": return String(localized: "\(name) Enhanced")
            default: return name
            }
        }
        return nil
    }

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
            return String(localized: "The say command failed (exit code \(status)). Check your voice settings.")
        case let .unreadableOutput(underlying):
            if let underlying {
                return String(localized: "Could not read the generated audio file: \(underlying.localizedDescription)")
            }
            return String(localized: "Could not read the generated audio file.")
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
    static func synthesize(_ request: SpeechRequest, to url: URL) async throws -> String? {
        // 合成時点の名前をファイルと一緒に保持する（先読み後に設定が変わっても表示を変えない）。
        let voiceName = request.voice.flatMap { $0.isEmpty ? nil : $0 } ?? SayCommand.defaultVoiceName()
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
            return voiceName
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
