import SwiftUI

struct TripChecklistsView: View {
    let trip: Trip

    @Environment(DataService.self) private var dataService
    @State private var rows: [TripChecklistWithItems] = []
    @State private var selectedTab: TripChecklistTemplateKey = .packing
    @State private var isLoading = true

    private var activeList: TripChecklistWithItems? {
        rows.first { $0.templateKey == selectedTab.rawValue }
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
                            subtitle: "Add checklist items from Wayfind on the web; they sync here.",
                            buttonTitle: nil,
                            buttonAction: nil
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List {
                            ForEach(list.items) { item in
                                ChecklistItemRow(
                                    title: item.title,
                                    isDone: isDone(item)
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
}

private struct ChecklistItemRow: View {
    let title: String
    let isDone: Bool
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
        .accessibilityHint("Double-tap to mark \(isDone ? "incomplete" : "complete").")
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

