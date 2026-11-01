import Foundation

/// `say -v ?` で取得できる音声
nonisolated struct SayVoice: Identifiable, Hashable, Sendable {
    let name: String
    let locale: String
    var id: String { name }
}

/// macOS 標準コマンド `/usr/bin/say` に関するユーティリティ
nonisolated enum SayCommand {
    static let executableURL = URL(fileURLWithPath: "/usr/bin/say")

    /// インストール済みの音声一覧を取得する（日本語音声を先頭に並べる）。
    static func availableVoices() async -> [SayVoice] {
        await Task.detached(priority: .utility) { () -> [SayVoice] in
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
    static func parseVoiceList(_ output: String) -> [SayVoice] {
        var voices: [SayVoice] = []
        var seen = Set<String>()
        for line in output.split(whereSeparator: \.isNewline) {
            let head = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let tokens = head.split(whereSeparator: \.isWhitespace)
            guard tokens.count >= 2, let locale = tokens.last else { continue }
            let name = tokens.dropLast().joined(separator: " ")
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            voices.append(SayVoice(name: name, locale: String(locale)))
        }
        return voices.sorted { lhs, rhs in
            let lhsRank = lhs.locale.hasPrefix("ja") ? 0 : 1
            let rhsRank = rhs.locale.hasPrefix("ja") ? 0 : 1
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

/// `say` コマンドを 1 文ごとに起動して読み上げる。
///
/// 停止はプロセスの終了（SIGTERM）で行う。`stop()` 後に届いた終了通知は世代番号で破棄するので、
/// `onFinish` は「その文を最後まで読み終えた（または異常終了した）」ときだけ呼ばれる。
final class SayCommandSpeaker {
    private var process: Process?
    private var generation = 0

    init() {
        // 終了済みの say の stdin に書き込んでもアプリが落ちないようにする
        signal(SIGPIPE, SIG_IGN)
    }

    func speak(
        _ text: String,
        voice: String?,
        rate: Int,
        onFinish: @escaping @MainActor @Sendable (_ status: Int32) -> Void
    ) throws {
        stop()
        generation &+= 1
        let token = generation

        let process = Process()
        process.executableURL = SayCommand.executableURL
        var arguments = ["-r", String(rate)]
        if let voice, !voice.isEmpty {
            arguments += ["-v", voice]
        }
        // 本文は標準入力から渡す（"-" で始まる文がオプション扱いされるのを防ぐ）
        arguments += ["-f", "-"]
        process.arguments = arguments

        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.process = nil
                onFinish(status)
            }
        }

        try process.run()
        self.process = process

        // 1 文は SentenceSplitter で最大数百文字に制限しているので、パイプのバッファに収まる
        let writer = input.fileHandleForWriting
        try? writer.write(contentsOf: Data(text.utf8))
        try? writer.close()
    }

    func stop() {
        generation &+= 1
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
    }
}
