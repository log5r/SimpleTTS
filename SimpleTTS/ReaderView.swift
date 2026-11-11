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

    /// 読み上げ画面の高さがこれ未満のときは、上下の余白を詰める（iPhone の横向きなど）。
    /// 詰めないと見出し・大写しの文・操作列が収まらず、はみ出た分がナビゲーションバーやホームインジケータに重なる。
    /// macOS はウィンドウの最小の高さ（`LayoutMetrics.readerMinHeight`）があるので該当しない。
    static let shortHeightThreshold: CGFloat = 420

    /// 読み上げ位置のスライダーをドラッグしている間の移動先（0 始まり）。ドラッグしていなければ nil。
    /// ドラッグ中は見出しの番号だけを追従させ、離したときに移動する（読み上げ中に途中の文を読み直さないため）。
    @State private var scrubbingIndex: Int?

    /// 見出しに表示する文番号（0 始まり）。ドラッグ中は移動先を示す。
    private var displayedIndex: Int { scrubbingIndex ?? model.currentIndex }

    var body: some View {
        if let document = model.document {
            // 文の長さに関係なく、詳細カラムに割り当てられたサイズでレイアウトする。
            GeometryReader { geometry in
                let widthClass = ReaderWidthClass(width: geometry.size.width)
                let isShort = geometry.size.height < Self.shortHeightThreshold
                VStack(spacing: 0) {
                    header(for: document, widthClass: widthClass, isShort: isShort)
                    Divider()
                    VStack(spacing: isShort ? 6 : (widthClass == .regular ? 20 : 14)) {
                        ContextColumn(
                            sentences: model.previousContext,
                            currentIndex: model.currentIndex,
                            notedIndices: notedIndices,
                            alignment: .bottom,
                            onSelect: { model.jump(to: $0) }
                        )
                        VStack(spacing: isShort ? 4 : 8) {
                            currentSentence(widthClass: widthClass, isShort: isShort)
                            if let note = model.currentNote {
                                notePreview(note, isShort: isShort)
                            }
                        }
                        .layoutPriority(1)
                        ContextColumn(
                            sentences: model.nextContext,
                            currentIndex: model.currentIndex,
                            notedIndices: notedIndices,
                            alignment: .top,
                            onSelect: { model.jump(to: $0) }
                        )
                    }
                    .padding(.horizontal, widthClass == .regular ? 32 : 16)
                    .padding(.vertical, isShort ? 8 : (widthClass == .regular ? 20 : 14))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    ControlBar(model: model, widthClass: widthClass, isShort: isShort)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        } else {
            ContentUnavailableView {
                Label("Open a Text File", systemImage: "doc.text")
            } description: {
                #if os(macOS)
                Text("Press ⌘O or drop a .txt file into this window.")
                #else
                Text("Choose Open File to select a .txt file.")
                #endif
            } actions: {
                Button("Open File…") {
                    model.isImporterPresented = true
                }
            }
        }
    }

    private func header(for document: ReaderDocument, widthClass: ReaderWidthClass, isShort: Bool) -> some View {
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
                        Label("Reading", systemImage: "speaker.wave.2.fill")
                            .foregroundStyle(.tint)
                    } else {
                        Label("Paused", systemImage: "pause.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                .labelStyle(AdaptiveLabelStyle(iconOnly: widthClass != .regular))
                .help(model.isPlaying ? LocalizedStringKey("Reading") : LocalizedStringKey("Paused"))
                .fixedSize()
                Text("\(displayedIndex + 1) / \(model.sentenceCount)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Button {
                    model.isNotesListPresented = true
                } label: {
                    Label("Notes", systemImage: "list.bullet.rectangle")
                }
                .labelStyle(AdaptiveLabelStyle(iconOnly: widthClass == .minimal))
                .disabled(!model.canShowNotes)
                .help("Show notes for this document (\(model.noteListEntries.count)) (⇧⌘L)")
                .fixedSize()
            }
            positionSlider
            if !model.savesCurrentDocument {
                Label("This document and its history will not be saved", systemImage: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, isShort ? 6 : 10)
    }

    /// 読み上げ位置を示し、ドラッグやクリックで別の文へ移動できるスライダー。
    /// キーボード（←／→）や VoiceOver の増減では、その場で 1 文ずつ移動する。
    private var positionSlider: some View {
        let lastIndex = max(model.sentenceCount - 1, 0)
        let value = Binding<Double>(
            get: { Double(displayedIndex) },
            set: { newValue in
                let index = min(max(Int(newValue.rounded()), 0), lastIndex)
                if scrubbingIndex != nil {
                    scrubbingIndex = index
                } else if index != model.currentIndex {
                    model.jump(to: index)
                }
            }
        )
        // 文が 1 つしかないときは範囲が 0...0 にならないようにする（その場合は操作できない）。
        // step を指定すると文の数だけ目盛りが付き、長い文書では詰まって見えるため、値は binding で文番号に丸める。
        return Slider(value: value, in: 0...Double(max(lastIndex, 1))) { isEditing in
            if isEditing {
                if scrubbingIndex == nil {
                    scrubbingIndex = model.currentIndex
                }
            } else if let index = scrubbingIndex {
                scrubbingIndex = nil
                if index != model.currentIndex {
                    model.jump(to: index)
                }
            }
        }
        .controlSize(.small)
        .disabled(!model.canSeek)
        .help("Drag to move to another sentence")
        .accessibilityLabel("Reading position")
        .accessibilityValue("Sentence \(displayedIndex + 1) of \(model.sentenceCount)")
        // 連続のスライダーは増減の幅が範囲の割合になるため、キーボードと VoiceOver では 1 文ずつ動かす
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.step(by: 1)
            case .decrement: model.step(by: -1)
            @unknown default: break
            }
        }
        .onChange(of: model.canSeek) { _, canSeek in
            // 読み込み中・削除中になったら、ドラッグ中の移動先を捨てる
            if !canSeek { scrubbingIndex = nil }
        }
        .onChange(of: model.document?.id) {
            scrubbingIndex = nil
        }
    }

    private func currentSentence(widthClass: ReaderWidthClass, isShort: Bool) -> some View {
        Group {
            if model.isPlaying {
                currentSentenceText(widthClass: widthClass, isShort: isShort)
            } else {
                // 一時停止中は大写しの文を選択してコピーできる
                currentSentenceText(widthClass: widthClass, isShort: isShort)
                    .textSelection(.enabled)
            }
        }
        .padding(isShort ? 12 : (widthClass == .regular ? 24 : 16))
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.accentColor.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.accentColor.opacity(model.isPlaying ? 0.7 : 0.25), lineWidth: 2)
        )
        .overlay(alignment: .topTrailing) {
            noteButton
                .padding(isShort ? 4 : 8)
        }
    }

    /// 現在の文のメモを書く・直すボタン。大写しの文の右上に置く。
    private var noteButton: some View {
        let hasNote = model.currentNote != nil
        return Button {
            model.beginEditingNote()
        } label: {
            Label(
                hasNote ? LocalizedStringKey("Edit Note") : LocalizedStringKey("Add Note"),
                systemImage: hasNote ? "note.text" : "square.and.pencil"
            )
            .labelStyle(.iconOnly)
            .font(.title3)
            .frame(width: Self.noteButtonSize, height: Self.noteButtonSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(hasNote ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .disabled(!model.canEditNotes)
        .help(noteButtonHelp(hasNote: hasNote))
    }

    private func noteButtonHelp(hasNote: Bool) -> LocalizedStringKey {
        if !model.savesCurrentDocument {
            return "Notes are available when Save Documents and History is on. Turn it on, then open the file again."
        }
        return hasNote ? "Edit the note for this sentence (⇧⌘N)" : "Add a note to this sentence (⇧⌘N)"
    }

    /// 現在の文に付けたメモの冒頭。押すと編集する。
    private func notePreview(_ note: SentenceNote, isShort: Bool) -> some View {
        Button {
            model.beginEditingNote()
        } label: {
            Label {
                Text(note.text)
                    .lineLimit(isShort ? 1 : 2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } icon: {
                Image(systemName: "note.text")
                    .foregroundStyle(.tint)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, isShort ? 4 : 8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.canEditNotes)
        .fixedSize(horizontal: false, vertical: true)
        .help("Edit the note for this sentence (⇧⌘N)")
        .accessibilityLabel("Note")
        .accessibilityValue(note.text)
    }

    private static let noteButtonSize: CGFloat = 28

    private var notedIndices: Set<Int> {
        Set(model.notes.map(\.sentenceIndex))
    }

    private func currentSentenceText(widthClass: ReaderWidthClass, isShort: Bool) -> some View {
        Text(model.currentSentence ?? "")
            .font(.system(size: widthClass == .regular ? 34 : 28, weight: .semibold))
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.4)
            .frame(maxWidth: .infinity, minHeight: isShort ? 44 : 80)
            // 右上のメモボタンと重ならないよう、左右を同じだけ空けて中央をそろえる
            .padding(.horizontal, Self.noteButtonSize - (widthClass == .regular ? 8 : 4))
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
    /// メモを付けた文の番号。該当する文にはメモの印を付ける。
    let notedIndices: Set<Int>
    let alignment: Alignment
    let onSelect: @MainActor (Int) -> Void

    var body: some View {
        VStack(spacing: 10) {
            ForEach(sentences) { sentence in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if notedIndices.contains(sentence.id) {
                        Image(systemName: "note.text")
                            .font(.callout)
                            .foregroundStyle(.tint)
                            .accessibilityLabel("Has a note")
                    }
                    Text(sentence.text)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                    .opacity(opacity(for: sentence.id))
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(sentence.id) }
                    .help("Go to this sentence")
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

/// 再生／一時停止・前後移動・セーブ・コピーの操作列。
/// キーボードショートカットは「再生」メニュー（`PlaybackCommands`）に割り当てている。
private struct ControlBar: View {
    let model: ReaderModel
    let widthClass: ReaderWidthClass
    let isShort: Bool

    var body: some View {
        VStack(spacing: isShort ? 4 : 8) {
            HStack(spacing: widthClass == .regular ? 12 : 8) {
                Group {
                    Button {
                        model.step(by: -1)
                    } label: {
                        Label("Previous", systemImage: "backward.end.fill")
                    }
                    .disabled(!model.canStepBackward)
                    // ← は「再生」メニューに割り当てている。従来の ⌘← も使えるよう残す
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                    .help("Previous sentence (← or ⌘←)")

                    Button {
                        model.togglePlayback()
                    } label: {
                        Label(
                            model.isPlaying ? LocalizedStringKey("Pause") : LocalizedStringKey("Play"),
                            systemImage: model.isPlaying ? "pause.fill" : "play.fill"
                        )
                        .labelStyle(.titleAndIcon)
                        .frame(minWidth: 90)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .help(model.isPlaying ? LocalizedStringKey("Pause (Space)") : LocalizedStringKey("Play (Space)"))

                    Button {
                        model.step(by: 1)
                    } label: {
                        Label("Next", systemImage: "forward.end.fill")
                    }
                    .disabled(!model.canStepForward)
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                    .help("Next sentence (→ or ⌘→)")
                }
                .labelStyle(AdaptiveLabelStyle(iconOnly: widthClass == .minimal))

                Divider()
                    .frame(height: 22)

                Group {
                    Button {
                        model.saveManually()
                    } label: {
                        Label("Save Position", systemImage: "bookmark")
                    }
                    .disabled(!model.canSaveManually)
                    .help("Save the current position while paused (⌘S, up to \(ReaderModel.manualSaveLimit) saved positions)")

                    Button {
                        model.copyCurrentSentence()
                    } label: {
                        Label("Copy Sentence", systemImage: "doc.on.doc")
                    }
                    .disabled(!model.canCopy)
                    .help("Copy the current sentence while paused (⇧⌘C)")
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
        .padding(.vertical, isShort ? 6 : 12)
    }
}
