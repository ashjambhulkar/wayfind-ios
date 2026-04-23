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
                                Toggle(isOn: binding(for: item)) {
                                    Text(item.title)
                                        .font(.appBody)
                                        .foregroundStyle(AppColors.textPrimary)
                                        .strikethrough(item.isDone)
                                }
                                .tint(AppColors.appPrimary)
                                .listRowBackground(AppColors.appSurface)
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
        .task {
            await load()
        }
    }

    private func binding(for item: TripChecklistItem) -> Binding<Bool> {
        Binding(
            get: {
                rows.flatMap(\.items).first(where: { $0.id == item.id })?.isDone ?? item.isDone
            },
            set: { newValue in
                Task {
                    await setDone(itemId: item.id, isDone: newValue)
                }
            }
        )
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

