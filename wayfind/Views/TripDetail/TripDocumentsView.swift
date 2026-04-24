import SwiftUI

/// Placeholder for the trip documents screen. Future iterations will let
/// travelers attach PDFs (boarding passes, hotel confirmations, visa letters,
/// insurance cards) and link to web URLs so everything for a trip lives in
/// one place.
struct TripDocumentsView: View {
    let trip: Trip

    var body: some View {
        VStack(spacing: AppSpacing.xl) {
            Spacer()

            Image(systemName: "doc.text.below.ecg")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(AppColors.appPrimary.opacity(0.7))

            VStack(spacing: AppSpacing.sm) {
                Text("Documents")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.primary)

                Text("Attach boarding passes, hotel\nconfirmations, visas and more.")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                // TODO: present document picker
            } label: {
                Label("Add Document", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, AppSpacing.xl)
                    .padding(.vertical, AppSpacing.md)
                    .background(AppColors.appPrimary)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }

            Spacer()
        }
        .padding(.horizontal, AppSpacing.lg)
        .navigationTitle("Documents")
        .navigationBarTitleDisplayMode(.inline)
    }
}


// =============================================================================
