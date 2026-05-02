import SwiftUI

/// Placeholder for future trip **Organize** flow (reorder, group, batch edit). Wired from the trip detail floating bar.
struct TripOrganizePlaceholderView: View {
    let trip: Trip

    var body: some View {
        ContentUnavailableView {
            Label("Organize", systemImage: "square.grid.2x2")
        } description: {
            Text("Tools to arrange and manage \(trip.title) will go here. This is a placeholder.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.appBackground)
    }
}

// =============================================================================


#if DEBUG
#Preview("Organize placeholder") {
    TripOrganizePlaceholderView(trip: .preview)
        .background(AppColors.appBackground)
}
#endif
