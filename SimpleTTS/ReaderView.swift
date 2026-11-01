import SwiftUI

/// 読み上げ画面の幅に応じたレイアウトの段階。
/// 幅が足りないときは、補助的なボタンのラベルを省略してアイコン（＋ツールチップ）だけにする。
enum ReaderWidthClass: Equatable {
    /// すべてのボタンにラベルを表示する
    case regular
    /// 「セーブ」「コピー」と状態表示をアイコンだけにする
    case compact
    /// 「再生／一時停止」以外のボタンをアイコンだけにする
    case minimal

    /// 幅の下限は `LayoutMetrics.readerMinWidth` でウィンドウ側から制限している。
    /// 操作列の実寸（左右の余白込み）はおよそ regular: 650pt、compact: 440pt、minimal: 320pt。
    init(width: CGFloat) {
        switch width {
        case 680...: self = .regular
        case 520...: self = .compact
        default: self = .minimal
        }
    }
}

/// 読み上げ中の文を大写しにし、その前後の文を上下に表示する。
struct ReaderView: View {
    let model: ReaderModel

    var body: some View {
        if let document = model.document {
            // 文の長さに関係なく、詳細カラムに割り当てられたサイズでレイアウトする。
            GeometryReader { geometry in
                let widthClass = ReaderWidthClass(width: geometry.size.width)
                VStack(spacing: 0) {
                    header(for: document, widthClass: widthClass)
                    Divider()
                    VStack(spacing: widthClass == .regular ? 20 : 14) {
                        ContextColumn(
                            sentences: model.previousContext,
                            currentIndex: model.currentIndex,
                            alignment: .bottom,
                            onSelect: { model.jump(to: $0) }
                        )
                        currentSentence(widthClass: widthClass)
                            .layoutPriority(1)
                        ContextColumn(
                            sentences: model.nextContext,
                            currentIndex: model.currentIndex,
                            alignment: .top,
                            onSelect: { model.jump(to: $0) }
                        )
                    }
                    .padding(.horizontal, widthClass == .regular ? 32 : 16)
                    .padding(.vertical, widthClass == .regular ? 20 : 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    ControlBar(model: model, widthClass: widthClass)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        } else {
            ContentUnavailableView {
                Label("テキストファイルを開いてください", systemImage: "doc.text")
            } description: {
                Text("⌘O、またはウィンドウへのドラッグ＆ドロップで .txt ファイルを開けます。")
            } actions: {
                Button("ファイルを開く…") {
                    model.isImporterPresented = true
                }
            }
        }
    }

    private func header(for document: ReaderDocument, widthClass: ReaderWidthClass) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                Text(document.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
                Spacer(minLength: 8)
                Group {
                    if model.isPlaying {
                        Label("読み上げ中", systemImage: "speaker.wave.2.fill")
                            .foregroundStyle(.tint)
                    } else {
                        Label("一時停止中", systemImage: "pause.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                .labelStyle(AdaptiveLabelStyle(iconOnly: widthClass != .regular))
                .help(model.isPlaying ? "読み上げ中" : "一時停止中")
                .fixedSize()
                Text("\(model.currentIndex + 1) / \(model.sentenceCount)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            ProgressView(value: Double(model.currentIndex + 1), total: Double(max(model.sentenceCount, 1)))
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private func currentSentence(widthClass: ReaderWidthClass) -> some View {
        Group {
            if model.isPlaying {
                currentSentenceText(widthClass: widthClass)
            } else {
                // 一時停止中は大写しの文を選択してコピーできる
                currentSentenceText(widthClass: widthClass)
                    .textSelection(.enabled)
            }
        }
        .padding(widthClass == .regular ? 24 : 16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.accentColor.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.accentColor.opacity(model.isPlaying ? 0.7 : 0.25), lineWidth: 2)
        )
    }

    private func currentSentenceText(widthClass: ReaderWidthClass) -> some View {
        Text(model.currentSentence ?? "")
            .font(.system(size: widthClass == .regular ? 34 : 28, weight: .semibold))
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.4)
            .frame(maxWidth: .infinity, minHeight: 80)
    }
}

/// 幅に応じて「アイコン＋タイトル」と「アイコンのみ」を切り替えるラベルスタイル。
/// アイコンのみのときもタイトルはアクセシビリティラベルとして残る。
private struct AdaptiveLabelStyle: LabelStyle {
    let iconOnly: Bool

    func makeBody(configuration: Configuration) -> some View {
        if iconOnly {
            Label(configuration)
                .labelStyle(.iconOnly)
        } else {
            Label(configuration)
                .labelStyle(.titleAndIcon)
        }
    }
}

/// 前後の文脈表示。現在の文に近いほど濃く表示する。クリックでその文へ移動。
private struct ContextColumn: View {
    let sentences: [ContextSentence]
    let currentIndex: Int
    let alignment: Alignment
    let onSelect: @MainActor (Int) -> Void

    var body: some View {
        VStack(spacing: 10) {
            ForEach(sentences) { sentence in
                Text(sentence.text)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .opacity(opacity(for: sentence.id))
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(sentence.id) }
                    .help("クリックでこの文へ移動")
            }
        }
        // 高さが足りないときは文脈を縮め、見出しと操作列の領域を確保する。
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: alignment)
        .clipped()
    }

    private func opacity(for index: Int) -> Double {
        let distance = abs(index - currentIndex)
        return max(0.35, 1.0 - Double(distance - 1) * 0.25)
    }
}

/// 再生／一時停止・前後移動・セーブ・コピーの操作列
private struct ControlBar: View {
    let model: ReaderModel
    let widthClass: ReaderWidthClass

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: widthClass == .regular ? 12 : 8) {
                Group {
                    Button {
                        model.step(by: -1)
                    } label: {
                        Label("前の文", systemImage: "backward.end.fill")
                    }
                    .disabled(!model.canStepBackward)
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                    .help("前の文へ移動（⌘←）")

                    Button {
                        model.togglePlayback()
                    } label: {
                        Label(
                            model.isPlaying ? "一時停止" : "再生",
                            systemImage: model.isPlaying ? "pause.fill" : "play.fill"
                        )
                        .labelStyle(.titleAndIcon)
                        .frame(minWidth: 90)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.space, modifiers: [])
                    .help(model.isPlaying ? "一時停止（スペース）" : "再生（スペース）")

                    Button {
                        model.step(by: 1)
                    } label: {
                        Label("次の文", systemImage: "forward.end.fill")
                    }
                    .disabled(!model.canStepForward)
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                    .help("次の文へ移動（⌘→）")
                }
                .labelStyle(AdaptiveLabelStyle(iconOnly: widthClass == .minimal))

                Divider()
                    .frame(height: 22)

                Group {
                    Button {
                        model.saveManually()
                    } label: {
                        Label("この位置をセーブ", systemImage: "bookmark")
                    }
                    .disabled(!model.canSaveManually)
                    .keyboardShortcut("s", modifiers: [.command])
                    .help("一時停止中に、現在の位置をセーブします（⌘S、最大\(ReaderModel.manualSaveLimit)件）")

                    Button {
                        model.copyCurrentSentence()
                    } label: {
                        Label("文章をコピー", systemImage: "doc.on.doc")
                    }
                    .disabled(!model.canCopy)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .help("一時停止中に、大写しの文章をコピーします（⇧⌘C）")
                }
                .labelStyle(AdaptiveLabelStyle(iconOnly: widthClass != .regular))
            }
            .fixedSize()

            Text(model.statusMessage ?? " ")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.vertical, 12)
    }
}
