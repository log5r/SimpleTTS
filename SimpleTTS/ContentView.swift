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
    @State private var toolbarWidthClass = ToolbarWidthClass(detailWidth: LayoutMetrics.windowDefaultWidth)
    /// 詳細カラムが狭く、ツールバーの「声」「速度」を 1 つのボタンにまとめて表示しているか
    @State private var isToolbarCompact = false
    @State private var toolbarCompactDebouncer = Debouncer()

    private var isSidebarVisible: Bool {
        columnVisibility != .detailOnly
    }

    var body: some View {
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
                Button {
                    model.isImporterPresented = true
                } label: {
                    Label("開く", systemImage: "folder")
                }
                .help("テキストファイルを開く（⌘O）")
            }

            ToolbarItem(placement: .primaryAction) {
                SpeechToolbarControls(model: model, isCompact: isToolbarCompact)
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
}

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

/// ツールバーの「声」と「速度」。
/// 詳細カラムが狭いときは 1 つのボタンにまとめ、押すとポップオーバーで同じ操作を出す。
/// 並べたままだと macOS がツールバーの「»」メニューに押し出し、スライダーを操作できなくなる。
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
                    Label("読み上げ設定", systemImage: "slider.horizontal.3")
                }
                .help("声と読み上げ速度（現在: \(model.selectedVoice ?? "システム既定の声")、\(Int(model.rate)) 語/分）")
                .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("声")
                            .font(.headline)
                        voicePicker
                            .labelsHidden()
                        Text("速度（次の文から反映）")
                            .font(.headline)
                        rateControl
                    }
                    .padding(16)
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
        Picker("声", selection: $model.selectedVoice) {
            Text("システム既定の声").tag(String?.none)
            Divider()
            ForEach(model.voices) { voice in
                Text("\(voice.name)（\(voice.locale)）").tag(Optional(voice.name))
            }
        }
        .frame(width: 220)
        .help("読み上げに使う声（say -v）")
    }

    private var rateControl: some View {
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

#Preview {
    ContentView(model: ReaderModel())
        .frame(width: 900, height: 600)
}
