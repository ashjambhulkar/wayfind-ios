import SwiftUI

struct NotificationsView: View {
    var body: some View {
        ContentUnavailableView(
            "No Notifications",
            systemImage: "bell.slash",
            description: Text("You're all caught up. Notifications about your trips will appear here.")
        )
        .background(AppColors.appBackground)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }
}
