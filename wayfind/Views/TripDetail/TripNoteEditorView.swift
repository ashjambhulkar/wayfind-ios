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
            VStack(alignment: .leading, spacing: AppSpacing.xl) {
                noteTitleSection

                noteBodySection
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

    private var noteTitleSection: some View {
        TripNoteMapSectionCard(title: "Title") {
            HStack(spacing: AppSpacing.md) {
                MapStyleIcon(
                    systemName: "textformat",
                    size: .small,
                    accent: AppColors.appPrimary,
                    accessibilityLabel: "Title"
                )

                TextField("Give this note a title", text: $title)
                    .font(.appBody)
                    .foregroundStyle(AppColors.textPrimary)
                    .textInputAutocapitalization(.sentences)
                    .frame(minHeight: TripNoteMapFormMetrics.rowMinHeight)
            }
            .padding(.horizontal, AppSpacing.md)
        }
    }

    private var noteBodySection: some View {
        TripNoteMapSectionCard(title: "Note") {
            HStack(alignment: .top, spacing: AppSpacing.md) {
                MapStyleIcon(
                    systemName: "note.text",
                    size: .small,
                    accent: AppColors.appPrimary,
                    accessibilityLabel: "Note body"
                )
                .padding(.top, AppSpacing.sm)

                ZStack(alignment: .topLeading) {
                    if bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Write ideas, links, reminders, or plans for this trip")
                            .font(.appBody)
                            .foregroundStyle(AppColors.textTertiary)
                            .padding(.top, AppSpacing.sm)
                            .allowsHitTesting(false)
                    }

                    TextField("", text: $bodyText, axis: .vertical)
                        .font(.appBody)
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(8...24)
                }
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm)
            .frame(minHeight: TripNoteMapFormMetrics.bodyMinHeight, alignment: .top)
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

private struct TripNoteMapSectionCard<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            FormSectionTitle(title)

            VStack(spacing: 0) {
                content
            }
            .background(AppColors.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                    .strokeBorder(AppColors.appDivider, lineWidth: 1)
            }
        }
    }
}

private enum TripNoteMapFormMetrics {
    static let rowMinHeight: CGFloat = 56
    static let bodyMinHeight: CGFloat = 220
}

