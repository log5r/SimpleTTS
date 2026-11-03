import SwiftUI

/// macOS の設定ウィンドウと iOS の設定シートで共通のプライバシー設定。
struct PrivacySettingsView: View {
    @Bindable var model: ReaderModel
    @State private var confirmsDeletion = false

    var body: some View {
        Form {
            Section {
                Toggle("文書と履歴を保存", isOn: $model.retainsDocuments)
            } header: {
                Text("保存")
            } footer: {
                Text("オンのときは、開いた文書の全文と、文書名・本文の抜粋・読み上げ位置・日時を保存します。オフにしても、以前の保存データは残ります。保存せずに開いた文書を保存するには、オンにして開き直してください。")
            }

            #if os(iOS)
            Section {
                Toggle("ロック画面に文書名を表示", isOn: $model.showsDocumentNameOnLockScreen)
            } header: {
                Text("再生情報")
            } footer: {
                Text("オフのときは「SimpleTTS」と表示します。オンにすると、コントロールセンターや接続先の機器にも文書名が表示されることがあります。")
            }
            #endif

            Section {
                Text("保存する設定にかかわらず、読み上げ中は一時的な音声ファイルを作ります。通常終了時と次回起動時に削除します。")
                Text("本文と履歴は端末内に保存し、アプリからサーバーへ送信しません。保存先は OS のバックアップ対象から除外します。")
            } header: {
                Text("データの取り扱い")
            }

            Section {
                Button("保存データをすべて削除…", role: .destructive) {
                    confirmsDeletion = true
                }
                if model.isClearingData {
                    ProgressView("削除中…")
                }
                if let message = model.dataDeletionMessage {
                    Text(message).foregroundStyle(.secondary)
                }
                if let error = model.dataDeletionError {
                    Text(error).foregroundStyle(.red)
                }
            } header: {
                Text("削除")
            } footer: {
                Text("本文・履歴・復旧用の退避データ・生成音声を削除し、開いている文書を閉じます。元ファイル、コピー済みのクリップボード、既存のバックアップは削除しません。")
            }
        }
        .formStyle(.grouped)
        .disabled(model.isBusy)
        .confirmationDialog("保存データをすべて削除しますか？", isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("すべて削除", role: .destructive) {
                Task { await model.deleteAllStoredData() }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("読み上げを停止し、アプリに保存した文書と履歴、生成音声を削除します。この操作は取り消せません。元ファイルとアプリの設定は残ります。")
        }
    }
}

#Preview("プライバシー") {
    let root = FileManager.default.temporaryDirectory.appending(path: "SimpleTTS-PrivacyPreview")
    let model = ReaderModel(
        storage: Storage(baseURL: root.appending(path: "Storage")),
        speaker: SpeechPlayer(temporaryDirectory: root.appending(path: "Audio")),
        defaults: UserDefaults(suiteName: "SimpleTTS.PrivacyPreview")!,
        loadsVoices: false
    )
    PrivacySettingsView(model: model)
        #if os(macOS)
        .frame(width: 500, height: 600)
        #endif
}
