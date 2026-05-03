//
//  BudgetFxProviderAttribution.swift
//  wayfind
//
//  pr-7 — canonical URLs and copy for third-party FX sources. Frankfurter is
//  free for commercial use; underlying data is credited to central banks
//  (see frankfurter.app). Backup `exchangerate.host` is used only when
//  Frankfurter lacks a code (see `currency-rates` Edge Function). Keep this
//  file aligned with `CurrencyService` + `ExchangeRateAttributionSheet`.
//

import Foundation

enum BudgetFxProviderAttribution {

    static let frankfurterHomeURL = URL(string: "https://www.frankfurter.app/")!

    static let exchangerateHostHomeURL = URL(string: "https://exchangerate.host/")!

    static let exchangerateHostTermsURL = URL(string: "https://exchangerate.host/service-agreement")!

    /// Short paragraph shown in Profile → Exchange rate data.
    static let disclosureSummary = """
    Wayfind fetches daily reference exchange rates when you save expenses in a \
    currency different from the trip’s budget currency, and when you view \
    converted budget summaries. We cache responses on your device to reduce \
    network use.
    """

    /// Secondary detail (Frankfurter aggregates central-bank sources).
    static let frankfurterDetail = """
    Primary rates come from Frankfurter, an open-source project that aggregates \
    daily reference rates published by central banks and similar institutions.
    """

    /// Backup provider (Edge function `currency-rates`).
    static let backupDetail = """
    When Frankfurter does not publish a requested currency, our servers may \
    request the same date from exchangerate.host (APILayer) so your receipt \
    currency still converts. Use their site for service terms.
    """
}


// =============================================================================
