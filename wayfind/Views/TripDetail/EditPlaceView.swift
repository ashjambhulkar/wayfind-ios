import SwiftUI

struct EditPlaceView: View {
    let place: Place
    var onSave: ((Place) -> Void)?

    @Environment(\.dismiss) var dismiss

    @State private var name: String
    @State private var address: String
    @State private var selectedCategory: PlaceCategory
    @State private var notes: String
    @State private var showTimeFields: Bool
    @State private var startTime: Date
    @State private var endTime: Date

    init(place: Place, onSave: ((Place) -> Void)? = nil) {
        self.place = place
        self.onSave = onSave
        _name = State(initialValue: place.name)
        _address = State(initialValue: place.address ?? "")
        _selectedCategory = State(initialValue: place.categoryEnum)
        _notes = State(initialValue: place.notes ?? "")
        _showTimeFields = State(initialValue: place.startTime != nil)
        _startTime = State(initialValue: place.startTime ?? Date())
        _endTime = State(initialValue: place.endTime ?? Date())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                Text("Edit Place")
                    .font(.sectionHeader)
                    .foregroundStyle(AppColors.textPrimary)

                FormField(label: "Name", placeholder: "Place name", text: $name)
                FormField(label: "Address", placeholder: "Address or location", text: $address)

                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text("Category")
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textSecondary)
                    Picker("Category", selection: $selectedCategory) {
                        ForEach(PlaceCategory.allCases, id: \.self) { category in
                            Text(category.label).tag(category)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(AppColors.appPrimary)
                }

                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text("Notes")
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textSecondary)
                    TextEditor(text: $notes)
                        .font(.appBody)
                        .scrollContentBackground(.hidden)
                        .frame(height: 80)
                        .padding(.horizontal, AppSpacing.sm)
                        .padding(.vertical, AppSpacing.xs)
                        .background(AppColors.appSurface)
                        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                                .strokeBorder(AppColors.appDivider, lineWidth: 1)
                        )
                }

                if !showTimeFields {
                    AppButton(title: "Add Time", style: .outline, action: {
                        withAnimation(AppSpring.smooth) {
                            showTimeFields = true
                        }
                    })
                } else {
                    VStack(alignment: .leading, spacing: AppSpacing.md) {
                        compactTimeRow(title: "Start Time", selection: $startTime)
                        compactTimeRow(title: "End Time", selection: $endTime)
                        Button {
                            withAnimation(AppSpring.smooth) {
                                showTimeFields = false
                            }
                        } label: {
                            Text("Remove Time")
                                .font(.appButton)
                                .foregroundStyle(AppColors.appError)
                                .padding(.horizontal, AppSpacing.sm)
                                .padding(.vertical, AppSpacing.xs)
                        }
                        .buttonStyle(.plain)
                    }
                }

                AppButton(title: "Save Changes", style: .primary, action: save)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, AppSpacing.xl)
            .padding(.horizontal, AppSpacing.lg)
            .padding(.bottom, AppSpacing.xxl)
        }
        .background(AppColors.appBackground)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func compactTimeRow(title: String, selection: Binding<Date>) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            FormSectionTitle(title)
            DatePicker(title, selection: selection, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .datePickerStyle(.compact)
                .tint(AppColors.appPrimary)
                .padding(.horizontal, AppSpacing.md)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .background(AppColors.appSurface)
                .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                        .strokeBorder(AppColors.appDivider, lineWidth: 1)
                )
        }
    }

    private func save() {
        var updated = place
        updated.name = name
        updated.address = address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : address
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

