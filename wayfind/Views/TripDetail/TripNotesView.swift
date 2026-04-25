import SwiftUI

private func tripNoteCardHeadline(_ note: TripNote) -> String {
    let t = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !t.isEmpty { return t }
    let first =
        note.body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    if first.isEmpty { return "New Note" }
    return first.count > 80 ? String(first.prefix(80)) + "…" : first
}

struct TripNotesView: View {
    let trip: Trip

    @Environment(DataService.self) private var dataService
    @Environment(CollaborationStore.self) private var collaborationStore
    @State private var notes: [TripNote] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var noteToEdit: TripNote?

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                Text(loadError)
                    .font(.appBody)
                    .foregroundStyle(AppColors.appError)
                    .multilineTextAlignment(.center)
                    .padding(AppSpacing.xl)
            } else if notes.isEmpty {
                // The empty-state CTA is the same write surface as the
                // toolbar's "New note" button — both gated together by
                // `canEditNotes`. Viewers see the empty state messaging
                // without an action so the surface still explains itself.
                if collaborationStore.canEditNotes {
                    EmptyStateView(
                        sfSymbol: "note.text",
                        title: "No notes yet",
                        subtitle: "Capture ideas, links, and reminders for this trip.",
                        buttonTitle: "+ New note",
                        buttonAction: { Task { await createNoteAndOpen() } }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyStateView(
                        sfSymbol: "note.text",
                        title: "No notes yet",
                        subtitle: "When the owner adds notes, they'll show up here.",
                        buttonTitle: nil,
                        buttonAction: nil
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                List {
                    ForEach(notes) { note in
                        Button {
                            noteToEdit = note
                        } label: {
                            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                Text(tripNoteCardHeadline(note))
                                    .font(.cardTitle)
                                    .foregroundStyle(AppColors.textPrimary)
                                    .lineLimit(2)
                                Text(note.updatedAt.shortFormatted)
                                    .font(.appCaption)
                                    .foregroundStyle(AppColors.textTertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, AppSpacing.xs)
                        }
                        .listRowBackground(AppColors.appSurface)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(AppColors.appBackground)
        .navigationTitle("Notes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if collaborationStore.canEditNotes {
                    Button {
                        Task { await createNoteAndOpen() }
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .foregroundStyle(AppColors.appPrimary)
                    }
                    .accessibilityLabel("New note")
                }
            }
        }
        .navigationDestination(item: $noteToEdit) { note in
            TripNoteEditorView(note: note) {
                Task { await reload() }
            }
        }
        .task {
            await reload()
        }
    }

    private func reload() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        notes = await dataService.listTripNotes(tripId: trip.id)
    }

    private func createNoteAndOpen() async {
        guard let note = await dataService.createTripNote(tripId: trip.id) else { return }
        notes.insert(note, at: 0)
        noteToEdit = note
    }
}


// =============================================================================

