//
//  ExpenseSplitEditorSheet.swift
//  wayfind
//
//  Modal that owns the split configuration for a single expense — how the
//  total amount divides across the trip's accepted members. Supports the
//  four split types the database understands:
//
//    .equal      → divide the total by the count of accepted members
//    .exact      → user enters the per-member amount; sum must equal total
//    .percentage → user enters per-member percent; sum must equal 100
//    .full       → payer covers the whole amount; everyone else owes 0
//
//  The sheet returns a fresh `[ExpenseSplit]` to the caller via the
//  `onSave` closure. We do all the locale-safe parsing here so the parent
//  AddExpenseSheet just hands us the total + currency.
//

import SwiftUI

struct ExpenseSplitEditorSheet: View {
    let expenseId: UUID
    let tripId: UUID
    let totalAmount: Decimal
    let currency: String
    let payerUserId: UUID?
    /// All trip members. Pending email-only invites are filtered out — only
    /// members with a resolved `userId` can be assigned a split because the
    /// `expense_splits` row needs a user FK.
    let members: [TripCollaborator]
    @Binding var splitType: TripExpense.SplitType
    let initialSplits: [ExpenseSplit]
    let onSave: ([ExpenseSplit]) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var participantStates: [UUID: ParticipantState] = [:]

    private var splitableMembers: [TripCollaborator] {
        members.filter { $0.userId != nil }
    }

    private struct ParticipantState: Hashable {
        var isAccepted: Bool
        var amountText: String
        var percentText: String
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                        FormSectionTitle(String(localized: "Split method"))
                        VStack(alignment: .leading, spacing: AppSpacing.sm) {
                            Picker("Split type", selection: $splitType) {
                                ForEach(TripExpense.SplitType.allCases, id: \.self) { type in
                                    Text(type.displayLabel).tag(type)
                                }
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: splitType) { _, _ in
                                recomputeAfterTypeChange()
                            }
                        }
                        .padding(AppSpacing.md)
                        .background(AppColors.appSurface)
                        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                                .strokeBorder(AppColors.appDivider, lineWidth: 1)
                        }
                    }

                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                        FormSectionTitle(String(localized: "With"))
                        VStack(spacing: 0) {
                            if splitableMembers.isEmpty {
                                emptyCollaboratorsCallout
                            } else {
                                ForEach(Array(splitableMembers.enumerated()), id: \.element.stableID) { index, member in
                                    if index > 0 {
                                        Divider()
                                            .background(AppColors.appDivider)
                                            .padding(.leading, AppSpacing.xxxl + AppSpacing.sm)
                                    }
                                    participantRow(for: member)
                                }
                            }
                        }
                        .background(AppColors.appSurface)
                        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                                .strokeBorder(AppColors.appDivider, lineWidth: 1)
                        }
                    }

                    if let summary = summaryFooter {
                        Text(summary.text)
                            .font(.appCaption)
                            .foregroundStyle(summary.isError ? AppColors.appError : AppColors.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, AppSpacing.xs)
                    }
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.vertical, AppSpacing.md)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AppColors.appBackground)
            .navigationTitle(String(localized: "Split"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) { commit() }
                        .disabled(!canCommit)
                }
            }
            .onAppear { seedInitialState() }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    private var emptyCollaboratorsCallout: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: "person.2.slash")
                    .font(.sectionHeader)
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(width: MapStyleIconSize.small.length, alignment: .center)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(String(localized: "No collaborators yet"))
                        .font(.appBody.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                    Text(String(localized: "Invite people to this trip to split expenses. Until then, only you can be assigned shares."))
                        .font(.appSmall)
                        .foregroundStyle(AppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Rows

    @ViewBuilder
    private func participantRow(for member: TripCollaborator) -> some View {
        if let memberId = member.userId {
            participantRowBody(memberId: memberId, member: member)
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, AppSpacing.sm)
        }
    }

    @ViewBuilder
    private func participantRowBody(memberId: UUID, member: TripCollaborator) -> some View {
        let state = participantStates[memberId] ?? ParticipantState(isAccepted: true, amountText: "", percentText: "")

        HStack(spacing: AppSpacing.md) {
            Toggle(isOn: Binding(
                get: { participantStates[memberId]?.isAccepted ?? true },
                set: { newValue in
                    var existing = participantStates[memberId] ?? state
                    existing.isAccepted = newValue
                    participantStates[memberId] = existing
                    if splitType == .equal {
                        recomputeEqualSplit()
                    }
                }
            )) {
                VStack(alignment: .leading) {
                    Text(member.displayName ?? "Member")
                        .font(.appBody)
                        .foregroundStyle(AppColors.textPrimary)
                    if let username = member.username {
                        Text("@\(username)")
                            .font(.appSmall)
                            .foregroundStyle(AppColors.textTertiary)
                    }
                }
            }
            .toggleStyle(.checkmark)
            .disabled(splitType == .full && member.userId != payerUserId)

            Spacer()

            switch splitType {
            case .equal:
                Text(equalShareString(for: memberId))
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textSecondary)
                    .monospacedDigit()
            case .exact:
                TextField("0", text: Binding(
                    get: { participantStates[memberId]?.amountText ?? "" },
                    set: { newValue in
                        var existing = participantStates[memberId] ?? state
                        existing.amountText = MoneyField.sanitize(newValue)
                        participantStates[memberId] = existing
                    }
                ))
                .multilineTextAlignment(.trailing)
                .keyboardType(.decimalPad)
                .frame(width: 80)
            case .percentage:
                HStack(spacing: 2) {
                    TextField("0", text: Binding(
                        get: { participantStates[memberId]?.percentText ?? "" },
                        set: { newValue in
                            var existing = participantStates[memberId] ?? state
                            existing.percentText = MoneyField.sanitize(newValue)
                            participantStates[memberId] = existing
                        }
                    ))
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.decimalPad)
                    .frame(width: 60)
                    Text("%")
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textSecondary)
                }
            case .full:
                Text(member.userId == payerUserId
                     ? MoneyFormatter.string(totalAmount, currency: currency)
                     : MoneyFormatter.string(0, currency: currency))
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textSecondary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - State management

    private func seedInitialState() {
        var initial: [UUID: ParticipantState] = [:]
        for member in splitableMembers {
            guard let memberId = member.userId else { continue }
            let existingSplit = initialSplits.first(where: { $0.userId == memberId })
            initial[memberId] = ParticipantState(
                isAccepted: existingSplit?.isAccepted ?? true,
                amountText: existingSplit.map { format(amount: $0.amount) } ?? "",
                percentText: existingSplit.map { percentString(for: $0.amount) } ?? ""
            )
        }
        participantStates = initial
        if splitType == .equal { recomputeEqualSplit() }
    }

    private func recomputeAfterTypeChange() {
        switch splitType {
        case .equal:
            recomputeEqualSplit()
        case .full:
            for memberId in participantStates.keys {
                participantStates[memberId]?.isAccepted = (memberId == payerUserId)
            }
        case .exact, .percentage:
            break
        }
    }

    private func recomputeEqualSplit() {
        let acceptedIds = participantStates.filter { $0.value.isAccepted }.map(\.key)
        guard !acceptedIds.isEmpty else { return }
        let share = totalAmount / Decimal(acceptedIds.count)
        for memberId in participantStates.keys {
            if acceptedIds.contains(memberId) {
                participantStates[memberId]?.amountText = format(amount: share)
            } else {
                participantStates[memberId]?.amountText = "0"
            }
        }
    }

    private func equalShareString(for memberId: UUID) -> String {
        let acceptedIds = participantStates.filter { $0.value.isAccepted }.map(\.key)
        guard acceptedIds.contains(memberId), !acceptedIds.isEmpty else {
            return MoneyFormatter.string(0, currency: currency)
        }
        return MoneyFormatter.string(totalAmount / Decimal(acceptedIds.count), currency: currency)
    }

    // MARK: - Validation + commit

    private var summaryFooter: (text: String, isError: Bool)? {
        switch splitType {
        case .equal, .full:
            return nil
        case .exact:
            let sum = participantStates.values.reduce(Decimal(0)) { acc, state in
                guard state.isAccepted, let value = MoneyField.parse(state.amountText) else {
                    return acc
                }
                return acc + value
            }
            if sum == totalAmount {
                return ("Splits add up.", false)
            }
            let diff = totalAmount - sum
            return ("Off by \(MoneyFormatter.string(diff, currency: currency))", true)
        case .percentage:
            let sum = participantStates.values.reduce(Decimal(0)) { acc, state in
                guard state.isAccepted, let value = MoneyField.parse(state.percentText) else {
                    return acc
                }
                return acc + value
            }
            if sum == 100 {
                return ("100% allocated.", false)
            }
            return ("Off by \((100 - sum).description)%", true)
        }
    }

    private var canCommit: Bool {
        guard !participantStates.isEmpty else { return false }
        guard participantStates.values.contains(where: \.isAccepted) else { return false }
        switch splitType {
        case .equal, .full:
            return true
        case .exact, .percentage:
            return summaryFooter?.isError == false
        }
    }

    private func commit() {
        let result = splitableMembers.compactMap { member -> ExpenseSplit? in
            guard let memberId = member.userId,
                  let state = participantStates[memberId] else { return nil }
            let amount: Decimal
            switch splitType {
            case .equal:
                let acceptedCount = participantStates.values.filter(\.isAccepted).count
                amount = state.isAccepted && acceptedCount > 0 ? totalAmount / Decimal(acceptedCount) : 0
            case .exact:
                amount = state.isAccepted ? (MoneyField.parse(state.amountText) ?? 0) : 0
            case .percentage:
                let pct = state.isAccepted ? (MoneyField.parse(state.percentText) ?? 0) : 0
                amount = totalAmount * pct / 100
            case .full:
                amount = (memberId == payerUserId) ? totalAmount : 0
            }
            return ExpenseSplit(
                id: initialSplits.first(where: { $0.userId == memberId })?.id ?? UUID(),
                expenseId: expenseId,
                tripId: tripId,
                userId: memberId,
                amount: amount,
                currencyCode: currency,
                isAccepted: state.isAccepted,
                createdAt: nil,
                updatedAt: nil
            )
        }
        onSave(result)
        dismiss()
    }

    // MARK: - Helpers

    private func format(amount: Decimal) -> String {
        var rounded = amount
        var output = Decimal()
        NSDecimalRound(&output, &rounded, 2, .plain)
        return "\(output)"
    }

    private func percentString(for amount: Decimal) -> String {
        guard totalAmount > 0 else { return "" }
        let pct = amount / totalAmount * 100
        var rounded = pct
        var output = Decimal()
        NSDecimalRound(&output, &rounded, 2, .plain)
        return "\(output)"
    }
}

private struct CheckmarkToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(action: { configuration.isOn.toggle() }) {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                    .font(.sectionHeader.weight(.regular))
                    .foregroundStyle(configuration.isOn ? AppColors.appPrimary : AppColors.textTertiary)
                configuration.label
            }
        }
        .buttonStyle(.plain)
    }
}

extension ToggleStyle where Self == CheckmarkToggleStyle {
    static var checkmark: CheckmarkToggleStyle { CheckmarkToggleStyle() }
}


// =============================================================================
