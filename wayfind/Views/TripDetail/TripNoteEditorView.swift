import SwiftUI

struct TripNoteEditorView: View {
    let note: TripNote
    var onChanged: () -> Void

    @Environment(DataService.self) private var dataService
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var bodyText: String
    @State private var isSaving = false
    @State private var showDeleteConfirm = false

    init(note: TripNote, onChanged: @escaping () -> Void = {}) {
        self.note = note
        self.onChanged = onChanged
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
    }

    @MainActor
    private func save() async {
        isSaving = true
        defer { isSaving = false }
        await dataService.updateTripNote(noteId: note.id, title: title, body: bodyText)
        onChanged()
        HapticManager.success()
        dismiss()
    }

    @MainActor
    private func deleteNote() async {
        await dataService.deleteTripNote(noteId: note.id)
        onChanged()
        HapticManager.success()
        dismiss()
    }
}
