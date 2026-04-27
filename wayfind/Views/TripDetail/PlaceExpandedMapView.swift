import MapKit
import SwiftUI

struct PlaceExpandedMapView: View {
    let place: Place
    let categorySymbol: String
    let initialPosition: MapCameraPosition

    @Environment(\.dismiss) private var dismiss
    @State private var position: MapCameraPosition = .automatic

    private var coordinate: CLLocationCoordinate2D? {
        guard let lat = place.lat, let lng = place.lng, !lat.isNaN, !lng.isNaN else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $position, interactionModes: [.pan, .zoom, .pitch, .rotate]) {
                if let coordinate {
                    Marker(place.name, systemImage: categorySymbol, coordinate: coordinate)
                        .tint(AppColors.appPrimary)
                }
            }
            .mapStyle(.standard(elevation: .realistic, emphasis: .muted))
            .ignoresSafeArea()
            .onAppear {
                if let coordinate {
                    position = .camera(
                        MapCamera(
                            centerCoordinate: coordinate,
                            distance: 900,
                            heading: 0,
                            pitch: 60
                        )
                    )
                } else {
                    position = initialPosition
                }
            }

            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 38, height: 38)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Close"))

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
    }
}
