import SwiftUI

/// オートセーブと任意セーブの一覧。クリックでその位置を読み込む。
struct SavesSidebar: View {
    let model: ReaderModel
    /// セーブを読み込んだあとに呼ばれる（iPhone で読み上げ画面に戻るため）
    var onLoad: () -> Void = {}
    @State private var pendingDeletion: SavePoint?

    var body: some View {
        List {
            Section("オートセーブ") {
                if model.autoSaves.isEmpty {
                    placeholder("一時停止するとここに保存されます")
                } else {
                    ForEach(model.autoSaves) { save in
                        row(for: save)
                    }
                }
            }

            Section("セーブ（\(model.manualSaves.count)/\(ReaderModel.manualSaveLimit)）") {
                if model.manualSaves.isEmpty {
                    placeholder("一時停止中に「この位置をセーブ」で追加できます")
                } else {
                    ForEach(model.manualSaves) { save in
                        row(for: save)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // 一覧全体に付ける。行ごとに付けると、iOS ではスワイプ操作から開いたときに表示されない
        .confirmationDialog(
            "このセーブを削除しますか？",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { save in
            Button("削除", role: .destructive) {
                model.delete(save)
                pendingDeletion = nil
            }
        } message: { save in
            Text("「\(save.documentTitle)」\(save.sentenceIndex + 1)文目")
        }
    }

    private func row(for save: SavePoint) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Button {
                load(save)
            } label: {
                SaveRow(save: save, isCurrentDocument: model.document?.id == save.documentID)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("この位置を読み込む")

            #if os(macOS)
            Button {
                pendingDeletion = save
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("削除")
            #endif
        }
        #if os(iOS)
        // iOS では行のスワイプで削除する（削除は確認ダイアログを経る）
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                pendingDeletion = save
            } label: {
                Label("削除", systemImage: "trash")
            }
        }
        #endif
        .contextMenu {
            Button("この位置を読み込む") { load(save) }
            Divider()
            Button("削除…", role: .destructive) { pendingDeletion = save }
        }
    }

    private func load(_ save: SavePoint) {
        model.load(save)
        onLoad()
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct SaveRow: View {
    let save: SavePoint
    let isCurrentDocument: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if isCurrentDocument {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(.tint)
                }
                Text(save.documentTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(save.excerpt)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack {
                Text("\(save.sentenceIndex + 1) / \(save.sentenceCount)文目")
                    .monospacedDigit()
                Spacer()
                Text(save.createdAt, format: .dateTime.year().month().day().hour().minute())
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}
