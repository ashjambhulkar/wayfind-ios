import SwiftUI

struct PlaceSearchResultsView: View {
    let results: [(name: String, address: String, category: String)]
    var onSelect: (String, String, String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(results.enumerated()), id: \.offset) { index, row in
                PlaceSearchResultRowView(
                    name: row.name,
                    address: row.address,
                    category: row.category,
                    onAdd: { onSelect(row.name, row.address, row.category) }
                )

                if index < results.count - 1 {
                    Divider()
                        .background(AppColors.appDivider)
                }
            }
        }
    }
}

private struct PlaceSearchResultRowView: View {
    let name: String
    let address: String
    let category: String
    let onAdd: () -> Void

    @State private var addButtonScale: CGFloat = 1

    private var categorySymbol: String {
        let trimmed = category.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = PlaceCategory(rawValue: trimmed) {
            return match.sfSymbol
        }
        let normalized = trimmed
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        switch normalized {
        case "attraction", "sightseeing", "landmark": return PlaceCategory.attraction.sfSymbol
        case "restaurant", "food", "dining": return PlaceCategory.restaurant.sfSymbol
        case "hotel", "lodging", "accommodation": return PlaceCategory.hotel.sfSymbol
        case "transport", "transit", "transportation": return PlaceCategory.transport.sfSymbol
        case "shopping", "shop", "retail": return PlaceCategory.shopping.sfSymbol
        case "nightlife", "bar", "club": return PlaceCategory.nightlife.sfSymbol
        case "nature", "park", "outdoor": return PlaceCategory.nature.sfSymbol
        default: return PlaceCategory.custom.sfSymbol
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            Image(systemName: categorySymbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppColors.textSecondary)
                .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(name)
                    .font(.cardTitle)
                    .foregroundStyle(AppColors.textPrimary)

                Text(address)
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            Button {
                HapticManager.medium()
                withAnimation(AppSpring.snappy) {
                    addButtonScale = 0.88
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    withAnimation(AppSpring.bouncy) {
                        addButtonScale = 1
                    }
                }
                onAdd()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(AppColors.appPrimary)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .scaleEffect(addButtonScale)
        }
        .padding(.vertical, AppSpacing.sm)
    }
}