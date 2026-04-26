import SwiftUI

struct TripNoteEditorView: View {
    let note: TripNote
    var onChanged: () -> Void

    /// True when the note was empty on disk when this editor opened (typical for “New note”).
    private let openedAsBlankNote: Bool

    @Environment(DataService.self) private var dataService
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var bodyText: String
    @State private var isSaving = false
    @State private var showDeleteConfirm = false
    /// When true, skip discarding an empty note on disappear (Save / Delete already handled persistence).
    @State private var skipEmptyDiscardOnDisappear = false

    init(note: TripNote, onChanged: @escaping () -> Void = {}) {
        self.note = note
        self.onChanged = onChanged
        let trimmedTitle = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
        self.openedAsBlankNote = trimmedTitle.isEmpty && trimmedBody.isEmpty
        _title = State(initialValue: note.title)
        _bodyText = State(initialValue: note.body)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                TextField("Title", text: $title)
                    .font(.sectionHeader)
                    .foregroundStyle(AppColors.textPrimary)
                    .padding(AppSpacing.md)
                    .background(AppColors.appSurface)
                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                            .strokeBorder(AppColors.appDivider, lineWidth: 1)
                    )

                Text("Body")
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textSecondary)
                TextField("Write something…", text: $bodyText, axis: .vertical)
                    .font(.appBody)
                    .lineLimit(8...24)
                    .padding(AppSpacing.md)
                    .background(AppColors.appSurface)
                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                            .strokeBorder(AppColors.appDivider, lineWidth: 1)
                    )
            }
            .padding(AppSpacing.lg)
        }
        .background(AppColors.appBackground)
        .navigationTitle("Note")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    Task { await save() }
                }
                .fontWeight(.semibold)
                .disabled(isSaving)
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("Delete", role: .destructive) {
                    showDeleteConfirm = true
                }
            }
        }
        .confirmationDialog("Delete this note?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { await deleteNote() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
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

    @MainActor
    private func deleteNote() async {
        skipEmptyDiscardOnDisappear = true
        await dataService.deleteTripNote(noteId: note.id)
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

