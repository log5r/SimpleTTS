import Foundation

/// 読み上げに使える声
nonisolated struct SpeechVoice: Identifiable, Hashable, Sendable {
    /// 合成時に声を指定する値。macOS では `say -v` に渡す音声名、iOS では `AVSpeechSynthesisVoice.identifier`。
    let id: String
    /// 画面に表示する名前
    let name: String
    let locale: String

    /// 日本語の声を先頭に、名前順に並べる。
    static func sortedForDisplay(_ voices: [SpeechVoice]) -> [SpeechVoice] {
        voices.sorted { lhs, rhs in
            let lhsRank = lhs.locale.hasPrefix("ja") ? 0 : 1
            let rhsRank = rhs.locale.hasPrefix("ja") ? 0 : 1
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

/// 1 文の合成条件。合成済みファイルのキャッシュのキーにも使う。
nonisolated struct SpeechRequest: Hashable, Sendable {
    let text: String
    /// 声の指定（`SpeechVoice.id`）。nil または空ならシステム既定の声
    let voice: String?
}
