#if os(iOS)
import MediaPlayer

/// ロック画面やコントロールセンターの「再生中」表示と、そこからの操作（再生・一時停止・前後の文）をつなぐ。
///
/// バックグラウンドで読み上げを続けられるようにしているので、画面を消したあとも操作できるようにする。
final class NowPlayingController {
    struct Actions {
        let play: () -> Void
        let pause: () -> Void
        let togglePlayPause: () -> Void
        let next: () -> Void
        let previous: () -> Void
    }

    struct State: Equatable {
        let title: String
        let sentenceIndex: Int
        let sentenceCount: Int
        let isPlaying: Bool
        let canStepBackward: Bool
        let canStepForward: Bool
    }

    private var lastState: State?
    private var isConfigured = false
    private let actions: Actions

    init(actions: Actions) {
        self.actions = actions
    }

    /// 表示を更新する。文書がないときは nil を渡して表示を消す。
    func update(_ state: State?) {
        guard state != lastState || state == nil else { return }
        lastState = state
        let center = MPNowPlayingInfoCenter.default()
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.isEnabled = state != nil
        commands.pauseCommand.isEnabled = state?.isPlaying == true
        commands.togglePlayPauseCommand.isEnabled = state != nil
        commands.previousTrackCommand.isEnabled = state?.canStepBackward == true
        commands.nextTrackCommand.isEnabled = state?.canStepForward == true
        guard let state else {
            center.nowPlayingInfo = nil
            return
        }
        configureCommandsIfNeeded()

        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: state.title,
            MPMediaItemPropertyArtist: "\(state.sentenceIndex + 1) / \(state.sentenceCount)文目",
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: state.isPlaying ? 1.0 : 0.0,
            // 文書名の表示を許可した場合も、システムのコンテンツ提案には使わせない。
            MPNowPlayingInfoPropertyExcludeFromSuggestions: true,
        ]
    }

    /// リモートコマンドは、最初に文書を表示したときに登録する（何も開いていない間は操作を出さない）。
    private func configureCommandsIfNeeded() {
        guard !isConfigured else { return }
        isConfigured = true
        let commands = MPRemoteCommandCenter.shared()
        let actions = actions
        commands.playCommand.addTarget { _ in
            MainActor.assumeIsolated { actions.play() }
            return .success
        }
        commands.pauseCommand.addTarget { _ in
            MainActor.assumeIsolated { actions.pause() }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { _ in
            MainActor.assumeIsolated { actions.togglePlayPause() }
            return .success
        }
        commands.nextTrackCommand.addTarget { _ in
            MainActor.assumeIsolated { actions.next() }
            return .success
        }
        commands.previousTrackCommand.addTarget { _ in
            MainActor.assumeIsolated { actions.previous() }
            return .success
        }
    }
}
#endif
