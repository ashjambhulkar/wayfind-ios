import MapKit
import SwiftUI

/// A drop-in `Form` row that replaces a plain `LabeledContent + TextField` for
/// address and location fields. While the user types, `MKLocalSearchCompleter`
/// (via the existing `AppleMapSearchService`) surfaces up to 4 inline suggestion
/// rows inside the same `Section`. Tapping a suggestion fills the text field and
/// resolves coordinates via `MKLocalSearch`.
///
/// Usage inside a `Section`:
/// ```swift
/// Section("Stay") {
///     AddressAutocompleteRow(
///         label: String(localized: "Address"),
///         placeholder: String(localized: "Street, city"),
///         text: $address,
///         latBinding: $addressLat,
///         lngBinding: $addressLng
///     )
/// }
/// ```
///
/// Design notes:
/// - `latBinding`/`lngBinding` are optional. Pass them only when coordinates
///   should be captured (hotel, restaurant, activity, car pickup, transport
///   departure). Leave nil for fields that are text-only (drop-off, arrival).
/// - Coordinates are nilled out on every manual keyboard change to prevent
///   a stale coordinate surviving after the user edits the auto-filled text.
/// - Suggestions clear with a 150 ms delay after focus loss so a tap on a
///   suggestion row is processed before the list disappears.
struct AddressAutocompleteRow: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var latBinding: Binding<Double?>? = nil
    var lngBinding: Binding<Double?>? = nil

    @State private var searchService = AppleMapSearchService()
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            LabeledContent(label) {
                TextField(placeholder, text: $text)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .focused($isFocused)
                    .onChange(of: text) { _, newValue in
                        // Any keyboard change invalidates a previously resolved coordinate.
                        latBinding?.wrappedValue = nil
                        lngBinding?.wrappedValue = nil
                        searchService.update(query: newValue, region: nil)
                    }
            }

            ForEach(Array(searchService.suggestions.prefix(4))) { suggestion in
                Button {
                    select(suggestion)
                } label: {
                    HStack(spacing: AppSpacing.sm) {
                        Image(systemName: "mappin")
                            .font(.appCaption)
                            .foregroundStyle(AppColors.textSecondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title)
                                .font(.appBody)
                                .foregroundStyle(AppColors.textPrimary)
                            if !suggestion.subtitle.isEmpty {
                                Text(suggestion.subtitle)
                                    .font(.appCaption)
                                    .foregroundStyle(AppColors.textSecondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .onChange(of: isFocused) { _, focused in
            guard !focused else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                searchService.clear()
            }
        }
    }

    private func select(_ suggestion: AppleMapSuggestion) {
        searchService.clear()
        isFocused = false
        text = suggestion.subtitle.isEmpty
            ? suggestion.title
            : "\(suggestion.title), \(suggestion.subtitle)"

        guard latBinding != nil || lngBinding != nil else { return }
        Task {
            if let resolved = await searchService.resolve(suggestion, in: nil) {
                latBinding?.wrappedValue = resolved.coordinate.latitude
                lngBinding?.wrappedValue = resolved.coordinate.longitude
            }
        }
    }
}
