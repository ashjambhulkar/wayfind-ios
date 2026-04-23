import SwiftUI

/// Placeholder for future budget features; see trip detail plan (native TabView).
struct TripBudgetTabView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Budget", systemImage: "dollarsign.circle")
        } description: {
            Text("A budget for this trip is coming soon. You’ll be able to track spending by category here.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.appBackground)
    }
}
