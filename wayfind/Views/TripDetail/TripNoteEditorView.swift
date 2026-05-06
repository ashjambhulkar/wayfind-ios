import SwiftUI

struct TripNoteEditorView: View {
    let note: TripNote
    /// When false (e.g. trip member with notes access but not editor), fields are read-only; Close dismisses without Save.
    var isEditable: Bool
    var onChanged: () -> Void

    /// True when the note was empty on disk when this editor opened (typical for “New note”).
    private let openedAsBlankNote: Bool

    @Environment(DataService.self) private var dataService
    @Environment(\.dismiss) private var dismiss

    @FocusState private var focusedField: NoteEditorFocus?

    @State private var title: String
    @State private var bodyText: String
    @State private var isSaving = false
    /// When true, skip discarding an empty note on disappear (Save already handled persistence).
    @State private var skipEmptyDiscardOnDisappear = false

    init(note: TripNote, isEditable: Bool = true, onChanged: @escaping () -> Void = {}) {
        self.note = note
        self.isEditable = isEditable
        self.onChanged = onChanged
        let trimmedTitle = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
        self.openedAsBlankNote = trimmedTitle.isEmpty && trimmedBody.isEmpty
        _title = State(initialValue: note.title)
        _bodyText = State(initialValue: note.body)
    }

    var body: some View {
        Form {
            Section(String(localized: "Title")) {
                TextField(String(localized: "Give this note a title"), text: $title)
                    .textInputAutocapitalization(.sentences)
                    .disabled(!isEditable)
                    .focused($focusedField, equals: .title)
            }

            Section(String(localized: "Note")) {
                TextField(String(localized: "Write ideas, links, reminders, or plans…"), text: $bodyText, axis: .vertical)
                    .lineLimit(8...24)
                    .disabled(!isEditable)
                    .focused($focusedField, equals: .body)
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppColors.appBackground)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Note")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .regular))
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppColors.textPrimary)
                .accessibilityLabel("Close")
            }
            if isEditable {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .fontWeight(.semibold)
                    .disabled(isSaving)
                }
            }
        }
        .task {
            guard isEditable else { return }
            try? await Task.sleep(for: TripNoteEditorTiming.sheetBodyFocusDelay)
            focusedField = .body
        }
        .onDisappear {
            Task { await discardEmptyNoteIfNeeded() }
        }
    }

    @MainActor
    private func save() async {
        isSaving = true
        defer { isSaving = false }
        skipEmptyDiscardOnDisappear = true
        await dataService.updateTripNote(noteId: note.id, title: title, body: bodyText)
        onChanged()
        HapticManager.success()
        dismiss()
    }

    /// New notes are created in the backend immediately; if the user backs out without saving
    /// and the note is still empty, delete it. Existing notes that had content are never deleted
    /// here—only refreshed if the user cleared fields and dismissed without saving.
    @MainActor
    private func discardEmptyNoteIfNeeded() async {
        guard !skipEmptyDiscardOnDisappear else { return }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.isEmpty, b.isEmpty else { return }
        if openedAsBlankNote {
            await dataService.deleteTripNote(noteId: note.id)
        }
        onChanged()
    }
}


// =============================================================================

private enum TripNoteEditorTiming {
    static let sheetBodyFocusDelay = Duration.milliseconds(350)
}

private enum NoteEditorFocus: Hashable {
    case title
    case body
}

