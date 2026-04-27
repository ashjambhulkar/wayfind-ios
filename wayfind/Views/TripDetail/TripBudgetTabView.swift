//
//  TripBudgetTabView.swift
//  wayfind
//
//  Read-side hub for the trip Budget tab. Renders the headline summary card,
//  per-category breakdown, and grouped expense list. Mutations live in
//  separate sheets (Phase 6 write); this view focuses on layout, scope
//  switching (All / Mine / Settle up), and empty / loading / failure states.
//
//  Lifetime: the underlying `BudgetViewModel` is owned by `AppRootTabView`
//  so it survives tab switches and is bound to realtime once the trip
//  detail viewmodel lands. We accept it as `Optional` because the parent
//  spins it up *after* `coordinator.activeTrip` is set, and there is a
//  single-frame window where we render before the viewmodel exists.
//

import SwiftUI

struct TripBudgetTabView: View {
    let trip: Trip
    let viewModel: BudgetViewModel?

    @Environment(CollaborationStore.self) private var collaborationStore
    @Environment(DataService.self) private var dataService
    @Environment(ToastManager.self) private var toastManager

    @State private var selectedScope: BudgetScope = .all
    @State private var showAddExpense = false
    @State private var expenseToEdit: TripExpense?
    @State private var expenseToDelete: TripExpense?
    @State private var editTripBudget = false
    @State private var editCategoryBudget: ExpenseCategory?
    /// Suggestion the user tapped "Settle Up" on. Drives `SettlementCompleteSheet`.
    @State private var settlementInProgress: SettlementSuggestion?
    @State private var csvShareURL: CSVShareItem?
    @State private var csvExportError: String?
    /// Snapshot of `trip.totalBudget` / `trip.budgetCurrencyCode` that
    /// we let users mutate via `EditTripBudgetSheet`. The owner can patch
    /// them locally so the summary card updates immediately while the
    /// network round-trip lands; the `trips` realtime channel syncs the
    /// canonical row back on the next refresh.
    @State private var localTotalBudget: Decimal?
    @State private var localBudgetCurrency: String?

    private var displayedTotalBudget: Decimal? {
        localTotalBudget ?? trip.totalBudget
    }

    private var displayedBudgetCurrency: String {
        localBudgetCurrency ?? trip.budgetCurrencyCode
    }

    var body: some View {
        Group {
            if let viewModel {
                content(viewModel: viewModel)
                    .toolbar {
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            if collaborationStore.isCurrentUserOwner {
                                Button {
                                    editTripBudget = true
                                } label: {
                                    Label("Trip budget", systemImage: "wallet.pass")
                                }
                                .accessibilityLabel("Edit trip budget")
                            }
                            Menu {
                                Button {
                                    exportCSV(viewModel: viewModel)
                                } label: {
                                    Label("Export CSV (Pro)", systemImage: "square.and.arrow.up.on.square")
                                }
                                .disabled(viewModel.snapshot.expenses.isEmpty)
                            } label: {
                                Label("More", systemImage: "ellipsis.circle")
                            }
                            .accessibilityLabel("More budget actions")
                            if collaborationStore.canEditExpenses {
                                Button {
                                    showAddExpense = true
                                } label: {
                                    Label("Add expense", systemImage: "plus")
                                }
                                .accessibilityLabel("Add expense")
                            }
                        }
                    }
                    .sheet(item: $csvShareURL) { item in
                        ExpenseCSVActivitySheet(fileURL: item.url)
                    }
                    .alert("Couldn't export CSV", isPresented: Binding(
                        get: { csvExportError != nil },
                        set: { if !$0 { csvExportError = nil } }
                    ), presenting: csvExportError) { _ in
                        Button("OK", role: .cancel) { csvExportError = nil }
                    } message: { message in
                        Text(message)
                    }
                    .sheet(isPresented: $showAddExpense) {
                        AddExpenseSheet(
                            trip: trip,
                            viewModel: viewModel,
                            members: orderedMembers,
                            payerUserId: viewModel.currentUserId ?? collaborationStore.currentUserId
                        )
                    }
                    .sheet(item: $expenseToEdit) { expense in
                        AddExpenseSheet(
                            trip: trip,
                            viewModel: viewModel,
                            members: orderedMembers,
                            payerUserId: expense.payerUserId ?? viewModel.currentUserId ?? collaborationStore.currentUserId,
                            editingExpense: expense
                        )
                    }
                    .sheet(isPresented: $editTripBudget) {
                        EditTripBudgetSheet(
                            trip: tripWithLocalOverrides,
                            viewModel: viewModel,
                            onSaved: { newTotal, newCurrency in
                                localTotalBudget = newTotal
                                localBudgetCurrency = newCurrency
                            }
                        )
                    }
                    .sheet(item: $editCategoryBudget) { category in
                        EditCategoryBudgetSheet(
                            trip: trip,
                            viewModel: viewModel,
                            initialCategory: category
                        )
                    }
                    .sheet(item: $settlementInProgress) { suggestion in
                        SettlementCompleteSheet(
                            suggestion: suggestion,
                            recipient: collaborationStore.members.first { $0.userId == suggestion.toUserId },
                            payer: collaborationStore.members.first { $0.userId == suggestion.fromUserId },
                            viewModel: viewModel
                        )
                    }
                    .confirmationDialog(
                        "Delete this expense?",
                        isPresented: Binding(
                            get: { expenseToDelete != nil },
                            set: { if !$0 { expenseToDelete = nil } }
                        ),
                        presenting: expenseToDelete
                    ) { expense in
                        Button("Delete", role: .destructive) {
                            HapticManager.warning()
                            Task {
                                await viewModel.deleteExpense(id: expense.id)
                                expenseToDelete = nil
                            }
                        }
                        Button("Cancel", role: .cancel) {
                            expenseToDelete = nil
                        }
                    } message: { expense in
                        Text("\(expense.title) — \(MoneyFormatter.string(expense.amount, currency: expense.currencyCode)). This can't be undone.")
                    }
            } else {
                loadingPlaceholder
            }
        }
        .background(AppColors.appBackground.ignoresSafeArea())
    }

    /// Members ordered with owner first, then accepted, with the current
    /// user always at the top of accepted so the split editor feels
    /// "you-first". Drives both `AddExpenseSheet` and the row labels.
    private var orderedMembers: [TripCollaborator] {
        let owner = collaborationStore.owner
        let others = collaborationStore.acceptedCollaborators.sorted { lhs, rhs in
            if lhs.userId == viewModel?.currentUserId { return true }
            if rhs.userId == viewModel?.currentUserId { return false }
            return (lhs.displayName ?? "") < (rhs.displayName ?? "")
        }
        return ([owner].compactMap { $0 } + others)
    }

    private var tripWithLocalOverrides: Trip {
        var copy = trip
        if let localTotalBudget {
            copy.totalBudget = localTotalBudget
        }
        if let localBudgetCurrency {
            copy.budgetCurrencyCode = localBudgetCurrency
        }
        return copy
    }

    // MARK: - Content

    @ViewBuilder
    private func content(viewModel: BudgetViewModel) -> some View {
        ScrollView {
            VStack(spacing: AppSpacing.lg) {
                if showsScopePicker {
                    scopePicker
                        .padding(.horizontal, AppSpacing.lg)
                }

                if viewModel.isMixedCurrency {
                    MixedCurrencyBanner(
                        totals: viewModel.totalsByCurrency,
                        headlineCurrency: displayedBudgetCurrency
                    )
                    .padding(.horizontal, AppSpacing.lg)
                }

                summaryCard(for: viewModel)
                    .padding(.horizontal, AppSpacing.lg)

                BudgetHomeCurrencyHeader(
                    totalAmount: viewModel.totalsByCurrency[displayedBudgetCurrency.uppercased()] ?? 0,
                    tripCurrency: displayedBudgetCurrency
                )
                .padding(.horizontal, AppSpacing.lg)

                if selectedScope == .settleUp && showsScopePicker {
                    SettlementsSection(
                        suggestions: visibleSuggestions(for: viewModel),
                        recentSettlements: recentSettlements(in: viewModel),
                        members: orderedMembers,
                        currentUserId: viewModel.currentUserId,
                        onSettle: { suggestion in
                            settlementInProgress = suggestion
                        }
                    )
                    .padding(.horizontal, AppSpacing.lg)
                } else if hasAnyData(in: viewModel) {
                    CategoryBudgetSection(
                        perCategory: viewModel.perCategoryByCurrency[displayedBudgetCurrency.uppercased()] ?? [:],
                        plannedByCategory: plannedCategoryMap(viewModel: viewModel),
                        currency: displayedBudgetCurrency,
                        canEdit: collaborationStore.canEditExpenses,
                        onEdit: { category in
                            editCategoryBudget = category
                        }
                    )
                    .padding(.horizontal, AppSpacing.lg)

                    if showsScopePicker, !viewModel.settlementSuggestions.isEmpty {
                        SettlementsSection(
                            suggestions: visibleSuggestions(for: viewModel),
                            recentSettlements: [],
                            members: orderedMembers,
                            currentUserId: viewModel.currentUserId,
                            onSettle: { suggestion in
                                settlementInProgress = suggestion
                            }
                        )
                        .padding(.horizontal, AppSpacing.lg)
                    }

                    expenseList(for: viewModel)
                        .padding(.horizontal, AppSpacing.lg)
                } else if viewModel.hasLoadedAtLeastOnce {
                    emptyState
                        .padding(.horizontal, AppSpacing.lg)
                        .padding(.top, AppSpacing.xl)
                }
            }
            .padding(.vertical, AppSpacing.lg)
        }
        .refreshable {
            await viewModel.reload()
        }
        .overlay(alignment: .top) {
            if viewModel.lastFetchFailed {
                fetchFailedBanner(viewModel: viewModel)
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.top, AppSpacing.sm)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: viewModel.lastFetchFailed)
    }

    // MARK: - Scope picker (only shown when there's >1 member)

    private var showsScopePicker: Bool {
        // Hide for solo trips — "All" and "Mine" would be identical and
        // "Settle up" would be empty. Trip owner counts as a member.
        collaborationStore.totalAcceptedMemberCount > 1
    }

    private var scopePicker: some View {
        Picker("View", selection: $selectedScope) {
            Text("All").tag(BudgetScope.all)
            Text("Mine").tag(BudgetScope.mine)
            Text("Settle up").tag(BudgetScope.settleUp)
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Summary card

    @ViewBuilder
    private func summaryCard(for viewModel: BudgetViewModel) -> some View {
        let currency = displayedBudgetCurrency.uppercased()
        let spent: Decimal = {
            switch selectedScope {
            case .mine:
                return viewModel.myShareByCurrency[currency] ?? 0
            default:
                return viewModel.totalsByCurrency[currency] ?? 0
            }
        }()
        BudgetSummaryCard(
            spent: spent,
            budget: displayedTotalBudget,
            currency: displayedBudgetCurrency,
            dailyPace: paceFor(spent: spent),
            daysRemainingCaption: daysRemainingCaption
        )
    }

    private func paceFor(spent: Decimal) -> Decimal? {
        let elapsed = max(daysElapsed, 1)
        guard spent > 0 else { return nil }
        return spent / Decimal(elapsed)
    }

    private var daysElapsed: Int {
        let calendar = Calendar.current
        let today = Date()
        if today < trip.startDate { return 0 }
        let endOfWindow = min(today, trip.endDate)
        let comps = calendar.dateComponents([.day], from: trip.startDate, to: endOfWindow)
        return (comps.day ?? 0) + 1
    }

    private var daysRemainingCaption: String? {
        let calendar = Calendar.current
        let today = Date()
        if today < trip.startDate {
            let days = calendar.dateComponents([.day], from: today, to: trip.startDate).day ?? 0
            return days > 0 ? "Trip starts in \(days)d" : nil
        }
        if today > trip.endDate {
            return "Trip ended"
        }
        let remaining = calendar.dateComponents([.day], from: today, to: trip.endDate).day ?? 0
        if remaining <= 0 { return "Last day" }
        return "Trip ends in \(remaining)d"
    }

    // MARK: - Expense list

    @ViewBuilder
    private func expenseList(for viewModel: BudgetViewModel) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Expenses")
                .font(.sectionHeader)
                .foregroundStyle(AppColors.textPrimary)

            VStack(spacing: AppSpacing.md) {
                ForEach(groupedExpenses(viewModel: viewModel), id: \.id) { group in
                    expenseGroup(group: group, viewModel: viewModel)
                }
            }
        }
    }

    @ViewBuilder
    private func expenseGroup(group: ExpenseDateGroup, viewModel: BudgetViewModel) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(group.headerLabel)
                .font(.appCaption.weight(.semibold))
                .foregroundStyle(AppColors.textSecondary)
                .textCase(.uppercase)

            VStack(spacing: 0) {
                ForEach(group.expenses) { expense in
                    expenseRowView(expense: expense, viewModel: viewModel)
                    if expense.id != group.expenses.last?.id {
                        Divider()
                            .padding(.leading, AppSpacing.lg + 40)
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

    /// Single expense row, gated by `canEditExpense(_:)`. Tap-to-edit is
    /// only enabled when the user is the payer (or the trip owner). Swipe
    /// actions follow the same gate. We intentionally use a Button rather
    /// than `.swipeActions` because the row sits inside a plain `VStack`
    /// (the budget hub is a `ScrollView`, not a `List`) and List-only
    /// modifiers wouldn't fire.
    @ViewBuilder
    private func expenseRowView(expense: TripExpense, viewModel: BudgetViewModel) -> some View {
        let canEdit = canEditExpense(expense)
        Button {
            if canEdit {
                expenseToEdit = expense
            }
        } label: {
            BudgetExpenseRow(
                expense: expense,
                payerName: payerName(for: expense.payerUserId),
                payerAvatarURL: payerAvatar(for: expense.payerUserId),
                myShare: shareForCurrentUser(in: expense, viewModel: viewModel)
            )
            .padding(.horizontal, AppSpacing.md)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if canEdit {
                Button {
                    expenseToEdit = expense
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    expenseToDelete = expense
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    /// Mirrors the plan: `canEditExpenses && (isPayer || canManage)`. The
    /// owner can delete anyone's expense (in case a member fat-fingers a
    /// $9,500 hotel they can't undo themselves), but typical edits stay
    /// with the payer.
    private func canEditExpense(_ expense: TripExpense) -> Bool {
        guard collaborationStore.canEditExpenses else { return false }
        if collaborationStore.canManage { return true }
        guard let currentUserId = viewModel?.currentUserId else { return false }
        return expense.payerUserId == currentUserId
    }

    // MARK: - Helpers

    private func hasAnyData(in viewModel: BudgetViewModel) -> Bool {
        !viewModel.snapshot.expenses.isEmpty
            || !viewModel.snapshot.budgets.isEmpty
            || displayedTotalBudget != nil
    }

    private func plannedCategoryMap(viewModel: BudgetViewModel) -> [ExpenseCategory: Decimal] {
        var map: [ExpenseCategory: Decimal] = [:]
        for budget in viewModel.snapshot.budgets {
            map[budget.category, default: 0] += budget.plannedAmount
        }
        return map
    }

    private func groupedExpenses(viewModel: BudgetViewModel) -> [ExpenseDateGroup] {
        let filtered: [TripExpense] = {
            switch selectedScope {
            case .mine:
                guard let userId = viewModel.currentUserId else { return [] }
                let mine = Set(viewModel.snapshot.splits.filter {
                    $0.userId == userId && $0.isAccepted
                }.map(\.expenseId))
                return viewModel.snapshot.expenses.filter {
                    $0.payerUserId == userId || mine.contains($0.id)
                }
            default:
                return viewModel.snapshot.expenses
            }
        }()
        let grouped = Dictionary(grouping: filtered) { expense in
            Calendar.current.startOfDay(for: expense.expenseDate)
        }
        return grouped
            .map { ExpenseDateGroup(date: $0.key, expenses: $0.value.sorted { $0.expenseDate > $1.expenseDate }) }
            .sorted { $0.date > $1.date }
    }

    private func payerName(for userId: UUID?) -> String? {
        guard let userId else { return nil }
        if userId == collaborationStore.currentUserId { return "You" }
        return collaborationStore.members.first { $0.userId == userId }?.displayName
    }

    private func payerAvatar(for userId: UUID?) -> String? {
        guard let userId else { return nil }
        return collaborationStore.members.first { $0.userId == userId }?.avatarURLString
    }

    /// Filters the simplifier output for the focused scope. On the
    /// "Settle up" segment we show every open suggestion regardless of
    /// who's involved; on "All" / "Mine" the section only renders when
    /// the current user is part of a suggestion so it doesn't dominate
    /// the hub for solo viewers.
    private func visibleSuggestions(for viewModel: BudgetViewModel) -> [SettlementSuggestion] {
        let all = viewModel.settlementSuggestions
        if selectedScope == .settleUp {
            return all
        }
        guard let userId = viewModel.currentUserId else { return [] }
        return all.filter { $0.fromUserId == userId || $0.toUserId == userId }
    }

    /// Up to five most recent completed settlements for the "Recently
    /// settled" rail. Realtime-driven so a new settlement collapses into
    /// this list within a tick of being marked.
    private func recentSettlements(in viewModel: BudgetViewModel) -> [ExpenseSettlement] {
        viewModel.snapshot.settlements
            .filter { $0.isSettled }
            .sorted { lhs, rhs in
                let lhsDate = lhs.settledAt ?? lhs.createdAt ?? Date.distantPast
                let rhsDate = rhs.settledAt ?? rhs.createdAt ?? Date.distantPast
                return lhsDate > rhsDate
            }
            .prefix(5)
            .map { $0 }
    }

    private func shareForCurrentUser(in expense: TripExpense, viewModel: BudgetViewModel) -> Decimal? {
        guard let userId = viewModel.currentUserId else { return nil }
        let split = viewModel.snapshot.splits.first {
            $0.expenseId == expense.id && $0.userId == userId
        }
        return split?.amount
    }

    // MARK: - Empty / failure states

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No expenses yet", systemImage: "creditcard")
        } description: {
            Text(emptyStateHint)
        } actions: {
            if collaborationStore.canEditExpenses {
                Button {
                    showAddExpense = true
                } label: {
                    Text("Add Expense")
                        .font(.appButton)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.appPrimary)
            }
        }
    }

    private var emptyStateHint: String {
        if collaborationStore.canEditExpenses {
            return "Track spending as you go. Add a flight, dinner, or anything else and it shows up here."
        }
        return "Once a trip member adds an expense, it'll appear here."
    }

    private var loadingPlaceholder: some View {
        ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func fetchFailedBanner(viewModel: BudgetViewModel) -> some View {
        Button {
            Task { await viewModel.reload() }
        } label: {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppColors.appWarning)
                Text("Couldn't refresh budget · Tap to retry")
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textPrimary)
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm)
            .background(AppColors.appSurface)
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(AppColors.appWarning.opacity(0.6), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct ExpenseDateGroup: Identifiable {
    let id = UUID()
    let date: Date
    let expenses: [TripExpense]

    var headerLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return formatter.string(from: date)
    }
}

enum BudgetScope: Hashable {
    case all
    case mine
    case settleUp
}

private struct MixedCurrencyBanner: View {
    let totals: [String: Decimal]
    let headlineCurrency: String

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: "globe")
                .foregroundStyle(AppColors.appPrimary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Multiple currencies on this trip")
                    .font(.appCaption.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
                Text(captionText)
                    .font(.appSmall)
                    .foregroundStyle(AppColors.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .background(AppColors.appPrimary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
    }

    private var captionText: String {
        let others = totals
            .filter { $0.key.uppercased() != headlineCurrency.uppercased() }
            .sorted { $0.key < $1.key }
        let parts = others.map { MoneyFormatter.string($0.value, currency: $0.key) }
        return "Also tracking " + parts.joined(separator: " · ")
    }
}


// =============================================================================

// MARK: - CSV Export glue (Wave 2.3)

/// `Identifiable` wrapper so we can use `.sheet(item:)` with the URL we
/// just wrote to disk. URL doesn't conform out of the box.
struct CSVShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// Bridges `UIActivityViewController` into SwiftUI for the CSV share
/// flow. Using UIActivityViewController instead of ShareLink because
/// it gives us "Save to Files" + "Open in Excel" without configuration.
private struct ExpenseCSVActivitySheet: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

extension TripBudgetTabView {
    /// Wave 4.5 — CSV export is now a HARD Pro gate.
    ///
    /// Free users tapping the menu item see the paywall via
    /// `PaywallPresenter` (which also publishes the
    /// `pro_gate_attempted` analytics event). Pro users get the
    /// existing share-sheet flow unchanged.
    ///
    /// We deliberately let the menu item *render* for free users
    /// (with the "Pro" suffix already in the label) instead of
    /// hiding it, so users discover the feature exists. This is a
    /// "show, then upsell" pattern — opposite of "hide and surprise".
    fileprivate func exportCSV(viewModel: BudgetViewModel) {
        if !EntitlementService.shared.hasPremiumAccess {
            PaywallPresenter.shared.present(
                .csvExport,
                dataService: dataService,
                metadata: [
                    "expense_count": String(viewModel.snapshot.expenses.count),
                    "trip_id": trip.id.uuidString,
                    "trigger": "budget_toolbar",
                ]
            )
            return
        }
        do {
            let url = try ExpenseCSVExporter.export(
                expenses: viewModel.snapshot.expenses,
                splits: viewModel.snapshot.splits,
                members: orderedMembers,
                tripName: trip.title
            )
            csvShareURL = CSVShareItem(url: url)
        } catch {
            csvExportError = error.localizedDescription
        }
    }
}
