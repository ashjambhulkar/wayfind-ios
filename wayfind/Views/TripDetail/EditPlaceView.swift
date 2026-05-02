import SwiftUI

struct EditPlaceView: View {
    let place: Place
    var onSave: ((Place) -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var selectedCategory: PlaceCategory
    @State private var notes: String
    @State private var showTimeFields: Bool
    @State private var startTime: Date
    @State private var endTime: Date

    init(place: Place, onSave: ((Place) -> Void)? = nil) {
        self.place = place
        self.onSave = onSave
        _selectedCategory = State(initialValue: place.categoryEnum)
        _notes = State(initialValue: place.notes ?? "")
        _showTimeFields = State(initialValue: place.startTime != nil)
        _startTime = State(initialValue: place.startTime ?? Date())
        _endTime = State(initialValue: place.endTime ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(place.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityHint(String(localized: "The activity title can’t be edited."))
                } header: {
                    Text(String(localized: "Activity"))
                        .textCase(nil)
                } footer: {
                    Text(String(localized: "The activity title can’t be edited."))
                        .font(.footnote)
                }

                Section {
                    Picker(String(localized: "Category"), selection: $selectedCategory) {
                        ForEach(PlaceCategory.allCases, id: \.self) { category in
                            Text(category.label).tag(category)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section {
                    TextField(
                        String(localized: "Add notes"),
                        text: $notes,
                        axis: .vertical
                    )
                    .lineLimit(3...10)
                } header: {
                    Text(String(localized: "Notes"))
                        .textCase(nil)
                }

                Section {
                    if showTimeFields {
                        DatePicker(
                            String(localized: "Start"),
                            selection: $startTime,
                            displayedComponents: .hourAndMinute
                        )
                        DatePicker(
                            String(localized: "End"),
                            selection: $endTime,
                            displayedComponents: .hourAndMinute
                        )
                        Button(String(localized: "Remove Time"), role: .destructive) {
                            withAnimation(AppSpring.smooth) {
                                showTimeFields = false
                            }
                        }
                    } else {
                        Button {
                            withAnimation(AppSpring.smooth) {
                                showTimeFields = true
                            }
                        } label: {
                            Label(String(localized: "Add times"), systemImage: "clock")
                        }
                    }
                } header: {
                    Text(String(localized: "Schedule"))
                        .textCase(nil)
                } footer: {
                    if showTimeFields {
                        Text(String(localized: "Shown on your itinerary timeline."))
                            .font(.footnote)
                    }
                }
            }
            .tint(AppColors.appPrimary)
            .navigationTitle(String(localized: "Edit activity"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Close")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) {
                        save()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func save() {
        var updated = place
        updated.category = selectedCategory.rawValue
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
        if showTimeFields {
            updated.startTime = startTime
            updated.endTime = endTime
        } else {
            updated.startTime = nil
            updated.endTime = nil
        }
        onSave?(updated)
        dismiss()
    }
}

#if DEBUG
#Preview("Edit activity") {
    EditPlaceView(place: .previewAttraction) { _ in }
}
#endif

// =============================================================================
