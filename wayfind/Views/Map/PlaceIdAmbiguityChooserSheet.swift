//
//  PlaceIdAmbiguityChooserSheet.swift
//  wayfind
//
//  Phase C.3 — Half-sheet shown when `PlaceIdBridgeService.resolve` returns
//  `.ambiguous`. The bridge gave us up to 3 plausible candidates that all
//  fit the Apple search hit (similar coords + similar name); we ask the user
//  to pick one before committing the row to `city_places`.
//
//  Mirrors the Airbnb 4-option report sheet visual language used elsewhere in
//  the app for consistency: medium detent, drag indicator, capsule-style
//  rows. Tapping a row dismisses immediately and forwards the chosen
//  candidate to the caller.
//

import SwiftUI

struct PlaceIdAmbiguityChooserSheet: View {
    let queryName: String
    let candidates: [PlaceIdBridgeService.Candidate]
    var onSelect: (PlaceIdBridgeService.Candidate) -> Void
    var onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("Which one?")
                    .font(.sectionHeader)
                    .foregroundStyle(AppColors.textPrimary)
                Text("We found a few matches for \"\(queryName)\". Pick the right one so we can save it correctly.")
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textSecondary)
            }

            VStack(spacing: AppSpacing.sm) {
                ForEach(candidates) { candidate in
                    candidateRow(candidate)
                }
            }

            Button {
                onCancel()
                dismiss()
            } label: {
                Text("None of these")
                    .font(.appBody)
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.md)
            }
            .accessibilityLabel("None of these match")
        }
        .padding(.top, AppSpacing.xl)
        .padding(.horizontal, AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.appBackground)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func candidateRow(_ c: PlaceIdBridgeService.Candidate) -> some View {
        Button {
            onSelect(c)
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: AppSpacing.md) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.title3)
                    .foregroundStyle(AppColors.appAccent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text(c.name)
                        .font(.cardTitle)
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: AppSpacing.xs) {
                        Text(c.source.displayLabel)
                            .font(.appSmall)
                            .foregroundStyle(AppColors.textSecondary)
                        Text("·")
                            .font(.appSmall)
                            .foregroundStyle(AppColors.textSecondary)
                        Text("\(Int((c.confidence * 100).rounded()))% match")
                            .font(.appSmall)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(AppColors.textTertiary)
            }
            .padding(AppSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                    .fill(AppColors.appSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                    .stroke(AppColors.appDivider, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(c.name), \(Int((c.confidence * 100).rounded())) percent match")
        .accessibilityAddTraits(.isButton)
    }
}

// =============================================================================

#if DEBUG
#Preview("Ambiguity chooser — 3 candidates") {
    let candidates = [
        PlaceIdBridgeService.Candidate(
            placeId: "ChIJD7fiBh9u5kcRYJSMaMOCCwQ",
            name: "Louvre Museum",
            lat: 48.8606,
            lng: 2.3376,
            confidence: 0.92,
            source: .cityPlaces
        ),
        PlaceIdBridgeService.Candidate(
            placeId: "ChIJBbMjYSJu5kcR0G2LCqA6Jac",
            name: "Louvre Palace (Historic)",
            lat: 48.8604,
            lng: 2.3374,
            confidence: 0.74,
            source: .bridge
        ),
        PlaceIdBridgeService.Candidate(
            placeId: "ChIJXxxFakeId123",
            name: "Louvre Hotel",
            lat: 48.8598,
            lng: 2.3380,
            confidence: 0.61,
            source: .googleTextSearch
        ),
    ]
    PlaceIdAmbiguityChooserSheet(
        queryName: "Louvre",
        candidates: candidates,
        onSelect: { _ in },
        onCancel: {}
    )
}

#Preview("Ambiguity chooser — 2 candidates") {
    let candidates = [
        PlaceIdBridgeService.Candidate(
            placeId: "ChIJVVVVV1234",
            name: "Sacré-Cœur Basilica",
            lat: 48.8867,
            lng: 2.3431,
            confidence: 0.88,
            source: .bridge
        ),
        PlaceIdBridgeService.Candidate(
            placeId: "ChIJAAAAA5678",
            name: "Sacré-Cœur (Montmartre Summit)",
            lat: 48.8869,
            lng: 2.3433,
            confidence: 0.71,
            source: .googleTextSearch
        ),
    ]
    PlaceIdAmbiguityChooserSheet(
        queryName: "Sacré-Cœur",
        candidates: candidates,
        onSelect: { _ in },
        onCancel: {}
    )
}
#endif
