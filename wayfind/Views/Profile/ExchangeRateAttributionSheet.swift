//
//  ExchangeRateAttributionSheet.swift
//  wayfind
//
//  In-app disclosure for budget FX sources (pr-7). Shown from Profile;
//  uses SwiftUI `Link` — no custom URL opener.
//

import SwiftUI

struct ExchangeRateAttributionSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                Text(BudgetFxProviderAttribution.disclosureSummary)
                    .font(.appBody)
                    .foregroundStyle(AppColors.textPrimary)

                Text(BudgetFxProviderAttribution.frankfurterDetail)
                    .font(.appBody)
                    .foregroundStyle(AppColors.textSecondary)

                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    Link(
                        destination: BudgetFxProviderAttribution.frankfurterHomeURL
                    ) {
                        Label("Frankfurter project", systemImage: "safari")
                            .font(.appBody.weight(.semibold))
                    }
                    .tint(AppColors.appPrimary)
                }

                Text(BudgetFxProviderAttribution.backupDetail)
                    .font(.appBody)
                    .foregroundStyle(AppColors.textSecondary)
                    .padding(.top, AppSpacing.sm)

                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    Link(
                        destination: BudgetFxProviderAttribution.exchangerateHostHomeURL
                    ) {
                        Label("exchangerate.host", systemImage: "safari")
                            .font(.appBody.weight(.semibold))
                    }
                    .tint(AppColors.appPrimary)

                    Link(
                        destination: BudgetFxProviderAttribution.exchangerateHostTermsURL
                    ) {
                        Label("exchangerate.host terms", systemImage: "doc.text")
                            .font(.appCaption.weight(.semibold))
                    }
                    .tint(AppColors.textSecondary)
                }
            }
            .padding(AppSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AppColors.appBackground)
        .navigationTitle("Exchange rate data")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .fontWeight(.semibold)
            }
        }
    }
}

#Preview {
    NavigationStack {
        ExchangeRateAttributionSheet()
    }
}


// =============================================================================
