import SwiftUI

struct TripChecklistsView: View {
    let trip: Trip

    @Environment(DataService.self) private var dataService
    @Environment(CollaborationStore.self) private var collaborationStore
    @State private var rows: [TripChecklistWithItems] = []
    @State private var selectedTab: TripChecklistTemplateKey = .packing
    @State private var isLoading = true
    @State private var showAddItemAlert = false
    @State private var newItemTitle = ""

    private var activeList: TripChecklistWithItems? {
        rows.first { $0.templateKey == selectedTab.rawValue }
    }

    private var canAddChecklistItem: Bool {
        collaborationStore.canEdit && !isLoading && !rows.isEmpty && activeList != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Checklist", selection: $selectedTab) {
                ForEach(TripChecklistTemplateKey.allCases, id: \.self) { key in
                    Text(key.tabLabel).tag(key)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, AppSpacing.md)

            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if rows.isEmpty {
                    EmptyStateView(
                        sfSymbol: "checklist",
                        title: "No checklists yet",
                        subtitle: "Open this trip on the web once to sync default packing and to-do lists.",
                        buttonTitle: nil,
                        buttonAction: nil
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let list = activeList {
                    if list.items.isEmpty {
                        EmptyStateView(
                            sfSymbol: "checklist",
                            title: "Nothing here yet",
                            subtitle: collaborationStore.canEdit
                                ? "Tap + to add an item, or manage lists on the web."
                                : "When editors add items, they'll show up here.",
                            buttonTitle: nil,
                            buttonAction: nil
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List {
                            ForEach(list.items) { item in
                                ChecklistItemRow(
                                    title: item.title,
                                    isDone: isDone(item),
                                    canDelete: collaborationStore.canEdit
                                ) {
                                    Task {
                                        await setDone(itemId: item.id, isDone: !isDone(item))
                                    }
                                }
                                .listRowBackground(AppColors.appSurface)
                                .listRowInsets(EdgeInsets(
                                    top: 0,
                                    leading: AppSpacing.lg,
                                    bottom: 0,
                                    trailing: AppSpacing.lg
                                ))
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    if collaborationStore.canEdit {
                                        Button(role: .destructive) {
                                            Task { await deleteChecklistItem(item.id) }
                                        } label: {
                                            Label(String(localized: "Delete"), systemImage: "trash")
                                        }
                                        .accessibilityLabel(String(localized: "Delete"))
                                    }
                                }
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                } else {
                    Text("This checklist tab is not available yet.")
                        .font(.appBody)
                        .foregroundStyle(AppColors.textSecondary)
                        .padding(AppSpacing.xl)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AppColors.appBackground)
        .navigationTitle("Checklists")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if canAddChecklistItem {
                    Button {
                        HapticManager.light()
                        newItemTitle = ""
                        showAddItemAlert = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .accessibilityLabel(String(localized: "Add new item"))
                }
            }
        }
        .alert(String(localized: "Add new item"), isPresented: $showAddItemAlert) {
            TextField(String(localized: "Title"), text: $newItemTitle)
            Button(String(localized: "Add")) {
                Task { await addChecklistItemFromAlert() }
            }
            .disabled(newItemTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(String(localized: "Cancel"), role: .cancel) {}
        }
        .task {
            await load()
        }
    }

    private func isDone(_ item: TripChecklistItem) -> Bool {
        rows.flatMap(\.items).first(where: { $0.id == item.id })?.isDone ?? item.isDone
    }

    @MainActor
    private func setDone(itemId: UUID, isDone: Bool) async {
        await dataService.setChecklistItemDone(itemId: itemId, isDone: isDone)
        for ri in rows.indices {
            if let ii = rows[ri].items.firstIndex(where: { $0.id == itemId }) {
                rows[ri].items[ii].isDone = isDone
            }
        }
    }

    @MainActor
    private func load() async {
        isLoading = true
        defer { isLoading = false }
        rows = await dataService.listTemplateTripChecklistsWithItems(tripId: trip.id)
        if let firstKey = rows.compactMap(\.templateKey).first,
           let key = TripChecklistTemplateKey(rawValue: firstKey),
           !rows.contains(where: { $0.templateKey == selectedTab.rawValue }) {
            selectedTab = key
        }
    }

    @MainActor
    private func deleteChecklistItem(_ itemId: UUID) async {
        guard collaborationStore.canEdit else { return }
        await dataService.deleteChecklistItem(itemId: itemId)
        for ri in rows.indices {
            rows[ri].items.removeAll { $0.id == itemId }
        }
        HapticManager.light()
    }

    @MainActor
    private func addChecklistItemFromAlert() async {
        let trimmed = newItemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let list = activeList, !trimmed.isEmpty else { return }
        let nextOrder = (list.items.map(\.sortOrder).max() ?? -1) + 1
        guard let created = await dataService.addChecklistItem(
            checklistId: list.id,
            tripId: trip.id,
            title: trimmed,
            sortOrder: nextOrder
        ) else { return }
        if let ri = rows.firstIndex(where: { $0.id == list.id }) {
            rows[ri].items.append(created)
        }
        newItemTitle = ""
        showAddItemAlert = false
    }
}

private struct ChecklistItemRow: View {
    let title: String
    let isDone: Bool
    /// When true, VoiceOver hints that a trailing swipe exposes delete (matches `swipeActions` on the row).
    var canDelete: Bool = false
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(isDone ? AppColors.appPrimary : AppColors.textTertiary)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)

                Text(title)
                    .font(.appBody)
                    .foregroundStyle(isDone ? AppColors.textTertiary : AppColors.textPrimary)
                    .strikethrough(isDone, color: AppColors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(ChecklistRowButtonStyle())
        .accessibilityLabel(title)
        .accessibilityValue(isDone ? "Completed" : "Not completed")
        .accessibilityHint(accessibilityHintText)
    }

    private var accessibilityHintText: String {
        let toggle = "Double-tap to mark \(isDone ? "incomplete" : "complete")."
        guard canDelete else { return toggle }
        return "\(toggle) Swipe left to delete."
    }
}

private struct ChecklistRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(AppSpring.snappy, value: configuration.isPressed)
    }
}


// =============================================================================

