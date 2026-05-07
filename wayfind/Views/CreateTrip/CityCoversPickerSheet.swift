import PhotosUI
import SwiftUI

/// Bottom sheet that lets the user pick a cover photo from the city's curated
/// Unsplash pool or choose their own photo from the device library.
struct CityCoversPickerSheet: View {
    let destination: String
    let cityImages: [SupabaseManager.CityProfileCoverImage]
    let currentCoverUrl: String?

    /// Called when the user taps a city image tile.
    var onSelectCityImage: (SupabaseManager.CityProfileCoverImage) -> Void
    /// Called when the user picks a photo from their library (raw Data, not yet JPEG-compressed).
    var onSelectUserPhoto: (PhotosPickerItem) -> Void

    @Binding var selectedCityImageId: UUID?
    @Environment(\.dismiss) private var dismiss

    private let columns = [
        GridItem(.flexible(), spacing: AppSpacing.sm),
        GridItem(.flexible(), spacing: AppSpacing.sm),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    if !cityImages.isEmpty {
                        cityPhotosGrid
                    }
                    uploadRow
                }
                .padding(AppSpacing.lg)
            }
            .scrollContentBackground(.hidden)
            .background(AppColors.appBackground)
            .navigationTitle(destination.isEmpty ? "Cover Photo" : destination)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: - City photos grid

    private var cityPhotosGrid: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Photos from \(destination)")
                .font(.appFootnote.weight(.semibold))
                .foregroundStyle(AppColors.textPrimary)

            LazyVGrid(columns: columns, spacing: AppSpacing.sm) {
                ForEach(cityImages) { image in
                    cityImageTile(image)
                }
            }
        }
    }

    private func cityImageTile(_ image: SupabaseManager.CityProfileCoverImage) -> some View {
        let isSelected = selectedCityImageId == image.id
            || (selectedCityImageId == nil && currentCoverUrl == image.imageUrl)

        return Button {
            selectedCityImageId = image.id
            onSelectCityImage(image)
            dismiss()
        } label: {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: URL(string: image.imageUrl)) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    case .empty:
                        Color(AppColors.appSurface)
                            .overlay { ProgressView().controlSize(.small) }
                    case .failure:
                        Color(AppColors.appSurface)
                            .overlay {
                                Image(systemName: "photo")
                                    .foregroundStyle(AppColors.textTertiary)
                            }
                    @unknown default:
                        Color(AppColors.appSurface)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 110)
                .clipped()

                if let name = image.photographerName {
                    Text(name)
                        .font(.appCaption)
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(.horizontal, AppSpacing.xs)
                        .padding(.bottom, AppSpacing.xs)
                        .lineLimit(1)
                }

                if isSelected {
                    Color.black.opacity(0.25)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(AppSpacing.xs)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium))
            .overlay(
                RoundedRectangle(cornerRadius: AppCornerRadius.medium)
                    .strokeBorder(
                        isSelected ? AppColors.appPrimary : Color.clear,
                        lineWidth: 2.5
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isSelected
                ? String(localized: "Selected: photo by \(image.photographerName ?? "Unsplash")")
                : String(localized: "Photo by \(image.photographerName ?? "Unsplash")")
        )
    }

    // MARK: - Upload from library

    private var uploadRow: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Your Photo")
                .font(.appFootnote.weight(.semibold))
                .foregroundStyle(AppColors.textPrimary)

            PhotosPicker(
                selection: Binding(
                    get: { nil },
                    set: { item in
                        guard let item else { return }
                        selectedCityImageId = nil
                        onSelectUserPhoto(item)
                        dismiss()
                    }
                ),
                matching: .images
            ) {
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.appBody)
                        .foregroundStyle(AppColors.appPrimary)
                        .frame(width: 32, height: 32)
                        .background(AppColors.appPrimary.opacity(0.1), in: RoundedRectangle(cornerRadius: AppCornerRadius.small))

                    Text("Choose from Photos")
                        .font(.appBody)
                        .foregroundStyle(AppColors.textPrimary)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.appFootnote.weight(.semibold))
                        .foregroundStyle(AppColors.textTertiary)
                }
                .padding(AppSpacing.md)
                .background(AppColors.appSurface, in: RoundedRectangle(cornerRadius: AppCornerRadius.medium))
            }
            .buttonStyle(.plain)
        }
    }
}

#if DEBUG
private extension SupabaseManager.CityProfileCoverImage {
    static func preview(id: UUID = UUID(), url: String, photographer: String) -> Self {
        SupabaseManager.CityProfileCoverImage(
            id: id,
            imageUrl: url,
            photographerName: photographer,
            photographerUrl: nil,
            photoPageUrl: nil
        )
    }
}

#Preview("City covers sheet") {
    CityCoversPickerSheet(
        destination: "Tokyo",
        cityImages: [
            .preview(url: "https://images.unsplash.com/photo-1540959733332-eab4deabeeaf?w=400", photographer: "Jezael Melgoza"),
            .preview(url: "https://images.unsplash.com/photo-1536098561742-ca998e48cbcc?w=400", photographer: "Su San Lee"),
            .preview(url: "https://images.unsplash.com/photo-1503899036084-c55cdd92da26?w=400", photographer: "Victoriano Izquierdo"),
            .preview(url: "https://images.unsplash.com/photo-1524413840807-0c3cb6fa808d?w=400", photographer: "Sorasak"),
        ],
        currentCoverUrl: nil,
        onSelectCityImage: { _ in },
        onSelectUserPhoto: { _ in },
        selectedCityImageId: .constant(nil)
    )
}
#endif
