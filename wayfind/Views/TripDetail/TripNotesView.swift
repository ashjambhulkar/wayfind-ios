import SwiftUI

// MARK: - List row (title · body preview · timestamp)

private struct TripNoteListRow: View {
    let note: TripNote

    private var titleText: String {
        note.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var bodyText: String {
        note.body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasTitle: Bool { !titleText.isEmpty }
    private var hasBody: Bool { !bodyText.isEmpty }

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            MapStyleIcon(
                systemName: "note.text",
                size: .small,
                accent: AppColors.appPrimary,
                accessibilityLabel: "Note"
            )

            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    if hasTitle {
                        Text(titleText)
                            .font(.appBody.weight(.semibold))
                            .foregroundStyle(AppColors.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }

                    if hasBody {
                        Text(bodyText)
                            .font(.appBody)
                            .foregroundStyle(hasTitle ? AppColors.textSecondary : AppColors.textPrimary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text(note.updatedAt.noteListCaption)
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppColors.textTertiary.opacity(0.55))
                .accessibilityHidden(true)
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .strokeBorder(AppColors.appDivider, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var parts: [String] = []
        if hasTitle { parts.append(titleText) }
        if hasBody { parts.append(bodyText) }
        parts.append(note.updatedAt.noteListCaption)
        return parts.joined(separator: ". ")
    }
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
            } else if displayNotes.isEmpty {
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
                ScrollView {
                    LazyVStack(spacing: AppSpacing.md) {
                        notesHeader

                        ForEach(displayNotes) { note in
                            Button {
                                HapticManager.selection()
                                noteToEdit = note
                            } label: {
                                TripNoteListRow(note: note)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(AppSpacing.lg)
                }
                .scrollIndicators(.hidden)
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
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(AppColors.appPrimary)
                    }
                    .buttonStyle(.plain)
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

    private var notesHeader: some View {
        HStack(spacing: AppSpacing.md) {
            MapStyleIcon(
                systemName: "lightbulb.fill",
                size: .small,
                accent: AppColors.appPrimary,
                backgroundStyle: .soft,
                accessibilityLabel: "Trip notes"
            )

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("\(displayNotes.count) \(displayNotes.count == 1 ? "note" : "notes")")
                    .font(.appBody.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
                Text("Ideas, links, reminders, and shared context for this trip")
                    .font(.appSmall)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(AppSpacing.md)
        .background(AppColors.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .strokeBorder(AppColors.appDivider, lineWidth: 1)
        }
    }

    /// Notes with at least a title or body — never show placeholder rows for blank server records.
    private var displayNotes: [TripNote] {
        notes.filter { !$0.isVisuallyEmpty }
    }

    private func reload() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        var loaded = await dataService.listTripNotes(tripId: trip.id)
        if collaborationStore.canEditNotes {
            let blanks = loaded.filter(\.isVisuallyEmpty)
            if !blanks.isEmpty {
                for n in blanks {
                    await dataService.deleteTripNote(noteId: n.id)
                }
                loaded = await dataService.listTripNotes(tripId: trip.id)
            }
        }
        notes = loaded
    }

    private func createNoteAndOpen() async {
        guard let note = await dataService.createTripNote(tripId: trip.id) else { return }
        notes.insert(note, at: 0)
        noteToEdit = note
    }
}


// =============================================================================

