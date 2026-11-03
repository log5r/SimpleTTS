import SwiftUI

/// macOS の設定ウィンドウと iOS の設定シートで共通のプライバシー設定。
struct PrivacySettingsView: View {
    @Bindable var model: ReaderModel
    @State private var confirmsDeletion = false

    var body: some View {
        Form {
            Section {
                Toggle("Save Documents and History", isOn: $model.retainsDocuments)
            } header: {
                Text("Storage")
            } footer: {
                Text("When enabled, the app saves the full text, document name, an excerpt, reading position, and date. Turning this off keeps existing saved data. To save a document opened with saving disabled, enable this setting and reopen it.")
            }

            #if os(iOS)
            Section {
                Toggle("Show Document Name on Lock Screen", isOn: $model.showsDocumentNameOnLockScreen)
            } header: {
                Text("Now Playing")
            } footer: {
                Text("When disabled, the title is shown as “SimpleTTS.” When enabled, the document name may also appear in Control Center and on connected devices.")
            }
            #endif

            Section {
                Text("Playback creates temporary audio files even when saving is disabled. These files are removed on normal exit and at the next launch.")
                Text("Documents and history stay on your device. The app does not upload them to a server, and excludes its storage folder from system backups.")
            } header: {
                Text("Data Use")
            }

            Section {
                Button("Delete All Saved Data…", role: .destructive) {
                    confirmsDeletion = true
                }
                if model.isClearingData {
                    ProgressView("Deleting…")
                }
                if let message = model.dataDeletionMessage {
                    Text(message).foregroundStyle(.secondary)
                }
                if let error = model.dataDeletionError {
                    Text(error).foregroundStyle(.red)
                }
            } header: {
                Text("Delete Data")
            } footer: {
                Text("Closes the current document and deletes stored documents, history, recovery copies, and generated audio. Original files, clipboard contents, and existing backups are not deleted.")
            }
        }
        .formStyle(.grouped)
        .disabled(model.isBusy)
        .confirmationDialog("Delete all saved data?", isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) {
                Task { await model.deleteAllStoredData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Playback will stop, and all documents, history, and generated audio stored by the app will be deleted. This cannot be undone. Original files and app settings will be kept.")
        }
    }
}

#Preview("Privacy") {
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
