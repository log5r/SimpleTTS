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

    /// ヒンジが動いている間（最後に動いたとみなしてから `hingeSettleDelay` まで）は true。
    /// その間は位置スライダーへの入力を受け付けない。
    /// 開閉の途中では、ヒンジの開き具合の段階が変わる前から折り目の位置が少しずつ動き、
    /// ドラッグ中のスライダーに編集終了が届いたり、止まった指の下でスライダーが動いて値が変わったりする。
    /// そのまま受け付けると、指を離していないのに読み上げ位置が移動する（iPhone Duo シミュレータで確認）。
    @State private var isHingeMoving = false
    /// ヒンジが動いたとみなした回数。増えるたびに、`isHingeMoving` を戻す待ち時間をやり直す。
    @State private var hingeChangeCount = 0

    /// ドラッグ中に読み上げ画面の大きさが変わった（回転など）とき true にし、そのドラッグの残りを無視する。
    /// 回転してもドラッグは続き、指を少し動かすと、新しい配置で指の下にある位置へつまみが飛ぶ。
    /// そのまま離すと、見出しに出ていた移動先とは別の文へ移動してしまう（iPhone Duo シミュレータで確認）。
    /// 編集終了（指を離したとき）か、スライダーが消えたときに false に戻す。
    @State private var ignoresInterruptedDrag = false

    /// ヒンジが止まってから、位置スライダーへの入力を再び受け付けるまでの時間
    private static let hingeSettleDelay: Duration = .milliseconds(500)

    /// 見出しに表示する文番号（0 始まり）。ドラッグ中は移動先を示す。
    private var displayedIndex: Int { scrubbingIndex ?? model.currentIndex }

    var body: some View {
        if let document = model.document {
            // 文の長さに関係なく、詳細カラムに割り当てられたサイズでレイアウトする。
            GeometryReader { geometry in
                Group {
                    if let split = FoldSplit(size: geometry.size, divisions: Self.divisionFrames(in: geometry)) {
                        foldedLayout(for: document, split: split)
                    } else {
                        let widthClass = ReaderWidthClass(width: geometry.size.width)
                        let isShort = geometry.size.height < Self.shortHeightThreshold
                        VStack(spacing: 0) {
                            header(for: document, widthClass: widthClass, isShort: isShort)
                            Divider()
                            readingArea(widthClass: widthClass, isShort: isShort)
                            Divider()
                            ControlBar(model: model, widthClass: widthClass, isShort: isShort)
                        }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .onChange(of: geometry.size) {
                    // ドラッグ中に回転などで配置が変わったら、移動先を捨てて、指を離すまでの入力を無視する
                    if scrubbingIndex != nil {
                        scrubbingIndex = nil
                        ignoresInterruptedDrag = true
                    }
                }
            }
            #if os(iOS)
            .modifier(HingeMotionObserver(onMove: hingeDidMove))
            .task(id: hingeChangeCount) {
                guard isHingeMoving else { return }
                // 次の変化が来れば、このタスクは取り消されて待ち直しになる
                try? await Task.sleep(for: Self.hingeSettleDelay)
                guard !Task.isCancelled else { return }
                isHingeMoving = false
            }
            #endif
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

    /// ヒンジが動いたとき（`HingeMotion` を参照）。ドラッグ中の移動先を捨て、しばらく位置スライダーを止める。
    /// ヒンジの変化の通知は、それに伴うスライダーの編集終了より先に届く（iPhone Duo シミュレータで確認）。
    /// 移動先を先に捨てるので、そのあと届いた編集終了では移動しない（`scrubbingIndex == nil`）。
    private func hingeDidMove() {
        scrubbingIndex = nil
        isHingeMoving = true
        hingeChangeCount &+= 1
    }

    /// 前後の文と大写しの文
    private func readingArea(widthClass: ReaderWidthClass, isShort: Bool) -> some View {
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
    }

    /// 折り目で 2 つに分けたレイアウト（iPhone Duo の内側の画面）。
    /// 先頭側（左または上）に文を、末尾側（右または下）に見出しと操作列を置き、折り目の上には何も置かない。
    /// 大写しの文やボタンが折り目をまたぐと、本を開いたような角度で持ったときに読みにくく、押しにくいため。
    private func foldedLayout(for document: ReaderDocument, split: FoldSplit) -> some View {
        let layout = split.axis == .horizontal
            ? AnyLayout(HStackLayout(spacing: 0))
            : AnyLayout(VStackLayout(spacing: 0))
        let textWidthClass = ReaderWidthClass(width: split.first.width)
        let textIsShort = split.first.height < Self.shortHeightThreshold
        let controlsWidthClass = ReaderWidthClass(width: split.second.width)
        let controlsAreShort = split.second.height < Self.shortHeightThreshold
        return layout {
            readingArea(widthClass: textWidthClass, isShort: textIsShort)
                .frame(width: split.first.width, height: split.first.height)
            Color.clear
                .frame(width: split.gap.width, height: split.gap.height)
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                header(for: document, widthClass: controlsWidthClass, isShort: controlsAreShort)
                Divider()
                Spacer(minLength: 0)
                ControlBar(model: model, widthClass: controlsWidthClass, isShort: controlsAreShort)
                Spacer(minLength: 0)
            }
            .frame(width: split.second.width, height: split.second.height)
        }
    }

    /// 読み上げ画面を横切る折り目の領域（読み上げ画面の座標）。折り目のない画面では空。
    /// macOS には折り目がないので問い合わせない。
    private static func divisionFrames(in geometry: GeometryProxy) -> [CGRect] {
        #if os(iOS)
        if #available(iOS 27.1, *) {
            return geometry.reservedRegions(kind: .division).map(\.frame)
        }
        #endif
        return []
    }

    private func header(for document: ReaderDocument, widthClass: ReaderWidthClass, isShort: Bool) -> some View {
        VStack(spacing: 6) {
            // 文字を大きくして 1 行に収まらないときは、文番号とメモの一覧ボタンを 2 行目に移す
            // （iPhone Duo の分割した区画で、ボタンが折り目をまたがないように）。
            // 題名は省略して縮められるので、収まるかどうかの判定には含めない（理想の幅を 0 にしている）。
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    headerTitle(for: document)
                    headerStatus(widthClass: widthClass)
                    sentenceCounter
                        .fixedSize()
                    notesButton(widthClass: widthClass)
                }

                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        headerTitle(for: document)
                        headerStatus(widthClass: widthClass)
                    }
                    HStack(spacing: 8) {
                        // 最後の並べ方は収まらなくても使われるので、文番号は縮めてでも収める
                        sentenceCounter
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        Spacer(minLength: 8)
                        notesButton(widthClass: widthClass)
                    }
                }
            }
            positionSlider
            // 再生前から高さを確保し、声名の表示で本文や操作列が上下に動かないようにする。
            Text(model.isPlaying
                 ? model.currentVoiceName.map { String(localized: "Reading voice: \($0)") }
                    ?? String(localized: "Reading voice: Checking…")
                 : " ")
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(model.currentVoiceName ?? "")
                .accessibilityHidden(!model.isPlaying)
            if !model.savesCurrentDocument {
                Label("This document and its history will not be saved", systemImage: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, isShort ? 6 : 10)
    }

    /// 見出しの文書アイコンと題名。余った幅を使い、足りなければ中ほどを省略する。
    private func headerTitle(for document: ReaderDocument) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
            Text(document.title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .layoutPriority(-1)
    }

    /// 読み上げ中／一時停止中の表示
    private func headerStatus(widthClass: ReaderWidthClass) -> some View {
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
    }

    private var sentenceCounter: some View {
        Text("\(displayedIndex + 1) / \(model.sentenceCount)")
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    private func notesButton(widthClass: ReaderWidthClass) -> some View {
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

    /// 読み上げ位置を示し、ドラッグやクリックで別の文へ移動できるスライダー。
    /// キーボード（←／→）や VoiceOver の増減では、その場で 1 文ずつ移動する。
    private var positionSlider: some View {
        let lastIndex = max(model.sentenceCount - 1, 0)
        let value = Binding<Double>(
            get: { Double(displayedIndex) },
            set: { newValue in
                // ヒンジが動いている間は、`.disabled` にしても指の下でスライダーが動いて値が届くことがある
                guard !isHingeMoving, !ignoresInterruptedDrag else { return }
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
                // ヒンジが動いている間に始まった編集は、指の下でスライダーが動いたことによるもので、利用者の操作ではない。
                // 移動先を持たなければ、その編集の終了でも移動しない。
                if scrubbingIndex == nil && !isHingeMoving && !ignoresInterruptedDrag {
                    scrubbingIndex = model.currentIndex
                }
            } else if ignoresInterruptedDrag {
                // 中断したドラッグの指を離した。移動はしない（移動先は中断したときに捨てている）。
                ignoresInterruptedDrag = false
            } else if let index = scrubbingIndex {
                scrubbingIndex = nil
                if index != model.currentIndex {
                    model.jump(to: index)
                }
            }
        }
        .controlSize(.small)
        .disabled(!model.canSeek || isHingeMoving)
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
        .onDisappear {
            // 開閉・回転によるレイアウト変更で Slider が消えても、親の @State は残る。
            // 編集終了の通知に頼らず仮位置を捨て、再生中の実際の文番号に戻す。
            scrubbingIndex = nil
            ignoresInterruptedDrag = false
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

#if os(iOS)
/// ヒンジが動いたら `onMove` を呼ぶ。動いたかどうかは `HingeMotion` で判定する。
///
/// 折り目の領域（`GeometryProxy.reservedRegions`）の変化は、`GeometryReader` がそのまま反映する。
/// 開き具合が変わるたびに読み上げ画面を作り直す（`.id`）必要はなく、作り直すとツールバーの
/// 「声と速度」のポップオーバーが閉じてしまう（iPhone Duo シミュレータで確認）。
private struct HingeMotionObserver: ViewModifier {
    let onMove: () -> Void

    /// 前回 `onMove` を呼んだときのヒンジ。まだ呼んでいなければ nil。
    @State private var reference: HingeMotion.Snapshot?

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content
                .onHingeChange { _, context in
                    let current = HingeMotion.Snapshot(
                        status: context.hinge.map { AnyHashable($0.status) },
                        degrees: context.hinge?.angle.degrees
                    )
                    if HingeMotion.hasMoved(from: reference, to: current) {
                        reference = current
                        onMove()
                    }
                }
        } else {
            content
        }
    }
}
#endif

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

    private var rowSpacing: CGFloat { isShort ? 4 : 8 }
    private var buttonSpacing: CGFloat { widthClass == .regular ? 12 : 8 }

    var body: some View {
        VStack(spacing: rowSpacing) {
            // 文字を大きくすると（アクセシビリティサイズなど）、横一列では割り当てられた幅に収まらないことがある。
            // iPhone Duo の分割した区画では、はみ出すと折り目をまたぐ。収まる並べ方のうち行の少ないものを選び、
            // どの並べ方でもすべてのボタンを表示する（はみ出す分を隠すことはしない）。
            // 最後の並べ方の幅は再生ボタン 1 つ分なので、最大のアクセシビリティサイズでも
            // `FoldSplit.minimumPaneLength` の区画に収まる（iPhone Duo シミュレータで確認）。
            ViewThatFits(in: .horizontal) {
                HStack(spacing: buttonSpacing) {
                    playbackButtons
                    Divider()
                        .frame(height: 22)
                    documentButtons
                }
                .fixedSize()

                VStack(spacing: rowSpacing) {
                    HStack(spacing: buttonSpacing) { playbackButtons }
                        .fixedSize()
                    HStack(spacing: buttonSpacing) { documentButtons }
                        .fixedSize()
                }

                VStack(spacing: rowSpacing) {
                    playButton
                        .fixedSize()
                    HStack(spacing: buttonSpacing) {
                        previousButton
                        nextButton
                    }
                    .labelStyle(AdaptiveLabelStyle(iconOnly: widthClass == .minimal))
                    .fixedSize()
                    HStack(spacing: buttonSpacing) { documentButtons }
                        .fixedSize()
                }
            }

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

    /// 前の文・再生／一時停止・次の文
    private var playbackButtons: some View {
        Group {
            previousButton
            playButton
            nextButton
        }
        .labelStyle(AdaptiveLabelStyle(iconOnly: widthClass == .minimal))
    }

    /// 位置のセーブ・文のコピー
    private var documentButtons: some View {
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

    private var previousButton: some View {
        Button {
            model.step(by: -1)
        } label: {
            Label("Previous", systemImage: "backward.end.fill")
        }
        .disabled(!model.canStepBackward)
        // ← は「再生」メニューに割り当てている。従来の ⌘← も使えるよう残す
        // （検索欄に入力中は、行頭への移動に譲る）
        .keyboardShortcut(commandArrow(.leftArrow))
        .help("Previous sentence (← or ⌘←)")
    }

    private var playButton: some View {
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
    }

    private var nextButton: some View {
        Button {
            model.step(by: 1)
        } label: {
            Label("Next", systemImage: "forward.end.fill")
        }
        .disabled(!model.canStepForward)
        .keyboardShortcut(commandArrow(.rightArrow))
        .help("Next sentence (→ or ⌘→)")
    }

    private func commandArrow(_ key: KeyEquivalent) -> KeyboardShortcut? {
        model.allowsPlaybackKeyShortcuts ? KeyboardShortcut(key, modifiers: [.command]) : nil
    }
}
