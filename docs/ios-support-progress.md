# iOS 対応の作業記録

- 最終更新: 2026-11-03（2 回目の作業。シミュレータでの確認まで完了）
- ブランチ: `feature/ios-support`（`main` から作成。2 回目の作業までをコミット済み）
- 前提: 未マージだった `fix/speech-start-noise` を `main` に fast-forward でマージ済み（ローカルのみ、未 push）

## 読み上げライブラリの選定

iOS では `say` コマンド（`Process`）が使えないため、OS 標準の `AVSpeechSynthesizer` を使う。ただし `speak(_:)` は使わず、`write(_:toBufferCallback:)` で波形を受け取る。受け取った波形は 48 kHz / Float32 / モノラルの WAV に変換して書き出し、再生は macOS と共通の `SpeechPlayer`（`AVAudioEngine`）で行う。

この構成にした理由は次のとおり。

- macOS では、合成エンジンにライブ再生させると文頭に不連続（「プツッ」）が入った。合成と再生を分けると、この不連続は消えた（`docs/speech-start-noise-investigation.md`）。`speak(_:)` も合成エンジンが文ごとに再生を始める経路なので、同じ問題が起きない構成にそろえた。
- 先読み、文間の無音、停止時のフェードアウト、`AVAudioUnitTimePitch` による速度変更（0.5〜2.0 倍）を macOS と共有できる。
- 他社製の TTS（オンデバイスのニューラル TTS やクラウド API）は、AGENTS.md の「可能な限り標準コンポーネントを使う」方針と、モデルサイズ・通信・ライセンスの負担を考えて採用しなかった。

## 実施済み

| ファイル | 内容 |
|---|---|
| `SimpleTTS/SpeechTypes.swift`（新規） | 共通の `SpeechVoice`（id・表示名・ロケール）と `SpeechRequest`。`SayVoice` は廃止した |
| `SimpleTTS/SpeechSynthesizer.swift` | 全体を `#if os(macOS)` で囲んだ。声の一覧の型を `SpeechVoice` に変更し、`SpeechSynthesizer.availableVoices()` を追加した |
| `SimpleTTS/SpeechSynthesizer-iOS.swift`（新規） | iOS 版 `SpeechSynthesizer`。`write` で波形を集め、`AVAudioConverter` で 48 kHz に変換して WAV に書き出す。完了は「長さ 0 のバッファ」を優先し、`didFinish` には 300 ms の猶予を置く。15 秒間応答がなければタイムアウトにする。声の一覧からノベルティ音声を除き、品質（拡張・プレミアム）を名前に添える |
| `SimpleTTS/SpeechPlayer.swift` | `SIGPIPE` の無視を macOS 限定にした。iOS では `AVAudioSession` を `.playback` / `.spokenAudio` に設定し、エンジンの開始時に有効化、停止時に `notifyOthersOnDeactivation` 付きで無効化する。割り込みと出力先の消失（`oldDeviceUnavailable`）を `onAudioSessionEvent` で通知する |
| `SimpleTTS/NowPlayingController.swift`（新規、iOS） | ロック画面の「再生中」表示（タイトル、何文目か）と、リモートコマンド（再生・一時停止・切り替え・前後の文）を扱う |
| `SimpleTTS/ReaderModel.swift` | AppKit と UIKit を条件付きで import する。コピーは iOS では `UIPasteboard` を使う。`selectedVoiceName` と `saveProgress()`（バックグラウンド移行時のオートセーブ）を追加した。割り込みで止めたら、終了時に `shouldResume` が付いていれば再開する。出力先が消えたら一時停止する。`document`・`currentIndex`・`isPlaying` の `didSet` で「再生中」表示を更新する |
| `SimpleTTS/ContentView.swift` | 共通部分（ファイル選択・ドロップ・アラート）と、OS ごとの `splitView` に分けた。iOS では `preferredCompactColumn = .detail` にして、iPhone では読み上げ画面から始まるようにした。ツールバーは詳細カラムに置き、声と速度は常にポップオーバーにまとめる（`.presentationCompactAdaptation(.popover)`）。`scenePhase == .background` でオートセーブする。声の Picker のタグを `voice.id` に変更した |
| `SimpleTTS/SavesSidebar.swift` | `onLoad` コールバックを追加した（iPhone で読み込み後に読み上げ画面へ戻る）。iOS ではゴミ箱ボタンの代わりにスワイプで削除する |
| `SimpleTTS/MyApp.swift` | macOS は `Window`、iOS は `WindowGroup` にした。iOS では `UIApplication.willTerminateNotification` で位置を保存する。「開く…」コマンドは両方で共有する |
| `SimpleTTS/ReaderView.swift` | ファイル未選択時の説明文を iOS 向けに変えた |
| `SimpleTTS.xcodeproj/project.xcproj` | `SUPPORTED_PLATFORMS` に iphoneos・iphonesimulator を追加し、`SUPPORTS_MACCATALYST=NO`、`TARGETED_DEVICE_FAMILY=1,2` にした。iOS の展開ターゲットを 27.2 から 27.0 に下げた（使っている新しい API は 27.0 からあり、手元のシミュレータは 27.1 までしかない）。iOS SDK のときだけ `INFOPLIST_FILE` に `Config/Info-iOS.plist` を指定した |
| `Config/Info-iOS.plist`（新規） | 生成される Info.plist に足すキー。`UIBackgroundModes = audio` と `UIApplicationSupportsMultipleScenes = false`。`INFOPLIST_KEY_UIBackgroundModes` は Xcode の生成対象のキーではなく、ビルド結果に入っていなかったため、ファイルで渡す。`SimpleTTS/` フォルダの中に置くとリソースとしてコピーされるので、外に置いた |

### 2 回目の作業で直したこと

- 警告 2 件を解消した。
  - `BufferCollector` のウォッチドッグのロックを同期関数 `activityStatus()` に切り出した。
  - 割り込みの通知を iOS 27 の `didBecomeInactiveNotification`（`DeactivationContext.source == .system` のときだけ割り込みとして扱う。自分で無効にしたときにも届くため）と `resumptionRecommendationNotification` に移行した。
- オーディオセッションの有効化・無効化を非同期版（`activate(options:)`、`deactivate(options:completionHandler:)`）にした。同期版の `setActive` は、メインスレッドで呼ぶと「AVAudioSession Hang Risk」のランタイム警告が出た。有効化は `speak` の中で、合成が終わってからエンジンを起動する前に待つ。待つあいだに停止・移動されたら流さない。
- `mediaServicesWereResetNotification` を受けたら、エンジンとノードを作り直して読み上げを一時停止の状態にする（`SpeechPlayer.AudioSessionEvent.mediaServicesReset`）。合成済みのファイルは残す。
- `AVSpeechSynthesisVoice.speechVoices()` と `AVSpeechSynthesisVoice(identifier:)` を GCD のキューで呼ぶようにした。Swift Concurrency のスレッドから呼ぶと「unsafeForcedSync called from Swift Concurrent context」のランタイム警告が出た。
- iPad で複数ウィンドウを作れないようにした（上記の Info.plist）。1 つの `ReaderModel` を共有しているので、複数ウィンドウでは「開く」のシートが両方に出るなどの不具合になる。macOS の `Window` と同じ扱い。
- iPhone の横向きで、読み上げ画面の中身が高さに収まらず、見出しがナビゲーションバーのボタンに、状態表示がホームインジケータに重なっていた。読み上げ画面の高さが 420pt 未満のときは上下の余白と大写しの文の最小の高さを詰める（`ReaderView.shortHeightThreshold`）。macOS はウィンドウの最小の高さが 480pt なので影響しない。

## 検証状況

- macOS 向けビルド（`platform=macOS`）: **成功**、警告なし。macOS 版の起動と読み上げは未確認（ビルドのみ）。
- iOS シミュレータ向けビルド: **成功**、警告なし。
- ビルドした Info.plist に `UIBackgroundModes = [audio]` と `UIApplicationSupportsMultipleScenes = false` が入っていることを確認した。
- シミュレータ（iPhone 18 Pro、iOS 27.0）で確認したこと。
  - 起動すると読み上げ画面が出る。「ファイルを開く…」とツールバーのフォルダボタンでファイル選択が開き、.txt を読み込める。
  - 3 文を最後まで読み上げた。3 文とも長さ 0 のバッファの直後に完了しており、タイムアウトはなかった。声に Kyoko を選んでも同じ。
  - 声の一覧（日本語の声が先頭）と速度のスライダーがポップオーバーで出る。
  - 再起動すると前回の位置が復元される。
  - セーブの追加、セーブ一覧（戻るボタン）、スワイプでの削除（確認あり）。
  - 縦向き・横向きのレイアウト（横向きは上記の修正後）。
  - ログに Hang Risk と unsafeForcedSync の警告が出なくなった。
- iPad Air 11 インチ（iOS 27.0）で、縦向きのサイドバーの開閉と分割表示を確認した。
- 音そのもの（文頭のノイズ・欠落）、バックグラウンド再生、ロック画面からの操作、割り込みと再開、ヘッドフォンの取り外しは、シミュレータでは確認できないので未確認。

## 残作業

1. 実機で確認する（シミュレータでは確認できない項目）。
   - 文頭のノイズや欠落がないこと。可能であれば `tmp/noise` の手順に準じて波形も確認する。
   - `AVSpeechSynthesizer.write` が、こちらで有効にしたオーディオセッションを無効化しないこと（無効化すると `didBecomeInactiveNotification` が `source == .system` で届き、読み上げが止まるはず）。
   - バックグラウンド再生、ロック画面からの操作、電話の着信後の再開、ヘッドフォンを外したときの一時停止。
   - 非同期の無効化の直後に次の文を再生したとき（一時停止してすぐ再生）に、有効化が失敗しないこと。
2. macOS 版を起動して、読み上げ・速度変更・セーブが従来どおり動くことを確かめる（ビルドだけ確認済み）。
3. 未対応のもの。
   - iOS 向けの起動スクリプト（`start.sh` は macOS 専用）。
   - Dynamic Type への対応（大写しの文は固定サイズ）。
   - 削除の確認ダイアログは一覧全体に付けているため、iPhone ではポップオーバーの矢印が削除する行ではなく一覧の上端を指す。行ごとに付けると、スワイプ操作から開いたときに表示されなかった。
   - セーブ一覧の日時が英語の書式で表示される（開発言語が `en` で、日本語のローカライズがないため。macOS 版も同じ）。
