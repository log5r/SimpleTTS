import SwiftUI

/// 読み込み結果を一覧と本文で確認し、未一致の行をユーザーが対応付ける。
struct NotesImportView: View {
    let model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @State private var plan: NoteImportPlan
    @State private var selection: Int?
    @State private var failureMessage: String?

    init(model: ReaderModel, plan: NoteImportPlan) {
        self.model = model
        _plan = State(initialValue: plan)
        _selection = State(initialValue: plan.items.first(where: {
            $0.assignment == .unresolved || plan.needsReplacementConfirmation($0) || plan.hasDuplicateTarget($0)
        })?.id ?? plan.items.first?.id)
    }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Import Notes").font(.headline)
                instructions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            Divider()
            HSplitView {
                List(plan.items, selection: $selection) { item in
                    importRow(item).tag(item.id)
                }
                .frame(minWidth: 220, idealWidth: 250, maxWidth: 320)
                if let position = plan.items.firstIndex(where: { $0.id == selection }) {
                    assignmentEditor(at: position)
                        .frame(minWidth: 430, maxWidth: .infinity)
                } else {
                    ContentUnavailableView("Select a Note", systemImage: "note.text")
                }
            }
            Divider()
            footer.padding(16)
        }
        .frame(minWidth: 780, idealWidth: 880, minHeight: 600, idealHeight: 700)
        .alert("Error", isPresented: errorIsPresented) {
            Button("OK", role: .cancel) {}
        } message: { Text(failureMessage ?? "") }
        #else
        NavigationStack {
            List {
                Section { instructions }
                ForEach(plan.items.indices, id: \.self) { position in
                    NavigationLink {
                        assignmentEditor(at: position)
                            .navigationTitle("Row \(plan.items[position].id)")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: { importRow(plan.items[position]) }
                }
            }
            .navigationTitle("Import Notes")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { footer.padding().background(.bar) }
        }
        .alert("Error", isPresented: errorIsPresented) {
            Button("OK", role: .cancel) {}
        } message: { Text(failureMessage ?? "") }
        #endif
    }

    private var instructions: some View {
        Text("Matching sentences are assigned automatically. Review each row, choose a destination for unmatched text, or skip it. Existing notes are replaced only with your confirmation.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private func importRow(_ item: NoteImportItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Row \(item.id)").font(.caption).foregroundStyle(.secondary)
            Text(item.source.sentence).lineLimit(2)
            if item.assignment == .skip {
                Label("Skipped", systemImage: "minus.circle").foregroundStyle(.secondary)
            } else if plan.hasDuplicateTarget(item) {
                Label("Duplicate Destination", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else if item.assignment == .unresolved {
                Label("Choose a Sentence", systemImage: "questionmark.circle").foregroundStyle(.orange)
            } else if plan.needsReplacementConfirmation(item) && !item.replacesExisting {
                Label("Confirm Replacement", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else if let index = item.targetIndex {
                Label("Sentence \(index + 1)", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.vertical, 4)
    }

    private func assignmentEditor(at position: Int) -> some View {
        NoteImportAssignmentView(item: $plan.items[position], sentences: plan.sentences,
                                 existing: plan.existingNote(for: plan.items[position]),
                                 hasDuplicateTarget: plan.hasDuplicateTarget(plan.items[position]))
            .id(plan.items[position].id)
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(plan.selectedCount) notes selected")
                if plan.unresolvedCount > 0 {
                    Text("\(plan.unresolvedCount) rows need a destination or must be skipped")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Import") {
                do {
                    try model.importNotes(plan)
                    dismiss()
                } catch {
                    failureMessage = String(localized: "Could not import the notes: \(error.localizedDescription)")
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!plan.canImport || !model.canEditNotes)
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(get: { failureMessage != nil }, set: { if !$0 { failureMessage = nil } })
    }
}

private struct NoteImportAssignmentView: View {
    @Binding var item: NoteImportItem
    let sentences: [String]
    let existing: SentenceNote?
    let hasDuplicateTarget: Bool
    @State private var query = ""

    private var candidates: [Int] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return Array(sentences.indices.lazy.filter {
            trimmed.isEmpty || String($0 + 1) == trimmed || sentences[$0].localizedStandardContains(trimmed)
        }.prefix(200))
    }

    private var assignment: Binding<NoteImportItem.Assignment> {
        Binding(get: { item.assignment }, set: { value in
            if item.assignment != value { item.replacesExisting = false }
            item.assignment = value
        })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("CSV Sentence") {
                    VStack(alignment: .leading, spacing: 6) {
                        if let index = item.source.sentenceIndex {
                            Text("Sentence \(index + 1)").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(item.source.sentence).textSelection(.enabled)
                        matchDescription.font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Imported Note") {
                    Text(item.source.text).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Picker("Import Action", selection: assignment) {
                    Text("Choose a Sentence…").tag(NoteImportItem.Assignment.unresolved)
                    Text("Skip This Row").tag(NoteImportItem.Assignment.skip)
                    if let index = item.targetIndex {
                        Text("Sentence \(index + 1)").tag(NoteImportItem.Assignment.sentence(index))
                    }
                }
                if item.assignment != .skip {
                    destinationPicker
                    if let index = item.targetIndex {
                        GroupBox("Destination Sentence") {
                            VStack(alignment: .leading, spacing: 8) {
                                if index > 0 { Text(sentences[index - 1]).foregroundStyle(.secondary) }
                                Text(sentences[index]).fontWeight(.medium)
                                if index + 1 < sentences.count { Text(sentences[index + 1]).foregroundStyle(.secondary) }
                            }
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if hasDuplicateTarget {
                            Label("Another imported note uses this sentence. Choose a different sentence or skip this row.", systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(.orange)
                        }
                        if let existing, existing.text != item.source.text {
                            GroupBox("Existing Note") {
                                Text(existing.text).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Toggle("Replace this existing note with the imported note", isOn: $item.replacesExisting)
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var matchDescription: some View {
        switch item.match {
        case .exact: Text("The sentence number and text match.")
        case .moved: Text("The text matches a sentence at a different position.")
        case .ambiguous: Text("More than one sentence matches this text. Choose the destination.")
        case .missing: Text("No sentence matches this text. Choose the destination.")
        }
    }

    private var destinationPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Destination Sentence").font(.headline)
            TextField("Find a destination by text or sentence number", text: $query)
                .textFieldStyle(.roundedBorder)
            // 選択をボタンにし、キーボード操作と VoiceOver の両方から対応先を確定できるようにする。
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(candidates, id: \.self) { index in
                        Button {
                            assignment.wrappedValue = .sentence(index)
                        } label: {
                            HStack(alignment: .top) {
                                Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                                    .frame(minWidth: 32, alignment: .trailing)
                                Text(sentences[index]).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                                if item.targetIndex == index { Image(systemName: "checkmark") }
                            }
                            .padding(8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(item.targetIndex == index ? Color.accentColor.opacity(0.12) : Color.clear)
                        .accessibilityAddTraits(item.targetIndex == index ? .isSelected : [])
                        Divider()
                    }
                    if candidates.isEmpty { Text("No Matching Sentences").foregroundStyle(.secondary).padding(8) }
                }
            }
            .frame(height: 180)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            if candidates.count == 200 {
                Text("Showing up to 200 sentences. Refine the search to find another destination.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
