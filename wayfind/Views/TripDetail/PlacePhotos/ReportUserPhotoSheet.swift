//
//  ReportUserPhotoSheet.swift
//  wayfind
//
//  Phase F.8 — Long-press a photo in the place carousel → report sheet.
//
//  Mirrors the Airbnb-style 4-option report dialog. We deliberately
//  keep the option set short so users don't get decision paralysis;
//  free-text "Tell us more" goes to a moderator alongside the
//  category. Three distinct reporters flip the photo back to
//  `pending_review` (logic lives in the `report_user_photo` RPC).
//

import SwiftUI

struct ReportUserPhotoSheet: View {
    let photoId: UUID
    var onSubmitted: (Bool) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(DataService.self) private var dataService

    @State private var selectedReason: ReportReason?
    @State private var details: String = ""
    @State private var isSubmitting: Bool = false
    @State private var inlineError: String?
    @State private var didSubmit: Bool = false
    @State private var didEscalate: Bool = false

    private let detailsLimit = 280

    enum ReportReason: String, CaseIterable, Identifiable {
        case inappropriate
        case misleading
        case spamOrAd = "spam_or_ad"
        case other

        var id: String { rawValue }

        var label: String {
            switch self {
            case .inappropriate: return "Inappropriate"
            case .misleading: return "Doesn't show this place"
            case .spamOrAd: return "Spam or advertising"
            case .other: return "Something else"
            }
        }

        var subtitle: String {
            switch self {
            case .inappropriate: return "Nudity, violence, hate speech, or other policy violations."
            case .misleading: return "The photo isn't of this place or is misleading."
            case .spamOrAd: return "Logo, watermark, QR code, or other promo content."
            case .other: return "Tell us what's wrong below."
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if didSubmit {
                    successBlock
                } else {
                    formBody
                }
            }
            .navigationTitle("Report photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                if !didSubmit {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: submit) {
                            if isSubmitting {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Send")
                                    .fontWeight(.semibold)
                            }
                        }
                        .disabled(selectedReason == nil || isSubmitting)
                    }
                }
            }
        }
    }

    // MARK: – Form

    private var formBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Why are you reporting this photo?")
                    .font(.system(size: 16, weight: .semibold))
                ForEach(ReportReason.allCases) { reason in
                    reasonRow(reason)
                }
                Divider().padding(.top, 8)
                Text("Add details (optional)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppColors.textSecondary)
                TextEditor(text: $details)
                    .frame(minHeight: 100)
                    .padding(8)
                    .background(AppColors.appSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                            .stroke(AppColors.appDivider, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
                    .onChange(of: details) { _, newValue in
                        if newValue.count > detailsLimit {
                            details = String(newValue.prefix(detailsLimit))
                        }
                    }
                    .accessibilityLabel(Text("Additional details"))
                    .accessibilityHint(Text("Optional. Describe what's wrong with this photo. Up to \(detailsLimit) characters."))
                HStack {
                    Spacer()
                    Text("\(details.count) / \(detailsLimit)")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColors.textTertiary)
                        .monospacedDigit()
                }
                if let inlineError {
                    Text(inlineError)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppColors.appError)
                }
                Text("Reports go to our moderation team. Our policies and the EU DSA prohibit malicious or repeated bad-faith reports.")
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.textTertiary)
                    .padding(.top, 6)
            }
            .padding(16)
        }
    }

    private func reasonRow(_ reason: ReportReason) -> some View {
        let isSelected = selectedReason == reason
        return Button {
            HapticManager.selection()
            selectedReason = reason
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? AppColors.appPrimary : AppColors.appDivider)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(reason.label)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                    Text(reason.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(AppColors.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
            }
            .padding(12)
            .background(isSelected ? AppColors.appPrimaryLight.opacity(0.7) : AppColors.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                    .stroke(isSelected ? AppColors.appPrimary.opacity(0.4) : AppColors.appDivider, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        // Phase G.4 — combined a11y label so VoiceOver announces
        // "<reason>. <subtitle>. Selected." in one pass instead of
        // walking each child element.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(reason.label). \(reason.subtitle)"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var successBlock: some View {
        VStack(spacing: 14) {
            Image(systemName: didEscalate ? "checkmark.shield.fill" : "checkmark.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(didEscalate ? AppColors.appWarning : AppColors.appSuccess)
                .accessibilityHidden(true)
            Text("Thanks for letting us know")
                .font(.system(size: 20, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text(didEscalate
                 ? "Your report — combined with others — sent this photo back to moderation."
                 : "We'll take a look. Your report stays anonymous to the uploader.")
                .font(.system(size: 14))
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.appPrimary)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 32)
    }

    // MARK: – Submit

    private func submit() {
        guard let reason = selectedReason, !isSubmitting else { return }
        isSubmitting = true
        inlineError = nil
        Task {
            let result = await dataService.reportUserPhoto(
                photoId: photoId,
                reason: reason.rawValue,
                details: details.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            isSubmitting = false
            switch result {
            case .success(let escalated):
                didEscalate = escalated
                didSubmit = true
                onSubmitted(escalated)
                HapticManager.success()
            case .failure(let message):
                inlineError = message
                HapticManager.error()
            }
        }
    }
}
