//
//  MoneyFormatter.swift
//  wayfind
//
//  Locale-aware currency formatting helpers used everywhere we render a
//  `Decimal` amount. We always go through `.formatted(.currency(code:))`
//  rather than `NumberFormatter` directly so the user's preferred locale
//  decides the digit grouping and symbol placement (e.g. "1,234.56 €" vs
//  "€1,234.56" vs "1.234,56 €").
//

import Foundation

enum MoneyFormatter {
    /// Standard amount string — "$12.50", "€2,300.00", etc. Negative amounts
    /// keep the leading sign so debit / credit semantics stay readable
    /// without colour as the only differentiator.
    static func string(_ amount: Decimal, currency: String) -> String {
        amount.formatted(.currency(code: currency.uppercased()))
    }

        /// Headline-scale variant used by the BudgetSummaryCard. Drops the
    /// fractional part for amounts ≥ $100 so the headline reads "$2,340"
    /// instead of "$2,340.00" — Apple Health style.
    static func headlineString(_ amount: Decimal, currency: String) -> String {
        let abs = amount < 0 ? -amount : amount
        var format = Decimal.FormatStyle.Currency(code: currency.uppercased())
        if abs >= 100 {
            format = format.precision(.fractionLength(0))
        }
        return format.format(amount)
    }

    /// "$0" for the explicit "no spend yet" state. Uses the headline style
    /// so the empty hub looks consistent with the populated one.
    static func zeroString(currency: String) -> String {
        headlineString(0, currency: currency)
    }
}


// =============================================================================
