import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Note editor

/// 1 つの文のメモを書く画面。メモは改行を含められる。
/// Return は改行の入力に使うので、保存は ⌘Return（macOS）か「保存」ボタンで行う。
struct NoteEditorView: View {
    let model: ReaderModel
    let request: NoteEditorRequest
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var confirmsDeletion = false
    @State private var failureMessage: String?
    @FocusState private var isEditorFocused: Bool

    init(model: ReaderModel, request: NoteEditorRequest) {
        self.model = model
        self.request = request
        _text = State(initialValue: request.text)
    }

    private var title: LocalizedStringKey {
        request.isNew
            ? "Add Note to Sentence \(request.sentenceIndex + 1)"
            : "Edit Note for Sentence \(request.sentenceIndex + 1)"
    }

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            sentence
            editor
                .frame(minHeight: 160, maxHeight: .infinity)
            footer
            HStack {
                if !request.isNew {
                    Button("Delete Note…", role: .destructive) {
                        confirmsDeletion = true
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .buttonStyle(.borderedProminent)
                .help("Save the note (⌘Return)")
            }
        }
        .padding(20)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 360, idealHeight: 400)
        .modifier(deletionDialog)
        .onAppear { isEditorFocused = true }
        #else
        NavigationStack {
            Form {
                Section("Sentence \(request.sentenceIndex + 1)") {
                    sentence
                }
                Section {
                    editor
                        .frame(minHeight: 180)
                } header: {
                    Text("Note")
                } footer: {
                    footer
                }
                if !request.isNew {
                    Section {
                        Button("Delete Note…", role: .destructive) {
                            confirmsDeletion = true
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
        .modifier(deletionDialog)
        .onAppear { isEditorFocused = true }
        #endif
    }

    private var sentence: some View {
        ScrollView {
            Text(request.sentence)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 80)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Sentence")
        .accessibilityValue(request.sentence)
    }

    private var editor: some View {
        TextEditor(text: $text)
            .font(.body)
            .focused($isEditorFocused)
            .accessibilityLabel("Note")
            #if os(macOS)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            #endif
    }

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let failureMessage {
                Label(failureMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            if let updatedAt = request.updatedAt {
                Text("Last modified \(updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
            } else {
                Text("Leave the note empty to remove it.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    private var deletionDialog: NoteDeletionDialog {
        NoteDeletionDialog(isPresented: $confirmsDeletion, sentenceNumber: request.sentenceIndex + 1) {
            do {
                try model.deleteNote(at: request.sentenceIndex, documentID: request.documentID)
                dismiss()
            } catch {
                failureMessage = String(localized: "Could not delete the note: \(error.localizedDescription)")
            }
        }
    }

    private func save() {
        if !request.isNew && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            confirmsDeletion = true
            return
        }
        do {
            try model.saveNote(text, for: request)
            dismiss()
        } catch {
            failureMessage = String(localized: "Could not save the note: \(error.localizedDescription)")
        }
    }
}

/// メモを削除する前の確認
private struct NoteDeletionDialog: ViewModifier {
    @Binding var isPresented: Bool
    /// 付け先の文が見つからないメモは nil
    let sentenceNumber: Int?
    let onDelete: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog("Delete this note?", isPresented: $isPresented, titleVisibility: .visible) {
            Button("Delete Note", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            if let sentenceNumber {
                Text("The note for sentence \(sentenceNumber) will be deleted. This cannot be undone.")
            } else {
                Text("The note will be deleted. This cannot be undone.")
            }
        }
    }
}

// MARK: - Notes list

/// 開いている文書のメモ一覧。メモを付けた文・メモ・最終更新日を表で表示し、CSV／TSV に書き出せる。
/// 本文が変わって付け先の文が見つからなくなったメモも、文番号なしで末尾に表示する（読み上げ画面には出ない）。
struct NotesListView: View {
    let model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var selection: Set<NoteListEntry.ID> = []
    @State private var sortOrder = [KeyPathComparator(\NoteListEntry.sortNumber)]
    @State private var editing: NoteEditorRequest?
    @State private var pendingDeletion: NoteListEntry?
    @State private var exportFile: NotesExportFile?
    @State private var failureMessage: String?

    private var entries: [NoteListEntry] { model.noteListEntries }

    private var sortedEntries: [NoteListEntry] {
        entries.sorted(using: sortOrder)
    }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack {
                Text("Notes")
                    .font(.headline)
                if let title = model.document?.title {
                    Text(title)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 10)
            content
            Divider()
            HStack {
                Text("\(entries.count) notes")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                exportMenu
                    .fixedSize()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        // 4 列の既定の幅（約 660pt）が横スクロールなしで収まる大きさにする
        .frame(minWidth: 700, idealWidth: 700, minHeight: 360, idealHeight: 480)
        .modifier(listPresentations)
        #else
        NavigationStack {
            content
                .navigationTitle("Notes")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        exportMenu
                    }
                }
        }
        .modifier(listPresentations)
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if entries.isEmpty {
            ContentUnavailableView {
                Label("No Notes", systemImage: "note.text")
            } description: {
                if model.canEditNotes {
                    Text("Use the note button on the current sentence to add a note.")
                } else {
                    Text("Notes are available when Save Documents and History is on. Turn it on, then open the file again.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            #if os(iOS)
            if horizontalSizeClass == .compact {
                compactList
            } else {
                table
            }
            #else
            table
            #endif
        }
    }

    private var table: some View {
        Table(sortedEntries, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("No.", value: \.sortNumber) { entry in
                if entry.sentenceIndex != nil {
                    Text(verbatim: entry.sentenceNumberText)
                        .monospacedDigit()
                } else {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                        .help(Self.unattachedHelp)
                        .accessibilityLabel("Sentence Not Found")
                }
            }
            .width(min: 32, ideal: 40, max: 64)
            TableColumn("Sentence", value: \.sentence) { entry in
                Text(entry.sentence)
                    .lineLimit(3)
                    .foregroundStyle(entry.sentenceIndex == nil ? .secondary : .primary)
                    .help(entry.sentenceIndex == nil ? Text(Self.unattachedHelp) : Text(entry.sentence))
            }
            .width(min: 120, ideal: 200)
            TableColumn("Note", value: \.text) { entry in
                Text(entry.text)
                    .lineLimit(3)
                    .help(entry.text)
            }
            .width(min: 120, ideal: 230)
            TableColumn("Last Modified", value: \.updatedAt) { entry in
                // 「2026年11月11日 21:00」のような表記は既定の列幅に収まらないため、数字の日付にする
                Text(entry.updatedAt, format: Date.FormatStyle(date: .numeric, time: .shortened))
                    .monospacedDigit()
                    .help(entry.updatedAt.formatted(date: .long, time: .shortened))
            }
            .width(min: 110, ideal: 140)
        }
        .contextMenu(forSelectionType: NoteListEntry.ID.self) { ids in
            if let id = ids.first, let entry = entry(id) {
                rowActions(for: entry)
            }
        } primaryAction: { ids in
            if let id = ids.first, let index = entry(id)?.sentenceIndex {
                go(to: index)
            }
        }
    }

    private static let unattachedHelp: LocalizedStringKey = "This sentence is no longer in the file. The note is kept so you can review, export, or delete it."

    private func entry(_ id: NoteListEntry.ID) -> NoteListEntry? {
        entries.first { $0.id == id }
    }

    #if os(iOS)
    private var compactList: some View {
        List(sortedEntries) { entry in
            Button {
                if let index = entry.sentenceIndex {
                    go(to: index)
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        if let index = entry.sentenceIndex {
                            Text("Sentence \(index + 1)")
                                .font(.caption.weight(.semibold))
                        } else {
                            Label("Sentence Not Found", systemImage: "questionmark.circle")
                                .font(.caption.weight(.semibold))
                        }
                        Spacer()
                        Text(entry.updatedAt, format: .dateTime.year().month().day().hour().minute())
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    Text(entry.sentence)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(entry.text)
                        .lineLimit(4)
                }
                .foregroundStyle(.primary)
            }
            .swipeActions(edge: .trailing) {
                if model.canEditNotes {
                    Button(role: .destructive) {
                        pendingDeletion = entry
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .contextMenu { rowActions(for: entry) }
        }
    }
    #endif

    @ViewBuilder
    private func rowActions(for entry: NoteListEntry) -> some View {
        // 付け先の文が見つからないメモは、移動・編集できない（内容の確認・コピー・削除だけできる）
        Button("Go to Sentence") {
            if let index = entry.sentenceIndex { go(to: index) }
        }
        .disabled(entry.sentenceIndex == nil)
        Button("Edit Note…") {
            if let index = entry.sentenceIndex { editing = model.makeNoteEditorRequest(at: index) }
        }
        .disabled(!model.canEditNotes || entry.sentenceIndex == nil)
        Button("Copy Note") { copy(entry.text) }
        Divider()
        Button("Delete Note…", role: .destructive) { pendingDeletion = entry }
            .disabled(!model.canEditNotes)
    }

    private var exportMenu: some View {
        Menu {
            ForEach(NotesExport.Format.allCases) { format in
                Button(format.menuTitle) {
                    exportFile = NotesExportFile(
                        format: format,
                        data: model.exportedNotes(format: format)
                    )
                }
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .disabled(entries.isEmpty)
        .help("Save the notes as a CSV or TSV file")
    }

    private var listPresentations: NotesListPresentations {
        NotesListPresentations(
            model: model,
            editing: $editing,
            pendingDeletion: $pendingDeletion,
            exportFile: $exportFile,
            failureMessage: $failureMessage,
            defaultFilename: model.notesExportFilename
        )
    }

    private func go(to index: Int) {
        model.jump(to: index)
        dismiss()
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

/// メモ一覧から出す編集画面・削除の確認・書き出し・エラー表示
private struct NotesListPresentations: ViewModifier {
    let model: ReaderModel
    @Binding var editing: NoteEditorRequest?
    @Binding var pendingDeletion: NoteListEntry?
    @Binding var exportFile: NotesExportFile?
    @Binding var failureMessage: String?
    let defaultFilename: String

    func body(content: Content) -> some View {
        content
            .sheet(item: $editing) { request in
                NoteEditorView(model: model, request: request)
            }
            .modifier(NoteDeletionDialog(
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                sentenceNumber: pendingDeletion?.sentenceIndex.map { $0 + 1 }
            ) {
                guard let entry = pendingDeletion, let documentID = model.document?.notesID else { return }
                do {
                    try model.deleteNote(entry, documentID: documentID)
                } catch {
                    failureMessage = String(localized: "Could not delete the note: \(error.localizedDescription)")
                }
                pendingDeletion = nil
            })
            .fileExporter(
                isPresented: Binding(
                    get: { exportFile != nil },
                    set: { if !$0 { exportFile = nil } }
                ),
                document: exportFile,
                contentType: exportFile?.format.contentType ?? .commaSeparatedText,
                defaultFilename: defaultFilename
            ) { result in
                if case let .failure(error) = result {
                    failureMessage = String(localized: "Could not export the notes: \(error.localizedDescription)")
                }
            }
            .alert(
                "Error",
                isPresented: Binding(
                    get: { failureMessage != nil },
                    set: { if !$0 { failureMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failureMessage ?? "")
            }
    }
}

// MARK: - Export

extension NotesExport.Format {
    var contentType: UTType {
        switch self {
        case .csv: .commaSeparatedText
        case .tsv: .tabSeparatedText
        }
    }

    var menuTitle: LocalizedStringKey {
        switch self {
        case .csv: "CSV (Comma-Separated)…"
        case .tsv: "TSV (Tab-Separated)…"
        }
    }
}

/// 書き出すメモ一覧。書き出しを選んだ時点の内容を保持する。
nonisolated struct NotesExportFile: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText, .tabSeparatedText]

    let format: NotesExport.Format
    let data: Data

    init(format: NotesExport.Format, data: Data) {
        self.format = format
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
