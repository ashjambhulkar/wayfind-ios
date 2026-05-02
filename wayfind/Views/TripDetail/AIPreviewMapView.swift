import MapKit
import SwiftUI

/// Compact map preview used inside `AIPlanWizardSheet`.
///
/// Renders the AI-proposed stops as numbered day-colored annotations and
/// connects them with a thin polyline so the route shape reads at a
/// glance. Camera auto-fits the bounding region of the cards on first
/// render and after the cards array changes (regenerate). Pan/zoom is
/// allowed so the user can inspect anything that's clustered together.
///
/// `selectedCardId` is two-way bound: tapping a pin highlights the
/// matching card row in the parent sheet, and tapping a card row
/// re-centers the map on that pin.
struct AIPreviewMapView: View {
    let cards: [ActivityPreviewCard]
    let dayColor: Color
    @Binding var selectedCardId: UUID?

    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $position) {
            ForEach(Array(plottableCards.enumerated()), id: \.element.id) { index, card in
                let coord = CLLocationCoordinate2D(
                    latitude: card.latitude!,
                    longitude: card.longitude!
                )
                Annotation(card.name, coordinate: coord, anchor: .bottom) {
                    pinView(index: index + 1, isSelected: selectedCardId == card.id)
                        .onTapGesture {
                            HapticManager.selection()
                            selectedCardId = card.id
                        }
                }
            }

            if routeCoordinates.count >= 2 {
                MapPolyline(coordinates: routeCoordinates)
                    .stroke(dayColor.opacity(0.55), lineWidth: 3)
            }
        }
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .frame(height: 240)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: AppCornerRadius.medium)
                .strokeBorder(AppColors.appDivider, lineWidth: 0.5)
        )
        .padding(.horizontal, AppSpacing.lg)
        .onAppear { recenter() }
        .onChange(of: cards.map(\.id)) { _, _ in
            recenter()
        }
        .onChange(of: selectedCardId) { _, newId in
            guard let newId, let card = plottableCards.first(where: { $0.id == newId }),
                  let lat = card.latitude, let lng = card.longitude else { return }
            withAnimation(.easeInOut(duration: 0.35)) {
                position = .region(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                    span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)
                ))
            }
        }
    }

    // MARK: - Helpers

    /// Cards that the model resolved to lat/lng. Anything missing
    /// coordinates is silently dropped from the map (it still appears in
    /// the strip below) so the camera fit doesn't get pulled to (0, 0).
    private var plottableCards: [ActivityPreviewCard] {
        cards.filter { $0.latitude != nil && $0.longitude != nil }
    }

    private var routeCoordinates: [CLLocationCoordinate2D] {
        plottableCards.map { CLLocationCoordinate2D(latitude: $0.latitude!, longitude: $0.longitude!) }
    }

    private func recenter() {
        let coords = routeCoordinates
        guard !coords.isEmpty else { return }
        if coords.count == 1 {
            position = .region(MKCoordinateRegion(
                center: coords[0],
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            ))
            return
        }
        let lats = coords.map(\.latitude)
        let lngs = coords.map(\.longitude)
        let minLat = lats.min()!, maxLat = lats.max()!
        let minLng = lngs.min()!, maxLng = lngs.max()!
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLng + maxLng) / 2
        )
        // Padded span so pins aren't kissed by the map edges.
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.4, 0.01),
            longitudeDelta: max((maxLng - minLng) * 1.4, 0.01)
        )
        position = .region(MKCoordinateRegion(center: center, span: span))
    }

    private func pinView(index: Int, isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .fill(dayColor)
                .frame(width: isSelected ? 36 : 28, height: isSelected ? 36 : 28)
                .shadow(color: .black.opacity(0.18), radius: isSelected ? 6 : 3, x: 0, y: 2)
            Text("\(index)")
                .font(.system(size: isSelected ? 14 : 12, weight: .bold))
                .foregroundStyle(.white)
        }
        .overlay(
            Circle()
                .strokeBorder(.white, lineWidth: isSelected ? 3 : 2)
        )
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isSelected)
    }
}
