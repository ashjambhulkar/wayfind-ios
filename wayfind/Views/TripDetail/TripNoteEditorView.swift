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

    private var noteTitleSection: some View {
        TripNoteMapSectionCard(title: "Title") {
            TextField("Give this note a title", text: $title)
                .font(.appBody)
                .foregroundStyle(AppColors.textPrimary)
                .textInputAutocapitalization(.sentences)
                .disabled(!isEditable)
                .focused($focusedField, equals: .title)
                .frame(minHeight: TripNoteMapFormMetrics.rowMinHeight)
                .padding(.horizontal, AppSpacing.md)
        }
    }

    private var noteBodySection: some View {
        TripNoteMapSectionCard(title: "Note") {
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
                    .disabled(!isEditable)
                    .focused($focusedField, equals: .body)
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

private enum TripNoteEditorTiming {
    /// Wait for sheet presentation before focusing the body field so the keyboard appears reliably.
    static let sheetBodyFocusDelay = Duration.milliseconds(350)
}

private enum TripNoteMapFormMetrics {
    static let rowMinHeight: CGFloat = 56
    static let bodyMinHeight: CGFloat = 220
}

private enum NoteEditorFocus: Hashable {
    case title
    case body
}

