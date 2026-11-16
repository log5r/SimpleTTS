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

### iPhone Duo への対応（2026-11-16）

iPhone Duo（`iPhone19,4`）は折りたためる iPhone で、外側の画面（シミュレータでは 1398×2034 px、@3x）と内側の画面（2007×2853 px、横向きが標準）を持つ。外側の画面では、ステータスバーとナビゲーションバーのボタンが画面の端に縦に並ぶ（縦のバー。iOS 27.1 から）。

| ファイル | 内容 |
|---|---|
| `SimpleTTS/FoldSplit.swift`（新規） | 折り目の領域（`ReservedRegion.Kind.division`）が読み上げ画面を端から端まで横切り、両側に 340pt 以上残るときに、2 つの区画と折り目の位置を求める。折り目が縦なら左右に、横なら上下に分ける。幅 0 の線として届いた折り目も扱う |
| `SimpleTTS/ReaderView.swift` | `GeometryProxy.reservedRegions(kind: .division)`（iOS 27.1 から）で折り目を調べ、分けられるときは先頭側（左・上）に文、末尾側（右・下）に見出しと操作列を置いて、折り目の上には何も置かない。折り目がなければ従来どおり。開閉による折り目の領域の変化は `GeometryReader` がそのまま反映する（作り直しはしない。繰り返し 2/3 で変更）。ヒンジが動いている間（`onHingeChange`、`HingeMotion`）と止まってから 0.5 秒は、位置スライダーへの入力を受け付けず、ドラッグ中の仮位置を捨てる。ドラッグ中に読み上げ画面の大きさが変わった（回転）ときも仮位置を捨て、指を離すまでそのドラッグを無視する（繰り返し 3/3）。操作列と見出しは、文字を大きくして 1 行に収まらないときに 2〜3 行に組み替え、区画からはみ出さない（`ViewThatFits`、繰り返し 3/3）。macOS では問い合わせない |
| `SimpleTTS/FoldSplit.swift` の `HingeMotion` | ヒンジが動いたとみなす条件（開き具合の段階の変化、または角度の 1 度以上の変化）|
| `SimpleTTS/ContentView.swift` | iOS では「声と速度」のポップオーバーの矢印の向きをシステムに任せる（`arrowEdge: nil`）。外側の画面ではボタンが縦のバーにあるため。macOS は従来どおり下向き |
| `Tests/FoldSplitTests.swift`、`scripts/test-fold-split.sh`（新規） | 区画の計算のテスト |

確認できたこと（シミュレータ「iPhone Duo」、iOS 27.2）:

- 外側の画面で、読み上げ画面（約 382×562pt、`.minimal`）の文・操作列・ツールバー（縦のバー）がはみ出さずに表示される。変更の前後で表示は同じ。
- 外側の画面では `reservedRegions` が `.division`・`.occlusion` とも空（`.includeInactive` を付けても空）。分割しない。
- 分割したレイアウトの見た目は、一時的に偽の折り目を渡したビルドを iPad Air 11 インチで表示して確認した（左右・上下とも）。確認用のコードは残していない。

確認できていないこと:

- 内側の画面での表示。Xcode 27.2 に Simulator.app がなく、`simctl` からは開閉を操作できない（外側の画面の電源を切っても内側の画面にアプリが移らず、内側の画面だけで起動すると SpringBoard が落ちた）。実際の折り目の位置と幅、`isActive` が開き具合でどう変わるか、サイドバーを出しているときに詳細カラムへ折り目がかかるかは未確認。
- 開閉したときに読み上げが途切れないこと、ポップオーバーやシートを開いたまま開閉したときの表示。
- 縦のバーにあるボタンから開いたポップオーバーの位置（シミュレータをタップできなかった）。

### 敵対的レビュー（2026-11-16）

レビュー判定: 以下の2点を修正済み。ただし内側画面の実動作は未検証なので、Duo対応の受け入れ完了とはしない。

- **P2・開閉後にスライダーの仮位置が残る可能性**（静的レビュー）: `HingeChangeObserver` の `.id` は `GeometryReader` 以下を作り直すが、`scrubbingIndex` は親の `ReaderView` にあり残る。ドラッグ中に Slider が消え、編集終了コールバックが届かない場合、番号表示が古い仮位置に固定され、以降の操作も仮位置の更新に入ってしまう。`positionSlider.onDisappear` で仮位置を破棄するよう修正。通常／分割レイアウトの切り替えにも適用する。実際のジェスチャー中断は未検証。
- **P2・上下分割で操作列の幅を確認していない**（回帰テストで再現）: 300×860pt、横折り目 y=420・高さ20pt でも、上下の高さが340pt以上なので分割していた。操作列の必要幅を満たすよう、上下分割にも幅の下限を追加。追加テストは修正前に失敗し、修正後に成功。

この工程で変更したファイル:

- `SimpleTTS/ReaderView.swift`: スライダー消失時の仮位置の破棄。
- `SimpleTTS/FoldSplit.swift`: 上下分割時の最小幅チェック。
- `Tests/FoldSplitTests.swift`: 幅不足の上下分割、下限ちょうど／0.5pt不足、ゼロ高さの横折り目を追加。
- `docs/ios-support-progress.md`: レビュー結果と引き継ぎ。

再検証:

- Xcode 27.2、Debug、署名なし。iOS Simulator（generic destination）とmacOSのビルド成功。ログ: `build/review/ios-build.log`、`build/review/mac-build.log`。
- 両ビルドに `Metadata extraction skipped, no AppIntents.framework dependency found` が1件ずつ出た。コンパイルエラーはないが、この再検証を「警告なし」とは報告しない。
- `test-fold-split.sh`、`test-storage-import.sh`、`test-reader-privacy.sh` の3本成功。`git diff --check` 成功。
- SDKの宣言と [AppleのSwiftUI更新情報](https://developer.apple.com/documentation/updates/swiftui) で `reservedRegions` / `onHingeChange` の存在を照合した。
- 今回はアプリを起動していない。macOS版は既存データの保存先を使用するため。Simulator.app が存在しないことも再確認した。前工程の外側画面・疑似折り目の表示結果は引き継ぎ情報であり、この工程で再確認した結果ではない。

次工程の必須確認:

1. Duoの内側画面で、全開／半開、回転、サイドバー表示切り替え時の折り目と画面配置を確認する。分割しない条件では従来のレイアウトになるため、サイドバー表示中の折り目との重なりも確認する。
2. 読み上げ中・一時停止中のそれぞれで位置スライダーをドラッグしながら開閉／回転する。操作が中断された後、表示番号が実際の読み上げ位置に戻り、VoiceOverの増減と再ドラッグも機能することを確認する。
3. 読み上げが開閉で途切れないこと、およびシート・声と速度のポップオーバーを表示したまま開閉したときの表示を確認する。
4. 内側画面の文字サイズ拡大時や長文・メモ表示時にも、折り目や操作列へのはみ出しがないことを確認する。

`install.sh` の既存変更は未編集。コミット・外部公開は行っていない。

### レビュー対応（2026-11-16、繰り返し 1/3）

前工程の指摘 2 点は、どちらも妥当で、前工程で入れた修正が正しいことを確認した。この工程ではソースを変えていない。

- スライダーの仮位置: `positionSlider` の `.onDisappear` で `scrubbingIndex` を捨てる。ヒンジの状態が変わると `.id` で `GeometryReader` 以下が作り直され、古い Slider の `onDisappear` が呼ばれる。そのあと編集終了のコールバックが届いても `scrubbingIndex == nil` なので何も起きない。届いたのが先なら通常どおり移動する。どちらの順でも矛盾しない。
- 上下分割の幅: `size.width >= minimumPaneLength` の判定と、追加したテスト 4 件は妥当。
- 追加で確認したこと: 読み上げ画面の中（`ReaderView`）にはポップオーバー・シート・アラートがない（メモの編集・メモの一覧・声と速度は `ContentView` 側にある）。そのため、ヒンジの状態が変わって作り直しても、開いている画面は閉じない。`ControlBar` にも `@State` はない。

再検証:

- iPhone Duo シミュレータ（iOS 27.2）向けのビルド成功（`build/review/duo-build.log`）。macOS のビルド成功（`build/review/mac-build-2.log`）。どちらも AppIntents のメタデータ抽出をスキップした警告が 1 件ずつ出た（前工程と同じ）。
- `test-fold-split.sh`、`test-storage-import.sh`、`test-reader-privacy.sh` の 3 本と `git diff --check` が成功した。
- Duo シミュレータで外側の画面を確認した。アプリの領域に試験用の文書とオートセーブ（`saves.json`、`Documents/<SHA-256>.txt`）を置き、前回の位置の復元を使って読み上げ画面を出した。文・操作列・縦のバーがはみ出さずに表示された（`build/review/duo/outer-1.png`）。
- 内側の画面は、今回も表示できなかった。`simctl io enumerate` では内側の画面（2007×2853）の電源は「On」だが、スクリーンショットは真っ黒だった。外側の画面の電源を切っても同じだった（`inner-1.png`、`inner-2.png`）。ヒンジの状態を変える手段が `simctl` になく、Simulator.app もない。確認後、外側の画面の電源を戻し、シミュレータを停止した。

内側の画面の実動作（前工程の「次工程の必須確認」1〜4）は未確認のまま。Simulator.app がある環境か実機での確認が必要。

### レビュー対応確認（2026-11-16、繰り返し 1/3）

判定: **CONTINUE**。指摘 2 点のコード修正は確認でき、新たなコード上の指摘はない。ただし、上記の必須確認 1〜4 は未完了であり、内側画面の動作に関するレビュー項目を解消したとは判断しない。

- `ReaderView.positionSlider.onDisappear` が親に残る `scrubbingIndex` を破棄することと、編集終了時に値がなければ移動しないことをコードで確認した。実際のジェスチャー中断時のコールバック順序は未検証。
- `FoldSplit` の上下分割で幅の下限も判定することを確認し、幅不足・境界値を含む `test-fold-split.sh` が成功した。
- `test-storage-import.sh`、`test-reader-privacy.sh`、`git diff --check` も成功した。
- iPhone Duo Simulator と macOS の Debug・署名なしビルドを再実行し、両方成功した。各ビルドに AppIntents メタデータ抽出スキップの警告が 1 件ある。ログ: `build/review/verification-duo-build.log`、`build/review/verification-mac-build.log`。
- Xcode の `Contents/Developer/Applications` が存在せず、`simctl help`、`help io`、`help ui` にヒンジ操作がないことを再確認した。今回はアプリの起動・表示確認は実施していない。前工程の画像を今回の実動作確認の代わりにはしていない。

今回の変更はこの記録のみ。権限不足ではなく、内側画面を操作できる検証環境が不足している。次工程では Simulator.app のある環境または実機で必須確認 1〜4（配置、ドラッグ中断、読み上げ・提示画面の継続、大きな文字・長文・メモ）を実施し、結果を記録する必要がある。

### レビュー対応（2026-11-16、繰り返し 2/3）

Xcode 27 では Simulator.app の代わりに `/Applications/Xcode.app/Contents/Applications/DeviceHub.app` がある（ユーザーの指摘）。DeviceHub で iPhone Duo を選ぶと、下部に「Closed」「Partially Open」「Open」のボタンがあり、内側の画面を表示・開閉できた。必須確認 1〜4 を実施し、2 件の不具合を見つけて直した。

操作の方法（次の工程でも使える）:

- 開閉: System Events からボタンを押す（`perform action "AXPress" of button 5|6|7 of group 3 of splitter group 1 of group 1 of splitter group 1 of group 1 of window 1`。5=Closed、6=Partially Open、7=Open）。マウスを使わないので、ドラッグしたまま開閉できる。
- タップとドラッグ: System Events の `click at` はシミュレータに届かないため、CGEvent でマウスを送る小さなツールを一時フォルダに作って使った（リポジトリには入れていない）。回転は ⌘← / ⌘→。
- 内側の画面の撮影: `xcrun simctl io booted screenshot --display=3`。
- 試験用の文書: アプリの領域に `long-check.txt`（長文、10 文）と、それを指すオートセーブを置いた（`saves.json` を置き換えた。前の `fold-check.txt` の `saves.json` は一時フォルダに退避）。2 文目にメモを付けた。いずれもシミュレータの中だけ。

見つけて直した不具合:

1. **P1・半開から全開にすると、ドラッグ中の位置へ勝手に移動する**（読み上げ中の 2 回で再現。全開→半開では起きない）。一時的なログで順序を調べた。開閉の途中は `onHingeChange` が約 16ms ごとに届くが、開き具合の段階は `partiallyOpen` のままなので `.id` は変わらない。ところが最初の通知の直後に、ドラッグ中のスライダーへ編集終了が届き、残っていた仮位置へ移動していた。その後も毎フレーム「編集開始→値の設定→編集終了」が届き、動いていくスライダーの下に止まった指の位置へさらに移動した。`onDisappear` は `fullyOpen` になって作り直されるときに初めて呼ばれるので、間に合わない。
   - 修正: ヒンジが動いたら（`HingeMotion`）仮位置を捨て、止まってから 0.5 秒（`hingeSettleDelay`）は、スライダーの編集開始と値の設定を無視する。`.disabled` も付けたが、それだけでは編集の通知が止まらなかったので、通知の処理でも判定している。ヒンジの通知は、それに伴う編集終了より先に届く（ログで確認）。
   - 角度の揺れで止まり続けないよう、開き具合の段階が変わるか、前回動いたとみなしたときから角度が 1 度以上変わったときだけ「動いた」とする。シミュレータでは 1 回の通知で約 7 度変わった。実機の揺れの大きさは未確認。
2. **P2・「声と速度」のポップオーバーが、開き具合が変わると閉じる**。`.id(hingeStatus)` を外した試験ビルドでは閉じなかった。また `.id` がなくても、半開（縦・横）・全開・閉じる→半開のどれでも、分割の有無と向きは `GeometryReader` がそのまま正しく反映した。そこで `.id` による作り直しをやめた（`HingeChangeObserver` を `HingeMotionObserver` に置き換えた）。

確認できたこと（iPhone Duo シミュレータ、iOS 27.2、修正後のビルド）:

1. 配置
   - 横向き: 全開は分割なし（従来どおり）。半開は左に文、右に見出しと操作列。折り目をまたぐ要素はない（`build/review/duo2/inner-half-1.png`）。
   - 縦向き: 全開は分割なし。半開は上に文、下に見出しと操作列。
   - 横向き半開でサイドバーを出すと、サイドバーが左半分、読み上げ画面が右半分に収まり、分割しない（`inner-half-sidebar-1.png`）。縦向きではサイドバーが自動で閉じる。
   - 回転して全開・半開を行き来しても、分割の有無と向きが追従する。
2. ドラッグ中の開閉
   - 読み上げ中・半開→全開: 仮表示 4/6 から実際の位置（3/6）に戻り、指を離しても移動しない（`fix2-t1-play-half-open/all.png`、ログでも確認）。
   - 一時停止中・半開→全開: 4/6 から 2/6 に戻る（`fix2-t4-pause-half-open`）。
   - 読み上げ中・全開→半開: 5/6 から 3/6 に戻り、読み上げは続く（`fix2-t6-play-open-half`）。
   - 横向きでも同じ（`final-drag`: 6/10 から 1/10 に戻り、そのまま 2/10 へ読み進む）。
   - ヒンジが止まった後は、再ドラッグで移動できる（`fix2-redrag.png`）。
   - 一時停止中・全開→半開は、修正前のビルドで 4/6 から 2/6 に戻ることを確認した（この方向は修正前から問題なし）。修正後は、試行のつまみの位置がずれていてドラッグできず、未確認。
3. 読み上げと提示画面の継続
   - 読み上げ中に半開→閉じる→半開としても止まらない（`close/all.png`）。閉じている間は外側の画面で読み上げが続く。
   - メモの編集シートを開いたまま全開・半開にしても閉じず、入力中の文字も残る（`sheet-posture.png`）。
   - 「声と速度」のポップオーバーは、修正後は全開→半開→全開でも開いたままで、縦のバーに合わせて位置が変わる（`final-popover/all.png`）。
4. 文字サイズ・長文・メモ
   - 標準と xxxL（アクセシビリティサイズではない最大）では、横・縦の半開とも、長い文・メモ・操作列が各区画に収まり、折り目をまたがない（`inner-note-half-land-xxxl.png`、`inner-note-half-port-xxxl.png`）。
   - アクセシビリティサイズの最大（AX5）では、右の区画の操作列が左にはみ出し、折り目をまたぐ（`inner-note-half-land-ax.png`）。全開（分割なし）でも、見出しがナビゲーションバーに重なり、操作列が画面からはみ出す（`inner-note-open-land-ax.png`）。既存の「Dynamic Type 未対応」の症状で、Duo 対応で生じたものではないので、この工程では直していない。大写しの文のメモボタンが本文に重なるのも同じ。

この工程で変更したファイル:

- `SimpleTTS/ReaderView.swift`: `.id` による作り直しをやめた。ヒンジが動いている間は仮位置を捨て、位置スライダーへの入力を無視する（`isHingeMoving`、`hingeDidMove`、`HingeMotionObserver`）。
- `SimpleTTS/FoldSplit.swift`: `HingeMotion`（動いたとみなす判定）を追加。
- `Tests/FoldSplitTests.swift`: `HingeMotion` のテスト（最初の通知、変化なし、閾値の手前・ちょうど、段階の変化、ヒンジの有無・角度の有無の変化）。
- `docs/ios-support-progress.md`: この記録と、変更内容の表の更新。

再検証:

- iPhone Duo シミュレータ向けと macOS 向けのビルド成功（`build/review/duo2/final-duo-build.log`、`final-mac-build.log`）。どちらも AppIntents のメタデータ抽出をスキップした警告が 1 件（従来どおり）。
- `test-fold-split.sh`（`HingeMotion` を含む）、`test-storage-import.sh`、`test-reader-privacy.sh` の 3 本と `git diff --check` が成功。
- 一時的なログ（`NSLog`）と `.id` を外した試験ビルドは調査だけに使い、ソースには残していない。

未確認・残り:

- 実機での動作。特に、指を画面に置いたまま開閉したときのタッチの扱い（シミュレータではマウスを押したままの開閉で再現した）と、手に持ったときの角度の揺れの大きさ（1 度の閾値が妥当か）。
- VoiceOver の増減による移動（シミュレータでは VoiceOver を操作していない）。コード上は、ヒンジが動いている間以外は従来どおり。
- アクセシビリティサイズの文字（上記 4）。Dynamic Type 対応として別に扱う。
- 閉じる→開くと、横向きで自分で開いたサイドバーが重ねて表示されることがある。`NavigationSplitView` の `columnVisibility` が残るためで、今回の変更とは関係ない。

### レビュー対応確認（2026-11-16、繰り返し 2/3）

判定: **CONTINUE**。ヒンジ移動中の意図しないシークとポップオーバー消失への修正はコードで確認した。ただし、文字拡大時の折り目との重なりが残っており、「指摘事項が存在しない」という終了条件は満たしていない。

- 修正確認: `hingeDidMove` が仮位置を破棄し、編集開始・値設定を抑止する。最後の有意なヒンジ変化から500ms待つタスクは次の変化でキャンセルされる。`HingeMotionObserver` は最後に移動と判定した角度を保持するため、小さな角度変化も累積して判定される。`.id` による作り直しは除去済み。今回、アプリの起動・ジェスチャー操作による再検証は行っておらず、実動作結果は前工程の記録と区別する。
- **P2・文字拡大時に操作列が折り目をまたぐ（未解決）**: 前工程の実画像 `build/review/duo2/inner-note-half-land-ax.png` を閲覧し、前の文へ戻るボタンが左右区画の境界にはみ出すことを確認した。現在の `ReaderView.swift` の `foldedLayout` は操作領域を固定幅にするが、`ControlBar` の横一列の `.fixedSize()`（546行）はその幅より大きくなれる。`FoldSplit.minimumPaneLength` も文字サイズを考慮しない。全開にも文字拡大の既存問題があることは、今回導入した分割領域で折り目を避けるという必須確認4の達成を示さない。次工程では操作列の折り返し・縦配置など、拡大しても区画内で全ボタンを操作できる配置に対応し、縦横の半開・最大アクセシビリティサイズで検証する。クリッピングのみでボタンを隠す対応は不可。
- 検証の残り: 修正後の一時停止中・全開→半開のドラッグ中断、ドラッグ中の回転、VoiceOverによる中断後の増減は、前工程の記録では完了を確認できない。次工程で実施し、実際の位置への復帰と再操作を記録する。実機のタッチ挙動と角度の揺れは引き続き未確認。

今回の再検証:

- `test-fold-split.sh`、`test-storage-import.sh`、`test-reader-privacy.sh` の3本成功。
- iPhone Duo Simulator / macOS のDebug・署名なしビルド成功。各1件、従来と同じAppIntentsメタデータ抽出スキップの警告あり。ログ: `build/review/verification2-duo-build.log`、`build/review/verification2-mac-build.log`。
- `git diff --check` 成功。

今回の変更ファイルは `docs/ios-support-progress.md` のみ。コードはレビュー対象のまま保持した。コミット・外部公開・シミュレータ内データの変更は行っていない。権限不足はない。

### レビュー対応（2026-11-16、繰り返し 3/3）

前工程の指摘（文字拡大時に操作列が折り目をまたぐ）は妥当と判断して直した。残っていた実動作確認のうち、ドラッグ中の回転で新たに不具合を見つけて直した。

DeviceHub の操作方法（前工程の記録から変わった点）:

- 下部の「Closed / Partially Open / Open」のボタンはなく、ヒンジの角度のスライダー（0〜180、`slider 1 of group 3 of splitter group 1 of group 1 of splitter group 1 of group 1 of window 1`）だけがある。AX で値を設定すると表示は動くが、シミュレータには届かない（アプリは半開のまま）。マウスで実際にドラッグしたときだけ開閉する。180 で全開、約 110 で半開。
- 回転は メニュー「Controls」→「Rotate Left / Rotate Right」を System Events で選ぶ（マウスを使わない）。
- 文字サイズは `xcrun simctl ui booted content_size accessibility-extra-extra-extra-large` など。確認後 `large` に戻した。
- タップ・ドラッグは前工程と同じく、一時フォルダに作った CGEvent のツール（リポジトリには入れていない）。

直したこと:

1. **P2・文字拡大時に操作列・見出しが区画からはみ出す**（前工程の指摘）。`ControlBar` は `ViewThatFits(in: .horizontal)` で「横一列」→「再生系の 3 つ／セーブ・コピーの 2 行」→「再生／前後／セーブ・コピーの 3 行」のうち収まるものを選ぶ。どの並べ方でもすべてのボタンを表示し、隠さない。最後の並べ方の幅は再生ボタン 1 つ分なので、`FoldSplit.minimumPaneLength`（340pt）の区画に AX5 でも収まる。見出しの行（文書アイコン・題名・状態・文番号・「メモ一覧」）も、1 行に収まらないときは文番号と「メモ一覧」を 2 行目に移す。題名は省略して縮めるので、収まるかどうかの判定には含めない（理想の幅を 0 にした）。分割しないレイアウトにも同じ部品を使うので、全開・外側の画面での AX サイズのはみ出しも直った。
2. **P2・ドラッグ中に回転すると、表示と違う位置へ移動する**（今回の確認で発見）。一時停止中に 5/10 までドラッグしたまま回転すると、見出しは 5/10 のままだが、指を少し動かすと、新しい配置で指の下にある位置へつまみが飛び、離すと 2/10 へ移動した（`build/review/duo3/rot/`）。読み上げ画面の大きさがドラッグ中に変わったら、仮位置を捨て、指を離すまでそのドラッグの入力を無視するようにした（`ignoresInterruptedDrag`。編集終了か、スライダーが消えたときに戻す）。ドラッグしていなければ何もしないので、回転のたびにスライダーが無効の表示になることはない。

確認できたこと（iPhone Duo シミュレータ、iOS 27.2、修正後のビルド。画像は `build/review/duo3/`）:

- AX5（最大のアクセシビリティサイズ）
  - 横向き・半開: 右の区画に見出し 2 行と操作列 3 行が収まり、折り目をまたがない。長文とメモのある 5/10 でも同じ（`half-land-ax5.png`、`half-land-ax5-note.png`。前工程の `duo2/inner-note-half-land-ax.png` と同じ状態）。
  - 縦向き・半開: 上の区画に文、下の区画に見出し 1 行と操作列 3 行が収まる（`half-port-ax5-note.png`）。
  - 横向き・半開でサイドバーを出したとき（分割しない）: 右半分の読み上げ画面に見出し 2 行と操作列 3 行が収まる（`half-land-sidebar-ax5.png`）。
  - 全開（分割なし）・外側の画面: 操作列が 2 行になり、画面からはみ出さない（`hub8.png`、`hub3.png`）。
- AX3 の横向き・半開: 操作列はアイコンのみの 1 行で右の区画に収まる（`half-land-ax3.png`）。
- 標準の文字サイズ（large）の全開: 操作列は従来どおり 1 行（`hub12.png`）。
- ドラッグ中の回転（修正後）
  - 一時停止中: 縦向き・全開で 10/10 から 6/10 までドラッグ → 回転 → 見出しは実際の 10/10 に戻り、指を動かして離しても移動しない（`rot2/1-during.png`〜`4-released.png`）。そのあとの再ドラッグで 5/10 へ移動できる（`rot2/6-redrag-released.png`）。
  - 読み上げ中: 8/10 までドラッグ → 回転 → 実際の 5/10 に戻り、離しても移動せず、読み上げは続く（`rot3/`）。

確認できなかったこと:

- **一時停止中・全開→半開のドラッグ中断（修正後）**: ヒンジはマウスでしか動かせず、ドラッグ中に 2 つ目のマウス操作をするとシミュレータには指を離したと伝わる（その時点の 9/10 へ通常どおり移動した。`hinge/6-during.png`、`8-later.png`）。指を置いたまま開閉する操作は、この環境では再現できない。コードの経路は、前工程で確認した「読み上げ中・全開→半開」「一時停止中・半開→全開」と同じ（`hingeDidMove`。再生状態による分岐はない）。
- **VoiceOver による増減**: DeviceHub の「Device → Accessibility → VoiceOver」で有効にできたが、マウスのタップが VoiceOver の操作として届かず（最初の案内の「OK」も選べなかった）、スライダーを選べなかった。確認後に VoiceOver を切り、案内を閉じた。コード上、増減は `accessibilityAdjustableAction` → `model.step` で、仮位置・ヒンジ・中断のフラグを通らない。
- 実機での動作（タッチの扱い、角度の揺れ）。
- macOS 版はビルドと起動（文書なしの画面）だけを確認した。文書を開くと利用者の実データ（オートセーブ）に書き込むため、開いていない。macOS ではウィンドウの最小幅で操作列が 1 行に収まるので、`ViewThatFits` は常に最初の並べ方を選ぶはず。

既存の Dynamic Type の問題で、今回直していないもの（折り目はまたがない）:

- AX サイズで、読み上げ画面の見出しがナビゲーションバーの題名に重なる（分割しないレイアウト）。
- AX サイズで、大写しの文の右上のメモボタンが文に少し重なる。
- AX5 で分割しないレイアウトのとき、高さが足りず、操作列の下の状態表示（ボタンではない）が画面の下端で切れることがある（`half-land-sidebar-ax5.png`）。

この工程で変更したファイル:

- `SimpleTTS/ReaderView.swift`: 操作列と見出しの組み替え（`ViewThatFits`。ボタンを `previousButton` などの部品に分けた）。ドラッグ中の大きさの変化でドラッグを中断する（`ignoresInterruptedDrag`）。
- `docs/ios-support-progress.md`: この記録と変更内容の表。

再検証:

- iPhone Duo シミュレータ向けと macOS 向けの Debug・署名なしビルド成功（`build/review/duo3/duo-build.log`、`mac-build.log`）。どちらも AppIntents のメタデータ抽出をスキップした警告が 1 件（従来どおり）。
- `test-fold-split.sh`、`test-storage-import.sh`、`test-reader-privacy.sh` の 3 本と `git diff --check` が成功。
- シミュレータの中で変えたもの: 文字サイズ（`large` に戻した）、VoiceOver（切った）、向きと開き具合、読み上げ位置（オートセーブ）。試験用の文書とメモは前工程のまま。コミット・外部公開はしていない。

### レビュー対応確認（2026-11-16、繰り返し 3/3）

判定: **CONTINUE**。文字拡大時の操作列の指摘は解消を確認した。新たなコード上の不具合は指摘しない。ただし、前回の必須確認2に含まれる実動作確認が2点残っており、レビュー項目をすべて解消したとは判定しない。

- 修正確認: `ControlBar` の `ViewThatFits` が1行・2行・3行を選び、最後の配置にも全ボタンが残る。見出しにも2行への切り替えがある。前工程の画像 `build/review/duo3/half-land-ax5-note.png` と `half-port-ax5-note.png` を実際に閲覧し、最大文字サイズ・長文・メモ表示で操作列がそれぞれの区画に収まることを確認した。今回新しく撮影した画像ではない。
- 回転時の修正確認: ドラッグ中の `geometry.size` 変更で仮位置を破棄し、値設定と編集開始を `ignoresInterruptedDrag` で抑止する。編集終了では移動せずフラグを戻し、スライダーの消失でも状態を戻す。実動作の結果は前工程の記録を参照し、今回のコード確認とは区別する。
- **未解決の検証項目**: 修正後の「一時停止中・全開→半開のドラッグ中断」と「中断後のVoiceOver増減」。前工程では入力手段の制約により未確認で、今回も実操作での再検証は行っていない。再生状態で分岐しないことや `accessibilityAdjustableAction` から `model.step` を呼ぶことはコードで確認できるが、イベントの到着順やアクセシビリティ操作の復帰を実証するものではない。次担当者は、同時のタッチ保持とヒンジ操作が可能な環境、およびVoiceOver操作が届く環境で、実際の位置への復帰・意図しないシークがないこと・再操作を確認して結果を追記する。
- 実機のタッチと角度の揺れ、既存のDynamic Typeの重なり、macOSの文書を開いた動作は、前工程記載の制限として残る。

今回の再検証:

- `test-fold-split.sh`、`test-storage-import.sh`、`test-reader-privacy.sh` の3本成功。
- iPhone Duo Simulator / macOS のDebug・署名なしビルド成功。各1件、従来と同じAppIntentsメタデータ抽出スキップの警告あり。ログ: `build/review/verification3-duo-build.log`、`build/review/verification3-mac-build.log`。
- `git diff --check` 成功。

今回の変更ファイルは `docs/ios-support-progress.md` のみ。アプリの起動・操作、シミュレータ内データの変更、コミット・外部公開は行っていない。権限不足ではなく、必須確認の実動作の裏付けが不足しているための継続判定。

### コミット工程（2026-11-16）

この工程の作業: 前工程の結果・作業ツリーの差分・既存のビルドログを確認し、変更対象と残る受け入れ条件を記録する。工程名は「コミット」だが、今回の作業条件でコミットは禁止されているため、ステージング・コミット・外部公開は行わない。

- 前工程の判定は **CONTINUE** のまま。レビュー対応確認は上限3回に達したが、それをもって受け入れ完了にはしない。
- Duo対応の差分は `SimpleTTS/ContentView.swift`、`SimpleTTS/ReaderView.swift`、新規の `SimpleTTS/FoldSplit.swift`、`Tests/FoldSplitTests.swift`、`scripts/test-fold-split.sh`、テスト手順を追加した `README.md`・`README.ja.md`、この記録。新規3ファイルは未追跡のため、将来コミットする際には含める必要がある。
- `install.sh` には工程開始前から別件の変更がある。今回編集・実行しておらず、Duo対応の変更対象には含めない。
- 今回は回転・ヒンジによる仮位置の破棄とVoiceOver増減のコード経路を確認した。実操作による検証の代わりにはしない。ソースの追加変更は行っていない。
- 既存ログ `build/review/verification3-duo-build.log` と `build/review/verification3-mac-build.log` で両ビルドの成功と、それぞれAppIntents警告1件を確認した。テスト3本の成功は前工程の記録を引き継ぐ。今回ビルド・テスト・アプリ操作は再実行していない。今回実行した `git diff --check` は成功。

次担当者の必須確認（未完了）:

1. 一時停止中、全開の位置スライダーをドラッグしたまま半開にし、表示が実際の位置に戻り、指を離しても意図しないシークが起きず、再ドラッグできることを確認する。同時にタッチ保持とヒンジ操作ができる環境が必要。
2. 中断後、VoiceOverで位置スライダーを選択し、増減で1文ずつ移動し、表示と実際の位置が一致することを確認する。VoiceOverの操作が届く環境が必要。

今回の変更ファイルはこの記録のみ。権限不足はない。上記2点の実動作の裏付けが得られるまで、Duo対応の受け入れは未完了。実機のタッチ・角度の揺れ、既存のDynamic Typeの重なり、macOSの文書を開いた動作も前工程記載の制限として残る。

## 検証状況（初期のiOS対応時点。Duo対応の最新結果は上記）

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
