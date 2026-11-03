# SimpleTTS

macOS・iPhone・iPad 向けのテキスト読み上げアプリです。OS 標準の音声を使い、文ごとの再生、前後の文への移動、0.5〜2.0 倍速の再生、読書位置の保存に対応しています。

## 必要な環境

現在のプロジェクト設定は macOS 27.0.1 以降、iOS / iPadOS 27.0 以降を対象としています。開発には Xcode 27.2 を使用しています。外部の Swift パッケージは使用していません。

## macOS で起動する

`SimpleTTS.xcodeproj` を Xcode で開き、`SimpleTTS` スキームと `My Mac` を選んで実行します。ターミナルから起動する場合は、次のスクリプトを使用できます。

```sh
./start.sh
```

ビルド済みのアプリがあればそれを起動します。ソースや署名設定を変更したあとは、再ビルドしてください。

```sh
./start.sh rebuild
```

署名を省略してローカルで試す場合は、`NO_SIGN=1 ./start.sh rebuild` を使用できます。これは開発用の起動方法です。配布用アプリの署名・公証は別途行ってください。

## iOS / iPadOS で起動する

Xcode で `SimpleTTS` スキームと iPhone / iPad のシミュレータを選んで実行します。コマンドラインでビルドだけを行う場合は、次のとおりです。

```sh
xcodebuild -project SimpleTTS.xcodeproj -scheme SimpleTTS \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData-iOS \
  CODE_SIGNING_ALLOWED=NO build
```

実機にインストールするときは、自分の Apple 開発チームと Bundle ID を指定します。公開リポジトリには個人のチーム ID を設定していません。

```sh
cp Config/Signing.example.xcconfig Config/Signing.local.xcconfig
```

コピーしたファイルの `YOUR_TEAM_ID` と `com.example.SimpleTTS` を自分の値に変更してください。`Signing.local.xcconfig` は Git の管理対象外で、`start.sh` が自動で読み込みます。`xcodebuild` を直接使う場合は `-xcconfig Config/Signing.local.xcconfig` を指定します。Xcode の画面から実行する場合は、ローカルで開発チームを選び、個人の設定変更をコミットしないでください。

## ファイルを読む

「開く」からテキストファイルを選ぶか、アプリにドロップします。読み込み対象は 10 MiB 以下の通常ファイルです。HTTP / HTTPS の URL は読み込みません。UTF-8、UTF-16、Shift JIS、EUC-JP などの文字コードに対応しています。

再生中は前後の文へ移動でき、一時停止中は読書位置の保存と、表示中の文のコピーができます。iOS ではバックグラウンドでも読み上げを継続します。

## プライバシー設定

macOS では「設定」、iOS ではツールバーの「プライバシー」から、本文・履歴の保存とロック画面への文書名表示を変更できます。

- 「文書と履歴を保存」は初期状態でオンです。開いた本文をアプリ内にコピーし、読書位置、文書名、本文の抜粋、保存日時を保持します。オフにすると本文・履歴の新たな保存を停止します。以前の保存データは残ります。
- 「ロック画面に文書名を表示」は初期状態でオフです。iOS の再生情報にはアプリ名を表示します。オンにするとファイル名を表示します。
- 保存済みの本文や履歴を消す場合は、「保存データをすべて削除…」を使います。通常のセーブ削除は、読書位置の記録だけを削除する操作です。

音声合成中は、保存設定がオフでも一時的な音声ファイルを作成します。保存場所、削除範囲、バックアップの扱いは [PRIVACY.md](PRIVACY.md) を参照してください。

## ソースを配布する

Git 管理下の変更をコミットしたあと、次のスクリプトで配布用 ZIP を作成できます。

```sh
./scripts/export-source.sh
```

出力先は `build/SimpleTTS-source.zip` です。`git archive HEAD` を使うため、Git 履歴、未追跡ファイル、ローカルのビルド成果物や調査用音声は含まれません。未コミットの変更がある場合や、出力先が存在する場合は停止します。別の出力先を指定する場合は、第1引数に ZIP のパスを渡してください。

リポジトリを Git で公開すると、コミット履歴も公開対象になります。作業フォルダ全体を圧縮する方法は、ローカルの設定や音声ファイルを含むため使用しないでください。

## テスト

macOS 上で、保存・ファイル読み込み・プライバシー設定の回帰テストを実行できます。

```sh
./scripts/test-storage-import.sh
./scripts/test-reader-privacy.sh
```

テストには一時フォルダ内の合成データと専用の設定領域を使います。通常のアプリデータは変更せず、音声も再生しません。

## ライセンス

[MIT License](LICENSE)。OS の音声や Apple のフレームワーク自体を同梱・再配布するプロジェクトではありません。
