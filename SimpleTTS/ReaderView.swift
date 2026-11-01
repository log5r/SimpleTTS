import SwiftUI

/// 読み上げ中の文を大写しにし、その前後の文を上下に表示する。
struct ReaderView: View {
    let model: ReaderModel

    var body: some View {
        if let document = model.document {
            VStack(spacing: 0) {
                header(for: document)
                Divider()
                VStack(spacing: 20) {
                    ContextColumn(
                        sentences: model.previousContext,
                        currentIndex: model.currentIndex,
                        alignment: .bottom,
                        onSelect: { model.jump(to: $0) }
                    )
                    currentSentence
                        .layoutPriority(1)
                    ContextColumn(
                        sentences: model.nextContext,
                        currentIndex: model.currentIndex,
                        alignment: .top,
                        onSelect: { model.jump(to: $0) }
                    )
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                ControlBar(model: model)
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

    private func header(for document: ReaderDocument) -> some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "doc.text")
                Text(document.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if model.isPlaying {
                    Label("読み上げ中", systemImage: "speaker.wave.2.fill")
                        .foregroundStyle(.tint)
                } else {
                    Label("一時停止中", systemImage: "pause.circle")
                        .foregroundStyle(.secondary)
                }
                Text("\(model.currentIndex + 1) / \(model.sentenceCount)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(model.currentIndex + 1), total: Double(max(model.sentenceCount, 1)))
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var currentSentence: some View {
        Group {
            if model.isPlaying {
                currentSentenceText
            } else {
                // 一時停止中は大写しの文を選択してコピーできる
                currentSentenceText
                    .textSelection(.enabled)
            }
        }
        .padding(24)
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

    private var currentSentenceText: some View {
        Text(model.currentSentence ?? "")
            .font(.system(size: 34, weight: .semibold))
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.4)
            .frame(maxWidth: .infinity, minHeight: 80, maxHeight: 360)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
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

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    model.step(by: -1)
                } label: {
                    Label("前の文", systemImage: "backward.end.fill")
                }
                .disabled(!model.canStepBackward)
                .keyboardShortcut(.leftArrow, modifiers: [.command])

                Button {
                    model.togglePlayback()
                } label: {
                    Label(
                        model.isPlaying ? "一時停止" : "再生",
                        systemImage: model.isPlaying ? "pause.fill" : "play.fill"
                    )
                    .frame(minWidth: 90)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.space, modifiers: [])

                Button {
                    model.step(by: 1)
                } label: {
                    Label("次の文", systemImage: "forward.end.fill")
                }
                .disabled(!model.canStepForward)
                .keyboardShortcut(.rightArrow, modifiers: [.command])

                Divider()
                    .frame(height: 22)

                Button {
                    model.saveManually()
                } label: {
                    Label("この位置をセーブ", systemImage: "bookmark")
                }
                .disabled(!model.canSaveManually)
                .keyboardShortcut("s", modifiers: [.command])
                .help("一時停止中に、現在の位置をセーブします（最大\(ReaderModel.manualSaveLimit)件）")

                Button {
                    model.copyCurrentSentence()
                } label: {
                    Label("文章をコピー", systemImage: "doc.on.doc")
                }
                .disabled(!model.canCopy)
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .help("一時停止中に、大写しの文章をコピーします")
            }

            Text(model.statusMessage ?? " ")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }
}
