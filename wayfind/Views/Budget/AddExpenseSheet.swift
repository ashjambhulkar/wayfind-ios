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
    @State private var showSplitEditor = false
    /// Wave 1.3 — receipts staged before the expense exists. After save
    /// they're flushed to `trip_expense_attachments` via the shared
    /// BackgroundUploader.
    @State private var stagedReceipts: [StagedReceipt] = []
    @State private var isSaving = false

    @FocusState private var amountFieldFocused: Bool

    @Environment(DataService.self) private var dataService

    private var existingSplits: [ExpenseSplit] {
        guard let editing = editingExpense else { return [] }
        return viewModel.snapshot.splits.filter { $0.expenseId == editing.id }
    }

    var body: some View {
        NavigationStack {
            Form {
                // Amount + description + split
                Section(String(localized: "Expense")) {
                    LabeledContent(String(localized: "Amount")) {
                        amountRow
                    }
                    LabeledContent(String(localized: "Description")) {
                        TextField(String(localized: "Dinner at Bar Tartine"), text: $title)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.sentences)
                            .autocorrectionDisabled()
                    }
                    Button {
                        recomputeSplitsFromCurrentAmount()
                        showSplitEditor = true
                    } label: {
                        LabeledContent(String(localized: "Split with")) {
                            Text(splitSummary)
                                .foregroundStyle(AppColors.textSecondary)
                                .font(.appBody)
                        }
                    }
                    .foregroundStyle(AppColors.textPrimary)

                    DatePicker(
                        String(localized: "Date"),
                        selection: $date,
                        displayedComponents: [.date]
                    )
                    .tint(category.accentColor)
                }

                // Category grid
                Section(String(localized: "Category")) {
                    ExpenseCategoryGrid(selection: $category)
                        .listRowInsets(EdgeInsets(
                            top: AppSpacing.sm,
                            leading: AppSpacing.sm,
                            bottom: AppSpacing.sm,
                            trailing: AppSpacing.sm
                        ))
                }

                // Receipts — rendered as a transparent naked row so its own card chrome shows
                Section {
                    ExpenseReceiptsSection(
                        expenseId: editingExpense?.id,
                        tripId: trip.id,
                        accent: category.accentColor,
                        stagedReceipts: $stagedReceipts
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(
                        top: 0,
                        leading: AppSpacing.xs,
                        bottom: 0,
                        trailing: AppSpacing.xs
                    ))
                }

                // Notes
                Section(String(localized: "Notes")) {
                    TextField(
                        String(localized: "Optional context, payment details, or reminders"),
                        text: $notes,
                        axis: .vertical
                    )
                    .lineLimit(2...5)
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppColors.appBackground)
            .scrollDismissesKeyboard(.interactively)
            .tint(category.accentColor)
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
                    .disabled(!canSave || isSaving)
                }
            }
            .presentationDetents([.large])
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

    private var amountRow: some View {
        HStack(spacing: AppSpacing.sm) {
            TextField(String(localized: "0"), text: $amountText)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .focused($amountFieldFocused)
                .onChange(of: amountText) { _, newValue in
                    amountText = MoneyField.sanitize(newValue)
                }

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
            amountText = format(amount: editing.originalAmount)
            currency = editing.originalCurrencyCode
            category = editing.category
            date = editing.expenseDate
            notes = editing.notes ?? ""
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
        guard !isSaving, let amount = parsedAmount else { return }
        isSaving = true
        defer { isSaving = false }
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

        let tripCap = trip.budgetCurrencyCode
        let success: Bool
        if editingExpense == nil {
            success = await viewModel.addExpense(
                expense,
                splits: resolvedSplits,
                tripBudgetCurrency: tripCap
            ) { error in
                toastManager.show(ToastData(message: error.localizedDescription, type: .error))
            }
        } else {
            success = await viewModel.updateExpense(
                expense,
                splits: resolvedSplits,
                tripBudgetCurrency: tripCap
            ) { error in
                toastManager.show(ToastData(message: error.localizedDescription, type: .error))
            }
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

// =============================================================================
