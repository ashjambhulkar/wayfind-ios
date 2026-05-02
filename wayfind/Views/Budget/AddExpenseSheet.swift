//
//  AddExpenseSheet.swift
//  wayfind
//
//  Numpad-first expense composer. Renders at .medium detent by default —
//  the user lands on the amount field with the keyboard already up so the
//  most common path (tap +, type "23", tap Save) is one motion. Expanding
//  to .large reveals notes; **split** is available on the main Expense card
//  next to amount and description (no need to expand first).
//
//  All persistence flows through `BudgetViewModel.addExpense`/.updateExpense
//  which manages the optimistic insertion + rollback. We just gather the
//  fields and hand off.
//

import SwiftUI

struct AddExpenseSheet: View {
    let trip: Trip
    let viewModel: BudgetViewModel
    let members: [TripCollaborator]
    let payerUserId: UUID?
    /// Optional source row when editing an existing expense. `nil` means
    /// "compose new". Splits are loaded from the viewmodel snapshot.
    var editingExpense: TripExpense?

    @Environment(\.dismiss) private var dismiss
    @Environment(ToastManager.self) private var toastManager

    @State private var title: String = ""
    @State private var amountText: String = ""
    @State private var currency: String = "USD"
    @State private var category: ExpenseCategory = .other
    @State private var date: Date = Date()
    @State private var notes: String = ""
    @State private var splitType: TripExpense.SplitType = .equal
    @State private var splits: [ExpenseSplit] = []
    @State private var detent: PresentationDetent = .medium
    @State private var showSplitEditor = false
    @State private var isNotesExpanded = false
    /// Wave 1.3 — receipts staged before the expense exists. After save
    /// they're flushed to `trip_expense_attachments` via the shared
    /// BackgroundUploader.
    @State private var stagedReceipts: [StagedReceipt] = []

    @FocusState private var amountFieldFocused: Bool

    @Environment(DataService.self) private var dataService

    private var existingSplits: [ExpenseSplit] {
        guard let editing = editingExpense else { return [] }
        return viewModel.snapshot.splits.filter { $0.expenseId == editing.id }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.xl) {
                    expenseDetailsSection

                    categorySection

                    ExpenseReceiptsSection(
                        expenseId: editingExpense?.id,
                        tripId: trip.id,
                        accent: category.accentColor,
                        stagedReceipts: $stagedReceipts
                    )

                    if detent == .large {
                        expenseMoreDetailsSection
                    } else {
                        moreOptionsButton
                    }
                }
                .padding(AppSpacing.lg)
            }
            .navigationTitle(editingExpense == nil ? "Add Expense" : "Edit Expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editingExpense == nil ? "Save" : "Update") {
                        Task { await save() }
                    }
                    .disabled(!canSave)
                }
            }
            .presentationDetents([.medium, .large], selection: $detent)
            .presentationDragIndicator(.visible)
            .onAppear { seedFromInputs() }
            .sheet(isPresented: $showSplitEditor) {
                if let amount = parsedAmount {
                    ExpenseSplitEditorSheet(
                        expenseId: editingExpense?.id ?? UUID(),
                        tripId: trip.id,
                        totalAmount: amount,
                        currency: currency,
                        payerUserId: payerUserId,
                        members: members,
                        splitType: $splitType,
                        initialSplits: splits,
                        onSave: { newSplits in
                            splits = newSplits
                        }
                    )
                } else {
                    splitEditorUnavailableView(
                        title: "Enter an amount first",
                        message: "Add a positive amount before choosing how to split it."
                    )
                }
            }
        }
    }

    private var expenseDetailsSection: some View {
        ExpenseMapSectionCard(title: "Expense") {
            HStack(spacing: AppSpacing.md) {
                MapStyleIcon(
                    systemName: "creditcard.fill",
                    size: .small,
                    accent: category.accentColor,
                    accessibilityLabel: "Amount"
                )

                Text("Amount")
                    .font(.appBody)
                    .foregroundStyle(AppColors.textPrimary)

                Spacer(minLength: AppSpacing.md)

                TextField("0", text: $amountText)
                    .font(.appBody)
                    .foregroundStyle(AppColors.textPrimary)
                    .keyboardType(.decimalPad)
                    .focused($amountFieldFocused)
                    .multilineTextAlignment(.trailing)
                    .onChange(of: amountText) { _, newValue in
                        amountText = MoneyField.sanitize(newValue)
                    }
                    .frame(minWidth: ExpenseMapFormMetrics.amountFieldMinWidth)

                Menu {
                    ForEach(MoneyField.commonCurrencies, id: \.self) { code in
                        Button(code) { currency = code }
                    }
                } label: {
                    HStack(spacing: AppSpacing.xs) {
                        Text(currency.uppercased())
                            .font(.appCaption.weight(.semibold))
                            .foregroundStyle(AppColors.textPrimary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.appSmall.weight(.semibold))
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.vertical, AppSpacing.xs)
                    .background(AppColors.appBackground)
                    .clipShape(Capsule())
                }
                .accessibilityLabel("Currency: \(currency.uppercased())")
            }
            .padding(.horizontal, AppSpacing.md)
            .frame(minHeight: ExpenseMapFormMetrics.rowMinHeight)

            ExpenseMapDivider()

            ExpenseMapTextRow(
                icon: "text.alignleft",
                title: "Description",
                placeholder: "Dinner at Bar Tartine",
                accent: category.accentColor,
                text: $title
            )

            ExpenseMapDivider()

            Button {
                recomputeSplitsFromCurrentAmount()
                showSplitEditor = true
            } label: {
                HStack(spacing: AppSpacing.md) {
                    MapStyleIcon(
                        systemName: "person.2.fill",
                        size: .small,
                        accent: category.accentColor,
                        accessibilityLabel: "Split"
                    )

                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text("Split with")
                            .font(.appBody)
                            .foregroundStyle(AppColors.textPrimary)
                        Text(splitSummary)
                            .font(.appSmall)
                            .foregroundStyle(AppColors.textSecondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: AppSpacing.md)

                    Image(systemName: "chevron.right")
                        .font(.appSmall.weight(.semibold))
                        .foregroundStyle(AppColors.textTertiary)
                }
                .padding(.horizontal, AppSpacing.md)
                .frame(minHeight: ExpenseMapFormMetrics.rowMinHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            FormSectionTitle("Category")

            ExpenseCategoryGrid(selection: $category)
                .padding(AppSpacing.md)
                .background(AppColors.appSurface)
                .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                        .strokeBorder(AppColors.appDivider, lineWidth: 1)
                }
        }
    }

    private var expenseMoreDetailsSection: some View {
        ExpenseMapSectionCard(title: "Details") {
            ExpenseMapDateRow(
                icon: "calendar",
                title: "Date",
                accent: category.accentColor,
                selection: $date
            )

            ExpenseMapDivider()

            ExpenseMapNotesRow(
                icon: "note.text",
                title: "Notes",
                accent: category.accentColor,
                notes: $notes,
                isExpanded: $isNotesExpanded
            )
        }
    }

    private var moreOptionsButton: some View {
        Button {
            withAnimation(AppSpring.snappy) { detent = .large }
        } label: {
            HStack(spacing: AppSpacing.md) {
                MapStyleIcon(
                    systemName: "ellipsis.circle.fill",
                    size: .small,
                    accent: category.accentColor,
                    accessibilityLabel: "More options"
                )

                Text("More Options")
                    .font(.appBody.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)

                Spacer(minLength: 0)

                Image(systemName: "chevron.down")
                    .font(.appSmall.weight(.semibold))
                    .foregroundStyle(AppColors.textTertiary)
            }
            .padding(.horizontal, AppSpacing.md)
            .frame(minHeight: ExpenseMapFormMetrics.rowMinHeight)
            .background(AppColors.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                    .strokeBorder(AppColors.appDivider, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func splitEditorUnavailableView(title: String, message: String) -> some View {
        NavigationStack {
            ContentUnavailableView(
                title,
                systemImage: "person.2.slash",
                description: Text(message)
            )
            .navigationTitle("Split")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        showSplitEditor = false
                    }
                }
            }
        }
    }

    // MARK: - Setup

    private func seedFromInputs() {
        currency = trip.budgetCurrencyCode
        if let editing = editingExpense {
            title = editing.title
            amountText = format(amount: editing.amount)
            currency = editing.currencyCode
            category = editing.category
            date = editing.expenseDate
            notes = editing.notes ?? ""
            isNotesExpanded = !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            splitType = editing.splitType
            splits = existingSplits
        } else {
            recomputeSplitsFromCurrentAmount()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            amountFieldFocused = true
        }
    }

    private func recomputeSplitsFromCurrentAmount() {
        guard let amount = parsedAmount, amount > 0 else { return }
        let participants = members.compactMap(\.userId)
        guard !participants.isEmpty else { return }
        let share = amount / Decimal(participants.count)
        splits = participants.map { uid in
            ExpenseSplit(
                id: UUID(),
                expenseId: editingExpense?.id ?? UUID(),
                tripId: trip.id,
                userId: uid,
                amount: share,
                currencyCode: currency,
                isAccepted: true,
                createdAt: nil,
                updatedAt: nil
            )
        }
    }

    // MARK: - Save

    private var parsedAmount: Decimal? {
        MoneyField.parse(amountText)
    }

    private var canSave: Bool {
        guard let amount = parsedAmount, amount > 0 else { return false }
        return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() async {
        guard let amount = parsedAmount else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = trimmedTitle.isEmpty ? category.displayLabel : trimmedTitle

        let expense = TripExpense(
            id: editingExpense?.id ?? UUID(),
            tripId: trip.id,
            userId: viewModel.currentUserId,
            payerUserId: payerUserId ?? viewModel.currentUserId,
            bookingId: editingExpense?.bookingId,
            title: resolvedTitle,
            amount: amount,
            currencyCode: currency.uppercased(),
            category: category,
            splitType: splitType,
            expenseDate: date,
            notes: notes.isEmpty ? nil : notes,
            isAutoSynced: false,
            createdAt: editingExpense?.createdAt,
            updatedAt: nil
        )

        let resolvedSplits = splits.isEmpty ? defaultEqualSplit(for: expense) : splits.map { rebound(split: $0, to: expense.id) }

        let success: Bool
        if editingExpense == nil {
            success = await viewModel.addExpense(expense, splits: resolvedSplits)
        } else {
            success = await viewModel.updateExpense(expense, splits: resolvedSplits)
        }
        if success {
            await flushStagedReceipts(for: expense)
            toastManager.show(ToastData(
                message: editingExpense == nil ? "Expense added" : "Expense updated",
                type: .success
            ))
            dismiss()
        }
    }

    /// Wave 1.3 — once the expense row is committed (or already exists),
    /// hand off any staged receipts to BackgroundUploader. Failures don't
    /// block the save toast — the user can re-attach in edit mode.
    private func flushStagedReceipts(for expense: TripExpense) async {
        guard !stagedReceipts.isEmpty else { return }
        let service = ExpenseAttachmentService(
            expenseId: expense.id,
            tripId: expense.tripId,
            dataService: dataService
        )
        for staged in stagedReceipts {
            do {
                _ = try await service.upload(
                    bytes: staged.bytes,
                    mimeType: staged.mimeType,
                    fileName: staged.fileName
                )
            } catch {
                continue
            }
        }
    }

    private func rebound(split: ExpenseSplit, to expenseId: UUID) -> ExpenseSplit {
        ExpenseSplit(
            id: split.id,
            expenseId: expenseId,
            tripId: split.tripId,
            userId: split.userId,
            amount: split.amount,
            currencyCode: split.currencyCode,
            isAccepted: split.isAccepted,
            createdAt: split.createdAt,
            updatedAt: split.updatedAt
        )
    }

    private func defaultEqualSplit(for expense: TripExpense) -> [ExpenseSplit] {
        let participants = members.compactMap(\.userId)
        guard !participants.isEmpty else { return [] }
        let share = expense.amount / Decimal(participants.count)
        return participants.map { uid in
            ExpenseSplit(
                id: UUID(),
                expenseId: expense.id,
                tripId: expense.tripId,
                userId: uid,
                amount: share,
                currencyCode: expense.currencyCode,
                isAccepted: true,
                createdAt: nil,
                updatedAt: nil
            )
        }
    }

    // MARK: - Helpers

    private func format(amount: Decimal) -> String {
        var rounded = amount
        var output = Decimal()
        NSDecimalRound(&output, &rounded, 2, .plain)
        return "\(output)"
    }

    private var splitSummary: String {
        let splittableMemberCount = members.filter { $0.userId != nil }.count
        if splittableMemberCount == 0 {
            return String(localized: "No collaborators on this trip yet")
        }
        let acceptedCount = splits.filter(\.isAccepted).count
        switch splitType {
        case .equal:
            return acceptedCount > 0
                ? String(localized: "Split equally with \(acceptedCount) people")
                : String(localized: "Split")
        case .exact:
            return String(localized: "Exact amounts")
        case .percentage:
            return String(localized: "By percentage")
        case .full:
            return String(localized: "You're covering this")
        }
    }
}

private struct ExpenseMapSectionCard<Content: View>: View {
    let title: String?
    let content: Content

    init(title: String?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            if let title {
                FormSectionTitle(title)
            }

            VStack(spacing: 0) {
                content
            }
            .background(AppColors.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                    .strokeBorder(AppColors.appDivider, lineWidth: 1)
            }
        }
    }
}

private struct ExpenseMapTextRow: View {
    let icon: String
    let title: String
    let placeholder: String
    let accent: Color
    @Binding var text: String

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            MapStyleIcon(
                systemName: icon,
                size: .small,
                accent: accent,
                accessibilityLabel: title
            )

            Text(title)
                .font(.appBody)
                .foregroundStyle(AppColors.textPrimary)

            Spacer(minLength: AppSpacing.md)

            TextField(placeholder, text: $text)
                .font(.appBody)
                .foregroundStyle(AppColors.textPrimary)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled()
                .frame(minWidth: ExpenseMapFormMetrics.trailingFieldMinWidth)
        }
        .padding(.horizontal, AppSpacing.md)
        .frame(minHeight: ExpenseMapFormMetrics.rowMinHeight)
        .contentShape(Rectangle())
    }
}

private struct ExpenseMapDateRow: View {
    let icon: String
    let title: String
    let accent: Color
    @Binding var selection: Date

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            MapStyleIcon(
                systemName: icon,
                size: .small,
                accent: accent,
                accessibilityLabel: title
            )

            DatePicker(title, selection: $selection, displayedComponents: [.date])
                .font(.appBody)
                .datePickerStyle(.compact)
                .tint(AppColors.appPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, AppSpacing.md)
        .frame(minHeight: ExpenseMapFormMetrics.rowMinHeight)
        .contentShape(Rectangle())
    }
}

private struct ExpenseMapNotesRow: View {
    let icon: String
    let title: String
    let accent: Color
    @Binding var notes: String
    @Binding var isExpanded: Bool

    private var hasNotes: Bool {
        !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(AppSpring.snappy) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: AppSpacing.md) {
                    MapStyleIcon(
                        systemName: icon,
                        size: .small,
                        accent: accent,
                        accessibilityLabel: title
                    )

                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text(hasNotes ? "Edit Notes" : "Add Notes")
                            .font(.appBody)
                            .foregroundStyle(AppColors.textPrimary)
                        Text(hasNotes ? notes : "Optional trip context, payment details, or reminders")
                            .font(.appSmall)
                            .foregroundStyle(AppColors.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: AppSpacing.md)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.appSmall.weight(.semibold))
                        .foregroundStyle(AppColors.textTertiary)
                }
                .padding(.horizontal, AppSpacing.md)
                .frame(minHeight: ExpenseMapFormMetrics.rowMinHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                HStack(alignment: .top, spacing: AppSpacing.md) {
                    Color.clear
                        .frame(width: MapStyleIconSize.small.length)

                    ZStack(alignment: .topLeading) {
                        if notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Add a note, e.g. paid in cash or reimbursed later")
                                .font(.appBody)
                                .foregroundStyle(AppColors.textTertiary)
                                .padding(.top, AppSpacing.sm)
                                .padding(.leading, AppSpacing.xs)
                                .allowsHitTesting(false)
                        }

                        TextEditor(text: $notes)
                            .font(.appBody)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: ExpenseMapFormMetrics.notesMinHeight)
                    }
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.vertical, AppSpacing.xs)
                    .background(AppColors.appBackground)
                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                            .strokeBorder(AppColors.appDivider, lineWidth: 1)
                    }
                }
                .padding(.horizontal, AppSpacing.md)
                .padding(.bottom, AppSpacing.md)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private struct ExpenseMapDivider: View {
    var body: some View {
        Divider()
            .background(AppColors.appDivider)
            .padding(.leading, AppSpacing.xxxl + AppSpacing.md)
    }
}

private enum ExpenseMapFormMetrics {
    static let rowMinHeight: CGFloat = 56
    static let amountFieldMinWidth: CGFloat = 72
    static let trailingFieldMinWidth: CGFloat = 140
    static let notesMinHeight: CGFloat = 96
}

// =============================================================================
