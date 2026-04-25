//
//  PhotoAppealSheet.swift
//  wayfind
//
//  Phase F.7 — DSA-compliant appeal sheet. Surfaced from the rejection
//  detail card on a user-uploaded photo (and from any incoming push
//  notification deep-link in a follow-up). Inserts a row in
//  `dsa_appeals` via the `submit_dsa_appeal` RPC (Article 20 of the
//  EU Digital Services Act — internal complaint mechanism).
//

import SwiftUI

struct PhotoAppealSheet: View {
    let photoId: UUID
    let originalReason: String?
    let originalDetail: String?
    var onSubmitted: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(DataService.self) private var dataService
    @State private var appealText: String = ""
    @State private var isSubmitting: Bool = false
    @State private var inlineError: String?
    @State private var didSubmit: Bool = false

    private let textLimit = 500

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if didSubmit {
                        successBlock
                    } else {
                        intro
                        if let detail = originalDetail, !detail.isEmpty {
                            originalReasonCard(detail: detail)
                        }
                        textEditorBlock
                        if let inlineError {
                            Text(inlineError)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(AppColors.appError)
                        }
                        submitButton
                        rightsFooter
                    }
                }
                .padding(20)
            }
            .navigationTitle("Appeal decision")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(didSubmit ? "Done" : "Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: – Subviews

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tell us why you think this decision was wrong")
                .font(.system(size: 18, weight: .semibold))
            Text("Our team will re-review your photo. You'll get a notification when it's resolved.")
                .font(.system(size: 14))
                .foregroundStyle(AppColors.textSecondary)
        }
    }

    private func originalReasonCard(detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Original reason")
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(AppColors.textTertiary)
            Text(detail)
                .font(.system(size: 14))
                .foregroundStyle(AppColors.textSecondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.appPrimaryLight.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
    }

    private var textEditorBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your explanation (optional but helpful)")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppColors.textSecondary)
            TextEditor(text: $appealText)
                .frame(minHeight: 140)
                .padding(8)
                .background(AppColors.appSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                        .stroke(AppColors.appDivider, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
                .onChange(of: appealText) { _, newValue in
                    if newValue.count > textLimit {
                        appealText = String(newValue.prefix(textLimit))
                    }
                }
            HStack {
                Spacer()
                Text("\(appealText.count) / \(textLimit)")
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.textTertiary)
                    .monospacedDigit()
            }
        }
    }

    private var submitButton: some View {
        Button {
            submit()
        } label: {
            HStack {
                if isSubmitting { ProgressView().controlSize(.small).tint(.white) }
                Text("Submit appeal")
                    .font(.system(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .foregroundStyle(.white)
            .background(AppColors.appPrimary)
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
        }
        .disabled(isSubmitting)
    }

    private var rightsFooter: some View {
        Text("This is your DSA Article 20 internal complaint. If we get it wrong again, you can also escalate to a certified out-of-court dispute settlement body.")
            .font(.system(size: 11))
            .foregroundStyle(AppColors.textTertiary)
    }

    private var successBlock: some View {
        VStack(spacing: 14) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 36))
                .foregroundStyle(AppColors.appPrimary)
            Text("Appeal received")
                .font(.system(size: 20, weight: .semibold))
            Text("We'll review and let you know.")
                .font(.system(size: 14))
                .foregroundStyle(AppColors.textSecondary)
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
        guard !isSubmitting else { return }
        isSubmitting = true
        inlineError = nil
        Task {
            let ok = await dataService.submitDsaAppeal(
                photoId: photoId,
                appealText: appealText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            isSubmitting = false
            if ok {
                didSubmit = true
                onSubmitted()
            } else {
                inlineError = "Couldn't send the appeal. Try again in a moment."
            }
        }
    }
}
