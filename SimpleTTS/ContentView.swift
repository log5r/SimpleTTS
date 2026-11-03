import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// ウィンドウと各カラムの寸法。
/// ウィンドウの最小サイズは「サイドバーの最小幅＋読み上げ画面の最小幅」から決め、
/// それ以上狭くならないようにする（読み上げ画面は幅に応じてボタンのラベルを省略する）。
nonisolated enum LayoutMetrics {
    static let sidebarMinWidth: CGFloat = 220
    static let sidebarIdealWidth: CGFloat = 270
    static let sidebarMaxWidth: CGFloat = 380

    /// 読み上げ画面（詳細カラム）の最小サイズ
    static let readerMinWidth: CGFloat = 480
    static let readerMinHeight: CGFloat = 480
    static let readerIdealWidth: CGFloat = 730

    static var windowMinWidth: CGFloat { sidebarMinWidth + readerMinWidth }
    static var windowMinHeight: CGFloat { readerMinHeight }

    /// 初回起動時のウィンドウサイズ
    static let windowDefaultWidth: CGFloat = 1000
    static let windowDefaultHeight: CGFloat = 680

    /// 詳細カラムがこの幅未満のときは、ツールバーの「声」と「速度」を 1 つのボタン（ポップオーバー）にまとめる。
    /// 両方を並べるとおよそ 450pt（声 220pt＋速度 約 210pt＋余白）必要で、
    /// これより狭いと macOS がツールバーの「»」メニューに押し出し、スライダーを操作できなくなる。
    static let toolbarCompactBelowDetailWidth: CGFloat = 680

    /// サイドバーを畳んでいるときにまとめ表示へ切り替える詳細カラムの幅。
    /// 畳むとウィンドウのボタン（閉じる・しまう・拡大）とサイドバー切り替えボタンが詳細カラム側のツールバーに移るため、
    /// その分（約 120pt）と余裕を足している。確認用の描画では、畳んだ状態は幅 740pt で「»」にあふれ、760pt で収まった
    /// （このときサイドバー切り替えボタンは表示されていなかった）。
    static let toolbarCompactBelowDetailWidthWithoutSidebar: CGFloat = 840
}

/// ツールバーの「声」「速度」をまとめ表示にするかの判定に使う、詳細カラム幅の区分。
/// 境界をまたいだときだけ更新されるよう、幅そのものではなくこの区分を監視する。
private nonisolated struct ToolbarWidthClass: Equatable {
    /// サイドバー表示中なら、まとめ表示にする幅か
    var isCompactWithSidebar: Bool
    /// サイドバーを畳んでいるなら、まとめ表示にする幅か
    var isCompactWithoutSidebar: Bool

    init(detailWidth: CGFloat) {
        isCompactWithSidebar = detailWidth < LayoutMetrics.toolbarCompactBelowDetailWidth
        isCompactWithoutSidebar = detailWidth < LayoutMetrics.toolbarCompactBelowDetailWidthWithoutSidebar
    }

    func isCompact(sidebarVisible: Bool) -> Bool {
        sidebarVisible ? isCompactWithSidebar : isCompactWithoutSidebar
    }
}

struct ContentView: View {
    @Bindable var model: ReaderModel
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    #if os(iOS)
    @State private var isPrivacyPresented = false
    #endif

    var body: some View {
        splitView
            .disabled(model.isBusy)
            .overlay {
                if model.isLoading {
                    ProgressView("Loading…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .fileImporter(
                isPresented: $model.isImporterPresented,
                allowedContentTypes: [.plainText]
            ) { result in
                switch result {
                case .success(let url):
                    Task { await model.openFile(at: url) }
                case .failure(let error):
                    model.errorMessage = String(localized: "Could not open the file: \(error.localizedDescription)")
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard !model.isBusy, let url = urls.first, url.isFileURL else { return false }
                Task { await model.openFile(at: url) }
                return true
            }
            .alert(
                "Error",
                isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
            #if os(macOS)
            .onDisappear {
                model.prepareForTermination()
            }
            #else
            .sheet(isPresented: $isPrivacyPresented) {
                NavigationStack {
                    PrivacySettingsView(model: model)
                        .navigationTitle("Privacy")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { isPrivacyPresented = false }
                                    .disabled(model.isClearingData)
                            }
                        }
                }
                .interactiveDismissDisabled(model.isClearingData)
            }
            .onChange(of: scenePhase) { _, phase in
                // バックグラウンドでは読み上げを続けるが、終了させられても再開できるよう位置を保存しておく
                if phase == .background {
                    model.saveProgress()
                }
            }
            #endif
    }

    private var openButton: some View {
        Button {
            model.isImporterPresented = true
        } label: {
            Label("Open…", systemImage: "folder")
        }
        .help("Open a text file (⌘O)")
    }

    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    /// iPhone など幅の狭い環境で表示するカラム。最初は読み上げ画面を出し、セーブ一覧は戻るボタンで開く。
    @State private var preferredCompactColumn = NavigationSplitViewColumn.detail

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredCompactColumn) {
            SavesSidebar(model: model) {
                // セーブを読み込んだら読み上げ画面に戻る
                preferredCompactColumn = .detail
            }
            .navigationTitle("Saved Positions")
        } detail: {
            ReaderView(model: model)
                .navigationTitle(model.document?.title ?? "SimpleTTS")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        openButton
                        SpeechToolbarControls(model: model, isCompact: true)
                        Button {
                            isPrivacyPresented = true
                        } label: {
                            Label("Privacy", systemImage: "hand.raised")
                        }
                    }
                }
        }
    }
    #else
    @State private var toolbarWidthClass = ToolbarWidthClass(detailWidth: LayoutMetrics.windowDefaultWidth)
    /// 詳細カラムが狭く、ツールバーの「声」「速度」を 1 つのボタンにまとめて表示しているか
    @State private var isToolbarCompact = false
    @State private var toolbarCompactDebouncer = Debouncer()

    private var isSidebarVisible: Bool {
        columnVisibility != .detailOnly
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SavesSidebar(model: model)
                .navigationSplitViewColumnWidth(
                    min: LayoutMetrics.sidebarMinWidth,
                    ideal: LayoutMetrics.sidebarIdealWidth,
                    max: LayoutMetrics.sidebarMaxWidth
                )
        } detail: {
            ReaderView(model: model)
                // 詳細カラムの最小幅は NavigationSplitView に伝えないとサイドバー側が優先され、
                // 読み上げ画面が最小幅より狭く押し込まれて右端が切れてしまう
                .navigationSplitViewColumnWidth(min: LayoutMetrics.readerMinWidth, ideal: LayoutMetrics.readerIdealWidth)
                .frame(minHeight: LayoutMetrics.readerMinHeight)
                .onGeometryChange(for: ToolbarWidthClass.self) { proxy in
                    ToolbarWidthClass(detailWidth: proxy.size.width)
                } action: { widthClass in
                    toolbarWidthClass = widthClass
                    scheduleToolbarCompactUpdate()
                }
        }
        .onChange(of: isSidebarVisible) {
            scheduleToolbarCompactUpdate()
        }
        .navigationTitle(model.document?.title ?? "SimpleTTS")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                openButton
            }

            ToolbarItem(placement: .primaryAction) {
                SpeechToolbarControls(model: model, isCompact: isToolbarCompact)
            }
            ToolbarItem(placement: .secondaryAction) {
                SettingsLink {
                    Label("Privacy Settings", systemImage: "hand.raised")
                }
            }
        }
    }

    /// 詳細カラムの幅とサイドバーの表示状態から、ツールバーのまとめ表示を決め直す。
    /// 起動直後のレイアウト途中では 0pt・100pt・430pt などの仮の幅が続けて届く。
    /// そのたびにツールバーの中身を入れ替えるとウィンドウタイトルの反映が抜けることがあるため、
    /// 判定が少しのあいだ変わらなくなってから反映する。
    private func scheduleToolbarCompactUpdate() {
        toolbarCompactDebouncer.schedule {
            let isCompact = toolbarWidthClass.isCompact(sidebarVisible: isSidebarVisible)
            if isToolbarCompact != isCompact {
                isToolbarCompact = isCompact
            }
        }
    }
    #endif
}

#if os(macOS)
/// 最後の呼び出しから一定時間たってから処理を 1 回だけ実行する
private final class Debouncer {
    private var pending: DispatchWorkItem?

    func schedule(after delay: DispatchTimeInterval = .milliseconds(150), _ action: @escaping @MainActor () -> Void) {
        pending?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { action() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
#endif

/// ツールバーの「声」と「速度」。
/// 詳細カラムが狭いときは 1 つのボタンにまとめ、押すとポップオーバーで同じ操作を出す。
/// 並べたままだと macOS がツールバーの「»」メニューに押し出し、スライダーを操作できなくなる。
/// iOS ではツールバーに並べる幅がないので、常にまとめて表示する。
private struct SpeechToolbarControls: View {
    @Bindable var model: ReaderModel
    let isCompact: Bool
    @State private var isPopoverPresented = false

    var body: some View {
        Group {
            if isCompact {
                Button {
                    isPopoverPresented.toggle()
                } label: {
                    Label("Speech Settings", systemImage: "slider.horizontal.3")
                }
                .help("Voice and speed (currently \(model.selectedVoiceName ?? String(localized: "System Default")), \(rateText))")
                .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Voice")
                            .font(.headline)
                        voicePicker
                            .labelsHidden()
                        Text("Speed")
                            .font(.headline)
                        rateControl
                    }
                    .padding(16)
                    #if os(iOS)
                    // 項目が少ないので、iPhone でもシートにせずポップオーバーのまま出す
                    .presentationCompactAdaptation(.popover)
                    #endif
                }
            } else {
                HStack(spacing: 12) {
                    voicePicker
                    rateControl
                }
            }
        }
        .onChange(of: isCompact) { _, isCompact in
            if !isCompact {
                isPopoverPresented = false
            }
        }
    }

    private var voicePicker: some View {
        Picker("Voice", selection: $model.selectedVoice) {
            Text("System Default").tag(String?.none)
            Divider()
            ForEach(model.voices) { voice in
                Text("\(voice.name) (\(voice.locale))").tag(Optional(voice.id))
            }
        }
        .frame(width: 220)
        .help("Voice used for speech")
    }

    private var rateControl: some View {
        HStack(spacing: 4) {
            Image(systemName: "tortoise")
            Slider(value: $model.rate, in: ReaderModel.rateRange, step: ReaderModel.rateStep)
                .frame(width: 120)
                .accessibilityLabel("Speech speed")
                .accessibilityValue(rateText)
            Image(systemName: "hare")
            Text(rateText)
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
        }
        .help("Speech speed relative to the voice's normal rate (\(rateText(ReaderModel.rateRange.lowerBound))–\(rateText(ReaderModel.rateRange.upperBound)))")
    }

    private var rateText: String {
        rateText(model.rate)
    }

    private func rateText(_ rate: Double) -> String {
        rate.formatted(.number.precision(.fractionLength(1))) + "×"
    }
}

#Preview("Reader") {
    // Keep preview content and preferences separate from the user's library.
    let model: ReaderModel = {
        let root = FileManager.default.temporaryDirectory.appending(path: "SimpleTTS-ReaderPreview")
        let storage = Storage(baseURL: root.appending(path: "Storage"))
        let text = "Welcome to SimpleTTS. Open a text file to read it aloud. You can move between sentences and adjust the playback speed."
        let document = ReaderDocument(title: "Welcome.txt", text: text)
        try? storage.storeDocumentText(text, id: document.id)
        try? storage.writeSaves([
            SavePoint(id: UUID(), kind: .auto, documentID: document.id, documentTitle: document.title,
                      sentenceIndex: 0, sentenceCount: document.sentences.count,
                      excerpt: document.sentences[0], createdAt: Date())
        ])
        let defaults = UserDefaults(suiteName: "SimpleTTS.ReaderPreview")!
        defaults.set(true, forKey: "retainsDocuments")
        return ReaderModel(storage: storage,
                           speaker: SpeechPlayer(temporaryDirectory: root.appending(path: "Audio")),
                           defaults: defaults, loadsVoices: false)
    }()
    ContentView(model: model)
        #if os(macOS)
        .frame(width: 1000, height: 600)
        #endif
}
