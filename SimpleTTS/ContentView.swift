import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: ReaderModel

    var body: some View {
        NavigationSplitView {
            SavesSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 380)
        } detail: {
            ReaderView(model: model)
        }
        .navigationTitle(model.document?.title ?? "SimpleTTS")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    model.isImporterPresented = true
                } label: {
                    Label("開く", systemImage: "folder")
                }
                .help("テキストファイルを開く（⌘O）")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Picker("声", selection: $model.selectedVoice) {
                    Text("システム既定の声").tag(String?.none)
                    Divider()
                    ForEach(model.voices) { voice in
                        Text("\(voice.name)（\(voice.locale)）").tag(Optional(voice.name))
                    }
                }
                .frame(width: 220)
                .help("読み上げに使う声（say -v）")

                HStack(spacing: 4) {
                    Image(systemName: "tortoise")
                    Slider(value: $model.rate, in: 90...360, step: 10)
                        .frame(width: 120)
                    Image(systemName: "hare")
                    Text("\(Int(model.rate))")
                        .monospacedDigit()
                        .frame(width: 32, alignment: .trailing)
                }
                .help("読み上げ速度（say -r、語/分）。次の文から反映されます")
            }
        }
        .fileImporter(
            isPresented: $model.isImporterPresented,
            allowedContentTypes: [.plainText]
        ) { result in
            switch result {
            case .success(let url):
                model.openFile(at: url)
            case .failure(let error):
                model.errorMessage = "ファイルを開けませんでした: \(error.localizedDescription)"
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.openFile(at: url)
            return true
        }
        .alert(
            "エラー",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onDisappear {
            model.prepareForTermination()
        }
    }
}

#Preview {
    ContentView(model: ReaderModel())
        .frame(width: 900, height: 600)
}
