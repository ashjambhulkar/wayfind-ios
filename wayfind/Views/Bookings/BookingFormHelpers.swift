import SwiftUI

struct FormSectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.appSmall)
            .foregroundStyle(AppColors.textTertiary)
            .tracking(1.5)
            .textCase(.uppercase)
    }
}

struct FormField: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(label)
                .font(.appCaption)
                .foregroundStyle(AppColors.textSecondary)
            TextField(placeholder, text: $text)
                .font(.appBody)
                .padding(.horizontal, AppSpacing.md)
                .frame(height: 48)
                .background(AppColors.appSurface)
                .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                        .strokeBorder(AppColors.appDivider, lineWidth: 1)
                )
        }
    }
}

struct FormDateRow: View {
    let label: String
    @Binding var selection: Date
    var components: DatePickerComponents = [.date, .hourAndMinute]

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(label)
                .font(.appCaption)
                .foregroundStyle(AppColors.textSecondary)
            DatePicker(label, selection: $selection, displayedComponents: components)
                .labelsHidden()
                .datePickerStyle(.compact)
                .tint(AppColors.appPrimary)
                .padding(.horizontal, AppSpacing.md)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .background(AppColors.appSurface)
                .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                        .strokeBorder(AppColors.appDivider, lineWidth: 1)
                )
        }
    }
}

// MARK: - Optional date (booking forms)

/// Row for a booking date/time that may be unset: shows **Not set** until the
/// user chooses a value (no silent default to “now”).
struct OptionalBookingDateRow: View {
    let icon: String
    let rowTitle: String
    let accent: Color
    @Binding var selection: Date?
    var displayedComponents: DatePickerComponents = [.date, .hourAndMinute]

    @Environment(\.calendar) private var calendar

    @State private var showingSheet = false
    @State private var draft = Date()

    var body: some View {
        HStack(alignment: .center, spacing: AppSpacing.md) {
            MapStyleIcon(
                systemName: icon,
                size: .small,
                accent: accent,
                accessibilityLabel: rowTitle
            )

            if selection != nil {
                DatePicker(
                    rowTitle,
                    selection: Binding(
                        get: { selection! },
                        set: { selection = $0 }
                    ),
                    displayedComponents: displayedComponents
                )
                .font(.appBody)
                .datePickerStyle(.compact)
                .tint(AppColors.appPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

                Menu {
                    Button(role: .destructive) {
                        selection = nil
                    } label: {
                        Label(String(localized: "Clear date"), systemImage: "xmark.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body.weight(.medium))
                        .foregroundStyle(AppColors.textSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(String(localized: "Date options"))
            } else {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(rowTitle)
                        .font(.appBody)
                        .foregroundStyle(AppColors.textPrimary)
                    Text(String(localized: "Not set"))
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textSecondary)
                }

                Spacer(minLength: AppSpacing.md)

                Button(String(localized: "Set date")) {
                    prepareDraftFromCurrentSelection()
                    showingSheet = true
                }
                .font(.appCaption.weight(.semibold))
                .foregroundStyle(AppColors.appPrimary)
            }
        }
        .padding(.horizontal, AppSpacing.md)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .sheet(isPresented: $showingSheet) {
            NavigationStack {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    DatePicker(
                        rowTitle,
                        selection: $draft,
                        displayedComponents: displayedComponents
                    )
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .tint(AppColors.appPrimary)
                    Spacer(minLength: 0)
                }
                .padding(AppSpacing.lg)
                .navigationTitle(rowTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Cancel")) {
                            showingSheet = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Done")) {
                            selection = draft
                            showingSheet = false
                        }
                        .fontWeight(.semibold)
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func prepareDraftFromCurrentSelection() {
        if let existing = selection {
            draft = existing
            return
        }
        let anchor = Date()
        draft = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: anchor)
            ?? calendar.startOfDay(for: anchor)
    }
}

/// Decimal-pad money input with an inline currency chip. Used in both the
/// AddExpenseSheet (PR-3) and the booking forms (PR-5) so all monetary
/// inputs share one parser. The text binding is the locale-friendly user
/// input; the parsed `Decimal?` is exposed for the caller to send to the
/// data layer. Locale-safe in two places: the keyboard fallback to "."
/// when the user is on a "," locale, and `Decimal(string:locale:)` for
/// the inverse parse.
struct MoneyField: View {
    let label: String
    let placeholder: String
    @Binding var amountText: String
    @Binding var currency: String

    /// Optional caption shown beneath the field — e.g.
    /// "Tracks as expense automatically" for booking forms.
    var caption: String? = nil

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(label)
                .font(.appCaption)
                .foregroundStyle(AppColors.textSecondary)
            HStack(spacing: AppSpacing.sm) {
                TextField(placeholder, text: $amountText)
                    .font(.appBody)
                    .keyboardType(.decimalPad)
                    .focused($isFocused)
                    .onChange(of: amountText) { _, newValue in
                        amountText = MoneyField.sanitize(newValue)
                    }

                Menu {
                    ForEach(MoneyField.commonCurrencies, id: \.self) { code in
                        Button(code) { currency = code }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(currency.uppercased())
                            .font(.appBody.weight(.semibold))
                            .foregroundStyle(AppColors.textPrimary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.vertical, 6)
                    .background(AppColors.appBackground)
                    .clipShape(Capsule())
                }
                .accessibilityLabel("Currency: \(currency.uppercased())")
            }
            .padding(.horizontal, AppSpacing.md)
            .frame(height: 48)
            .background(AppColors.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                    .strokeBorder(AppColors.appDivider, lineWidth: 1)
            )

            if let caption {
                Text(caption)
                    .font(.appSmall)
                    .foregroundStyle(AppColors.textTertiary)
            }
        }
    }

    /// Strips leading currency symbols, collapses double separators, and
    /// converts user-typed "," to "." so the downstream `Decimal(string:)`
    /// parser stays locale-agnostic. Keeps a single decimal separator.
    static func sanitize(_ raw: String) -> String {
        let allowed = Set("0123456789.,")
        var stripped = String(raw.filter { allowed.contains($0) })
        // Replace localized comma with dot for parsing — we'll show whatever
        // the user typed, but persist a normalized form.
        stripped = stripped.replacingOccurrences(of: ",", with: ".")
        let parts = stripped.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count > 2 {
            stripped = parts[0] + "." + parts.dropFirst().joined()
        }
        return stripped
    }

    static func parse(_ raw: String) -> Decimal? {
        let normalized = sanitize(raw)
        guard !normalized.isEmpty else { return nil }
        return Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
    }

    static let commonCurrencies = ["USD", "EUR", "GBP", "JPY", "CAD", "AUD", "INR", "MXN", "CHF", "CNY"]
}


// =============================================================================

