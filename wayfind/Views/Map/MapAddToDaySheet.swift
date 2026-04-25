//
//  MapAddToDaySheet.swift
//  wayfind
//
//  Phase 7 of the Map Screen Search Redesign.
//
//  Half-sheet that slides in over the preview when the user taps
//  "Add to Day". Prefilled with the resolved Apple/DB place — day
//  picker, optional time, optional notes, Save.
//
//  No inline Menu — the plan calls this out explicitly: an inline
//  Menu was too thin for a real add (day, time, notes), so we use a
//  proper sheet.
//

import SwiftUI

struct MapAddToDaySheet: View {
    let preview: MapSearchPreview
    let scheduledDays: [ItineraryDay]

    /// Day prefilled when the user opened the preview. nil = first day.
    let preselectedDayId: UUID?

    /// Save tapped. Caller persists via `dataService.addPlace` and
    /// kicks the bridge if origin is `.apple` AND we don't already
    /// have a `place_id`.
    var onSave: (_ dayId: UUID, _ startTime: Date?, _ notes: String?) -> Void

    var onCancel: () -> Void

    @State private var selectedDayId: UUID?
    @State private var includeTime: Bool = false
    @State private var startTime: Date = Date()
    @State private var notes: String = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    headerRow
                } header: {
                    Text("Place")
                }

                Section {
                    Picker("Day", selection: Binding(
                        get: { selectedDayId ?? scheduledDays.first?.id ?? UUID() },
                        set: { selectedDayId = $0 }
                    )) {
                        ForEach(scheduledDays, id: \.id) { day in
                            Text(dayLabel(day)).tag(day.id)
                        }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("Schedule")
                }

                Section {
                    Toggle(isOn: $includeTime.animation()) {
                        Label("Set start time", systemImage: "clock")
                    }
                    if includeTime {
                        DatePicker(
                            "Start time",
                            selection: $startTime,
                            displayedComponents: .hourAndMinute
                        )
                    }
                }

                Section {
                    TextField(
                        "Notes (optional)",
                        text: $notes,
                        axis: .vertical
                    )
                    .lineLimit(2...4)
                } header: {
                    Text("Notes")
                }
            }
            .navigationTitle("Add to Day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Save").bold()
                        }
                    }
                    .disabled(scheduledDays.isEmpty || isSaving)
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppColors.appBackground)
            .onAppear {
                if selectedDayId == nil {
                    selectedDayId = preselectedDayId ?? scheduledDays.first?.id
                }
            }
        }
        .tint(AppColors.appPrimary)
    }

    private var headerRow: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppColors.appPrimaryLight)
                    .frame(width: 40, height: 40)
                Image(systemName: preview.category?.mapBadgeSymbol ?? "mappin.circle.fill")
                    .foregroundStyle(AppColors.appPrimary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(preview.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                if !preview.subtitle.isEmpty {
                    Text(preview.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func save() {
        guard let dayId = selectedDayId ?? scheduledDays.first?.id else { return }
        isSaving = true
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(dayId, includeTime ? startTime : nil, trimmed.isEmpty ? nil : trimmed)
    }

    private func dayLabel(_ day: ItineraryDay) -> String {
        "Day \(day.dayNumber)"
    }
}

// =============================================================================
