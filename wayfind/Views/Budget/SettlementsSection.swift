//
//  SettlementsSection.swift
//  wayfind
//
//  Phase 6 (PR-4) — settle-up surface for the trip Budget tab. Renders the
//  output of `SettlementSimplifier.simplify(...)` as a stack of cards. Each
//  card shows the two participants (overlapping avatars, payer first), the
//  amount due, and a primary "Settle Up" button. Tapping the button opens
//  `SettlementCompleteSheet` so the user can confirm method (cash / Venmo /
//  PayPal / other) and create the row.
//
//  Recently completed settlements collapse into a compact "Settled · Apr 24
//  via Venmo" row beneath the live suggestions so the user can see what just
//  happened without losing the action surface.
//
//  Visibility rules:
//   • Section is hidden when there are no suggestions and no recent
//     settlements (the parent's `BudgetScope.settleUp` segment is empty in
//     that case too — `TripBudgetTabView` chooses what to show.).
//   • Solo trips never reach this view because `showsScopePicker` hides the
//     "Settle up" segment for trips with ≤ 1 accepted member.
//

import SwiftUI

struct SettlementsSection: View {
    let suggestions: [SettlementSuggestion]
    let recentSettlements: [ExpenseSettlement]
    let members: [TripCollaborator]
    let currentUserId: UUID?
    /// Invoked when the user taps "Settle Up" on a suggestion. The parent
    /// presents `SettlementCompleteSheet` and, on confirm, dispatches the
    /// `addSettlement` mutation through the view-model.
    let onSettle: (SettlementSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                sectionHeader
                Text("Each amount is in one currency — settle in that currency.")
                    .font(.caption2)
                    .foregroundStyle(AppColors.textTertiary)
            }

            if suggestions.isEmpty && recentSettlements.isEmpty {
                emptyState
            } else {
                if !suggestions.isEmpty {
                    VStack(spacing: AppSpacing.sm) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            SettlementSuggestionCard(
                                suggestion: suggestion,
                                fromMember: member(for: suggestion.fromUserId),
                                toMember: member(for: suggestion.toUserId),
                                isCurrentUserPaying: suggestion.fromUserId == currentUserId,
                                onSettle: { onSettle(suggestion) }
                            )
                        }
                    }
                }

                if !recentSettlements.isEmpty {
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text("Recently settled")
                            .font(.appCaption.weight(.semibold))
                            .foregroundStyle(AppColors.textSecondary)
                            .textCase(.uppercase)
                        VStack(spacing: 0) {
                            ForEach(recentSettlements) { settlement in
                                SettledRow(
                                    settlement: settlement,
                                    fromName: memberName(for: settlement.fromUserId),
                                    toName: memberName(for: settlement.toUserId)
                                )
                                if settlement.id != recentSettlements.last?.id {
                                    Divider().padding(.leading, AppSpacing.lg)
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
            }
        }
    }

    private var sectionHeader: some View {
        Text("Settle up")
            .font(.sectionHeader)
            .foregroundStyle(AppColors.textPrimary)
    }

    private var emptyState: some View {
        HStack(spacing: AppSpacing.md) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title3)
                .foregroundStyle(AppColors.appSuccess)
            VStack(alignment: .leading, spacing: 2) {
                Text("Everyone's square")
                    .font(.appBody.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
                Text("No one owes anyone right now.")
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textSecondary)
            }
            Spacer()
        }
        .padding(AppSpacing.md)
        .background(AppColors.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .stroke(AppColors.appDivider, lineWidth: 1)
        )
    }

    private func member(for userId: UUID) -> TripCollaborator? {
        members.first { $0.userId == userId }
    }

    private func memberName(for userId: UUID) -> String {
        if userId == currentUserId { return "You" }
        return member(for: userId)?.resolvedDisplayName ?? "Someone"
    }
}

// MARK: - Suggestion card

struct SettlementSuggestionCard: View {
    let suggestion: SettlementSuggestion
    let fromMember: TripCollaborator?
    let toMember: TripCollaborator?
    /// True when the *current user* is the one who owes — drives the verb
    /// ("Settle up" vs "Mark as paid") and which avatar is in front.
    let isCurrentUserPaying: Bool
    let onSettle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(spacing: AppSpacing.md) {
                avatarPair
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.appBody.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(MoneyFormatter.string(suggestion.amount, currency: suggestion.currency))
                        .font(.appBody.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(amountColor)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(rowAccessibilityLabel)
                Spacer()
            }

            Button(action: onSettle) {
                Text(buttonTitle)
                    .font(.appButton)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppColors.appPrimary)
            .accessibilityHint(accessibilityHint)
        }
        .padding(AppSpacing.md)
        .background(AppColors.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .stroke(AppColors.appDivider, lineWidth: 1)
        )
    }

    /// One-sentence VoiceOver summary that combines the headline + amount so
    /// the user hears the full picture before reaching the action button.
    /// Mirrors the row's visible copy so screen-reader users don't get a
    /// stripped-down version.
    private var rowAccessibilityLabel: String {
        let amount = MoneyFormatter.string(suggestion.amount, currency: suggestion.currency)
        return "\(headline). Amount \(amount)."
    }

    private var avatarPair: some View {
        ZStack {
            // Back avatar (recipient on the right when current user pays;
            // payer on the right when someone owes the current user).
            avatar(for: backMember)
                .frame(width: 36, height: 36)
                .offset(x: 14)
                .overlay(
                    Circle().stroke(AppColors.appSurface, lineWidth: 2).offset(x: 14)
                )
            avatar(for: frontMember)
                .frame(width: 36, height: 36)
                .offset(x: -14)
                .overlay(
                    Circle().stroke(AppColors.appSurface, lineWidth: 2).offset(x: -14)
                )
        }
        .frame(width: 64, height: 36)
    }

    private var frontMember: TripCollaborator? {
        // The "actor" of the row goes in front so the eye lands on whoever
        // pressed the button.
        isCurrentUserPaying ? fromMember : toMember
    }

    private var backMember: TripCollaborator? {
        isCurrentUserPaying ? toMember : fromMember
    }

    @ViewBuilder
    private func avatar(for member: TripCollaborator?) -> some View {
        if let urlString = member?.avatarURLString,
           let url = URL(string: urlString) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                avatarFallback(for: member)
            }
            .clipShape(Circle())
        } else {
            avatarFallback(for: member)
        }
    }

    private func avatarFallback(for member: TripCollaborator?) -> some View {
        ZStack {
            Circle().fill(AppColors.appPrimary.opacity(0.2))
            Text(initials(for: member))
                .font(.appCaption.weight(.semibold))
                .foregroundStyle(AppColors.appPrimary)
        }
    }

    private func initials(for member: TripCollaborator?) -> String {
        let source = member?.resolvedDisplayName ?? "?"
        let words = source.split(separator: " ").prefix(2)
        let joined = words.compactMap { $0.first.map(String.init) }.joined()
        return joined.isEmpty ? "?" : joined.uppercased()
    }

    private var headline: String {
        let from = fromMember?.resolvedDisplayName ?? "Someone"
        let to = toMember?.resolvedDisplayName ?? "Someone"
        if isCurrentUserPaying {
            return "You owe \(to)"
        }
        return "\(from) owes you"
    }

    private var amountColor: Color {
        isCurrentUserPaying ? AppColors.appWarning : AppColors.appSuccess
    }

    private var buttonTitle: String {
        isCurrentUserPaying ? "Settle Up" : "Mark as paid"
    }

    private var accessibilityHint: String {
        isCurrentUserPaying
            ? "Open settlement methods"
            : "Mark this payment as received"
    }
}

// MARK: - Settled row

private struct SettledRow: View {
    let settlement: ExpenseSettlement
    let fromName: String
    let toName: String

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: methodSymbol)
                .foregroundStyle(AppColors.appSuccess)
                .font(.body)
                .frame(width: 28, height: 28)
                .background(AppColors.appSuccess.opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("\(fromName) paid \(toName)")
                    .font(.appBody)
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                Text(caption)
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textSecondary)
            }

            Spacer()

            Text(MoneyFormatter.string(settlement.amount, currency: settlement.currencyCode))
                .font(.appBody.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(AppColors.textPrimary)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowAccessibilityLabel)
    }

    /// Single-sentence summary so VoiceOver reads "Alex paid Sam $24 via
    /// Venmo on Apr 24" instead of stitching three separate pieces with
    /// pauses. `caption` already encodes method + date so we tack on the
    /// amount last to keep the listener oriented.
    private var rowAccessibilityLabel: String {
        let amount = MoneyFormatter.string(settlement.amount, currency: settlement.currencyCode)
        let prefix = "\(fromName) paid \(toName) \(amount)"
        let detail = caption.isEmpty ? "" : " \(caption)"
        return prefix + detail
    }

    private var methodSymbol: String {
        settlement.settledVia?.systemImage ?? "checkmark.circle"
    }

    private var caption: String {
        var pieces: [String] = []
        if let method = settlement.settledVia {
            pieces.append("via \(method.displayLabel)")
        }
        if let date = settlement.settledAt {
            pieces.append(Self.dateFormatter.string(from: date))
        }
        return pieces.joined(separator: " · ")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()
}


// =============================================================================
