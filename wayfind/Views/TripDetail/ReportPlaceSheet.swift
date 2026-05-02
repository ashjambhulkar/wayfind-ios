import SwiftUI

/// Half-sheet for reporting a place issue (closed, incorrect, etc.).
struct ReportPlaceSheet: View {
    @Environment(\.dismiss) private var dismiss

    enum Reason: String, CaseIterable, Identifiable {
        case closed = "closed"
        case incorrect = "incorrect"
        case inappropriate = "inappropriate"
        case other = "other"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .closed: String(localized: "Place is closed or doesn't exist")
            case .incorrect: String(localized: "Information is incorrect")
            case .inappropriate: String(localized: "Inappropriate or offensive")
            case .other: String(localized: "Something else")
            }
        }

        var icon: String {
            switch self {
            case .closed: "xmark.circle"
            case .incorrect: "exclamationmark.triangle"
            case .inappropriate: "hand.raised"
            case .other: "ellipsis.circle"
            }
        }

        var accessibilityHint: String {
            switch self {
            case .closed:
                String(localized: "Report that this place is closed or missing.")
            case .incorrect:
                String(localized: "Report wrong hours, address, or other details.")
            case .inappropriate:
                String(localized: "Report offensive or unsafe content.")
            case .other:
                String(localized: "Report a different issue.")
            }
        }
    }

    let placeName: String
    let googlePlaceId: String
    let onSubmit: (Reason) -> Void

    @State private var selectedReason: Reason?
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(alignment: .top, spacing: AppSpacing.md) {
                        Image(systemName: "flag.fill")
                            .font(.title3)
                            .foregroundStyle(AppColors.appPrimary)
                            .symbolRenderingMode(.hierarchical)
                            .accessibilityHidden(true)
                            .frame(width: 28, alignment: .center)

                        VStack(alignment: .leading, spacing: AppSpacing.xs) {
                            Text(String(localized: "Tell us what’s wrong"))
                                .font(.appBody.weight(.semibold))
                                .foregroundStyle(AppColors.textPrimary)

                            Text(String(localized: "What's wrong with \"\(placeName)\"?"))
                                .font(.appCaption)
                                .foregroundStyle(AppColors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Section {
                    ForEach(Reason.allCases) { reason in
                        reasonRow(reason)
                    }
                } header: {
                    Text(String(localized: "Issue"))
                        .textCase(nil)
                } footer: {
                    Text(String(localized: "Reports are reviewed to keep listings accurate. This won’t share your name with the place."))
                        .font(.footnote)
                }
            }
            .navigationTitle(String(localized: "Report a problem"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) {
                        dismiss()
                    }
                    .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSubmitting {
                        ProgressView()
                            .controlSize(.regular)
                    } else {
                        Button(String(localized: "Submit")) {
                            submitSelected()
                        }
                        .fontWeight(.semibold)
                        .disabled(selectedReason == nil)
                    }
                }
            }
        }
        .tint(AppColors.appPrimary)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func reasonRow(_ reason: Reason) -> some View {
        let isSelected = selectedReason == reason

        return Button {
            withAnimation(AppSpring.smooth) {
                selectedReason = reason
            }
        } label: {
            HStack(alignment: .center, spacing: AppSpacing.md) {
                Image(systemName: reason.icon)
                    .font(.body)
                    .foregroundStyle(isSelected ? AppColors.appPrimary : AppColors.textSecondary)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 28, alignment: .center)
                    .accessibilityHidden(true)

                Text(reason.title)
                    .font(.appBody)
                    .foregroundStyle(AppColors.textPrimary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AppColors.appPrimary)
                        .accessibilityLabel(String(localized: "Selected"))
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, AppSpacing.xs)
        }
        .buttonStyle(.plain)
        .accessibilityHint(reason.accessibilityHint)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func submitSelected() {
        guard let reason = selectedReason, !isSubmitting else { return }
        isSubmitting = true

        onSubmit(reason)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            dismiss()
        }
    }
}

#if DEBUG
private struct ReportPlaceSheetSheetPreviewHost: View {
    @State private var showSheet = true

    var body: some View {
        Color.clear
            .sheet(isPresented: $showSheet) {
                ReportPlaceSheet(
                    placeName: "Museum of Modern Art",
                    googlePlaceId: "ChIJpreview",
                    onSubmit: { _ in }
                )
            }
    }
}

#Preview("Report place") {
    ReportPlaceSheet(
        placeName: "Café Example",
        googlePlaceId: "ChIJpreview",
        onSubmit: { _ in }
    )
}

#Preview("Report place — sheet") {
    ReportPlaceSheetSheetPreviewHost()
}
#endif
