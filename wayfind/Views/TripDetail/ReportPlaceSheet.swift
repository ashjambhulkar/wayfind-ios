//
//  ReportPlaceSheet.swift
//  wayfind
//
//  Phase E.3 — Airbnb-style 4-option report half-sheet for `city_places`.
//
//  Triggered from `PlaceDetailSheet` ("Report this place" overflow item).
//  Always returns immediately on tap with a thank-you toast — we never block
//  on the network because the report RPC is fire-and-forget anyway (3
//  distinct reporters trip the threshold, not one).
//

import SwiftUI

struct ReportPlaceSheet: View {
    let placeName: String
    let googlePlaceId: String

    /// Called after the user makes a selection. The handler is responsible
    /// for showing the thank-you toast in the parent context.
    var onSubmit: (Reason) -> Void

    @Environment(\.dismiss) private var dismiss

    enum Reason: String, CaseIterable, Identifiable {
        case closed = "closed"
        case incorrect = "incorrect"
        case inappropriate = "inappropriate"
        case other = "other"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .closed: return "It's permanently closed"
            case .incorrect: return "Information is wrong"
            case .inappropriate: return "It's inappropriate or unsafe"
            case .other: return "Something else"
            }
        }

        var subtitle: String {
            switch self {
            case .closed: return "Out of business or no longer operating"
            case .incorrect: return "Wrong address, hours, photos, or details"
            case .inappropriate: return "Hate, harassment, scam, or unsafe content"
            case .other: return "Tell us in a follow-up"
            }
        }

        var icon: String {
            switch self {
            case .closed: return "lock.fill"
            case .incorrect: return "exclamationmark.triangle.fill"
            case .inappropriate: return "hand.raised.fill"
            case .other: return "ellipsis.bubble.fill"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("Report a problem")
                    .font(.sectionHeader)
                    .foregroundStyle(AppColors.textPrimary)
                Text("What's wrong with \"\(placeName)\"?")
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textSecondary)
            }

            VStack(spacing: AppSpacing.sm) {
                ForEach(Reason.allCases) { reason in
                    reasonRow(reason)
                }
            }

            Button {
                dismiss()
            } label: {
                Text("Cancel")
                    .font(.appBody)
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.md)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, AppSpacing.xl)
        .padding(.horizontal, AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.appBackground)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func reasonRow(_ reason: Reason) -> some View {
        Button {
            // Submit immediately, dismiss, let the parent show the toast.
            onSubmit(reason)
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: AppSpacing.md) {
                Image(systemName: reason.icon)
                    .font(.title3)
                    .foregroundStyle(AppColors.appPrimary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text(reason.label)
                        .font(.cardTitle)
                        .foregroundStyle(AppColors.textPrimary)
                    Text(reason.subtitle)
                        .font(.appSmall)
                        .foregroundStyle(AppColors.textSecondary)
                        .multilineTextAlignment(.leading)
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
        .accessibilityLabel(reason.label)
        .accessibilityHint(reason.subtitle)
    }
}
