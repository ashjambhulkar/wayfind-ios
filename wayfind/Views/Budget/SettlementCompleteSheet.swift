//
//  SettlementCompleteSheet.swift
//  wayfind
//
//  Phase 6 (PR-4) — confirmation sheet for one settlement. The user picks a
//  payment method (Cash / Venmo / PayPal / Other), optionally launches the
//  matching app via deep link, and presses "Mark settled" to write the
//  ledger row through `BudgetViewModel.addSettlement(_:)`.
//
//  Notes that informed the design:
//   • Apple Pay Cash is intentionally absent — Apple does not publish a
//     P2P URL scheme, so we cannot open the right surface from a deep link
//     even though many travellers settle that way. "Other" covers it.
//   • Deep links use `UIApplication.canOpenURL` to gate the launch button:
//     if Venmo isn't installed we fall back to the Universal Link
//     `https://venmo.com/...`. Same idea for PayPal.me.
//   • We construct the URL up-front and keep the user's amount in the URL
//     so they don't have to retype it inside the third-party app — this
//     matches the Splitwise / Venmo behaviour iOS users expect.
//

import SwiftUI
import UIKit

struct SettlementCompleteSheet: View {
    @Environment(\.dismiss) private var dismiss

    let suggestion: SettlementSuggestion
    let recipient: TripCollaborator?
    let payer: TripCollaborator?
    let viewModel: BudgetViewModel

    @State private var selectedMethod: ExpenseSettlement.SettlementMethod = .cash
    @State private var notes: String = ""
    @State private var isSubmitting = false
    @State private var submitError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    headerCard
                    methodSection
                    if let deepLink = currentDeepLink {
                        deepLinkButton(for: deepLink)
                    }
                    notesSection
                    if let submitError {
                        Text(submitError)
                            .font(.appCaption)
                            .foregroundStyle(AppColors.appError)
                    }
                }
                .padding(AppSpacing.lg)
            }
            .background(AppColors.appBackground)
            .navigationTitle("Settle up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Mark settled") {
                        Task { await submit() }
                    }
                    .fontWeight(.semibold)
                    .disabled(isSubmitting)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(headlineCopy)
                .font(.appBody.weight(.semibold))
                .foregroundStyle(AppColors.textPrimary)
            Text(MoneyFormatter.string(suggestion.amount, currency: suggestion.currency))
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .foregroundStyle(AppColors.textPrimary)
                .monospacedDigit()
            Text(subtitleCopy)
                .font(.appCaption)
                .foregroundStyle(AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.md)
        .background(AppColors.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .stroke(AppColors.appDivider, lineWidth: 1)
        )
    }

    private var headlineCopy: String {
        let payerName = payer?.resolvedDisplayName ?? "You"
        let recipientName = recipient?.resolvedDisplayName ?? "Someone"
        if suggestion.fromUserId == viewModel.currentUserId {
            return "Pay \(recipientName)"
        }
        return "\(payerName) is paying you"
    }

    private var subtitleCopy: String {
        suggestion.fromUserId == viewModel.currentUserId
            ? "Choose how you sent the money."
            : "Confirm the method they used."
    }

    // MARK: - Method picker

    private var methodSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Method")
                .font(.appCaption.weight(.semibold))
                .foregroundStyle(AppColors.textSecondary)
                .textCase(.uppercase)

            VStack(spacing: 0) {
                ForEach(ExpenseSettlement.SettlementMethod.allCases, id: \.self) { method in
                    Button {
                        selectedMethod = method
                        HapticManager.selection()
                    } label: {
                        HStack(spacing: AppSpacing.md) {
                            Image(systemName: method.systemImage)
                                .font(.body)
                                .foregroundStyle(method == selectedMethod ? AppColors.appPrimary : AppColors.textSecondary)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(method.displayLabel)
                                    .font(.appBody)
                                    .foregroundStyle(AppColors.textPrimary)
                                if let hint = methodCaption(for: method) {
                                    Text(hint)
                                        .font(.appCaption)
                                        .foregroundStyle(AppColors.textTertiary)
                                }
                            }
                            Spacer()
                            if selectedMethod == method {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(AppColors.appPrimary)
                            }
                        }
                        .padding(.horizontal, AppSpacing.md)
                        .padding(.vertical, AppSpacing.sm)
                    }
                    .buttonStyle(.plain)
                    if method != ExpenseSettlement.SettlementMethod.allCases.last {
                        Divider().padding(.leading, AppSpacing.lg + 28)
                    }
                }
            }
            .background(AppColors.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                    .stroke(AppColors.appDivider, lineWidth: 1)
            )
        }
    }

    private func methodCaption(for method: ExpenseSettlement.SettlementMethod) -> String? {
        switch method {
        case .venmo:
            return recipient?.venmoUsername.flatMap { "@\($0)" }
                ?? "Recipient hasn't added a Venmo handle"
        case .paypal:
            return recipient?.paypalUsername.flatMap { "paypal.me/\($0)" }
                ?? "Recipient hasn't added a PayPal handle"
        case .cash:
            return "In person, no link"
        case .other:
            return "Cash App, Zelle, Wise, Apple Pay…"
        }
    }

    // MARK: - Deep link

    private var currentDeepLink: SettlementDeepLink? {
        guard suggestion.fromUserId == viewModel.currentUserId else {
            // Only the payer needs the launcher — recipients are confirming
            // money already received.
            return nil
        }
        switch selectedMethod {
        case .venmo:
            guard let handle = recipient?.venmoUsername, !handle.isEmpty else { return nil }
            return SettlementDeepLink.venmo(handle: handle, amount: suggestion.amount, note: noteForLink)
        case .paypal:
            guard let handle = recipient?.paypalUsername, !handle.isEmpty else { return nil }
            return SettlementDeepLink.paypal(handle: handle, amount: suggestion.amount, currency: suggestion.currency)
        case .cash, .other:
            return nil
        }
    }

    @ViewBuilder
    private func deepLinkButton(for link: SettlementDeepLink) -> some View {
        Button {
            link.open()
        } label: {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: link.systemImage)
                Text(link.title)
                    .font(.appButton)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
        }
        .buttonStyle(.bordered)
        .tint(AppColors.appPrimary)
    }

    private var noteForLink: String {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return "Wayfind trip"
    }

    // MARK: - Notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Notes (optional)")
                .font(.appCaption.weight(.semibold))
                .foregroundStyle(AppColors.textSecondary)
                .textCase(.uppercase)
            TextField("e.g. dinner Sunday", text: $notes, axis: .vertical)
                .font(.appBody)
                .lineLimit(2...4)
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, AppSpacing.sm)
                .frame(minHeight: 56, alignment: .topLeading)
                .background(AppColors.appSurface)
                .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                        .stroke(AppColors.appDivider, lineWidth: 1)
                )
        }
    }

    // MARK: - Submit

    @MainActor
    private func submit() async {
        isSubmitting = true
        submitError = nil
        defer { isSubmitting = false }

        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let settlement = ExpenseSettlement(
            id: UUID(),
            tripId: viewModel.tripId,
            fromUserId: suggestion.fromUserId,
            toUserId: suggestion.toUserId,
            amount: suggestion.amount,
            currencyCode: suggestion.currency,
            isSettled: true,
            settledAt: Date(),
            settledVia: selectedMethod,
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
            createdAt: Date(),
            updatedAt: Date()
        )

        let success = await viewModel.addSettlement(settlement)
        if success {
            HapticManager.success()
            dismiss()
        } else {
            submitError = "Couldn't record the payment. Try again."
        }
    }
}

// MARK: - Deep links

/// Encapsulates everything we need to launch a settlement deep link plus a
/// sensible fallback when the third-party app isn't installed. The Decimal
/// formatting strips fractional zeros so "12.00" becomes "12" — the app
/// stores will accept either, but the cleaner value is friendlier in the
/// pre-fill field.
enum SettlementDeepLink {
    case venmo(handle: String, amount: Decimal, note: String)
    case paypal(handle: String, amount: Decimal, currency: String)

    var title: String {
        switch self {
        case .venmo: return "Open Venmo to pay"
        case .paypal: return "Open PayPal.me"
        }
    }

    var systemImage: String {
        switch self {
        case .venmo: return "v.circle.fill"
        case .paypal: return "p.circle.fill"
        }
    }

    /// First tries the native scheme (`venmo://...`) so installed users go
    /// straight into the app with the form pre-filled, then falls back to
    /// the Universal Link so the App Store / web flow still works.
    func open() {
        for url in candidateURLs() {
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
                return
            }
        }
        if let last = candidateURLs().last {
            UIApplication.shared.open(last)
        }
    }

    private func candidateURLs() -> [URL] {
        switch self {
        case .venmo(let handle, let amount, let note):
            let amountString = Self.formatAmount(amount)
            let noteEncoded = note.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? note
            let cleanedHandle = handle.replacingOccurrences(of: "@", with: "")
            var urls: [URL] = []
            if let scheme = URL(string: "venmo://paycharge?txn=pay&recipients=\(cleanedHandle)&amount=\(amountString)&note=\(noteEncoded)") {
                urls.append(scheme)
            }
            if let universal = URL(string: "https://venmo.com/\(cleanedHandle)") {
                urls.append(universal)
            }
            return urls

        case .paypal(let handle, let amount, let currency):
            let amountString = Self.formatAmount(amount)
            let cleanedHandle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
            // paypal.me wants the format `paypal.me/<handle>/<amount><currency>`.
            // Lowercase currency code is what their site renders consistently.
            let currencyCode = currency.uppercased()
            var urls: [URL] = []
            if let universal = URL(string: "https://paypal.me/\(cleanedHandle)/\(amountString)\(currencyCode)") {
                urls.append(universal)
            }
            return urls
        }
    }

    private static func formatAmount(_ amount: Decimal) -> String {
        var value = amount
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 2, .plain)
        let nsNumber = NSDecimalNumber(decimal: rounded)
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        formatter.usesGroupingSeparator = false
        return formatter.string(from: nsNumber) ?? "\(rounded)"
    }
}


// =============================================================================
