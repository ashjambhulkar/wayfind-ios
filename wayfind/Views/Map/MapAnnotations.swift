//
//  MapAnnotations.swift
//  wayfind
//
//  UIKit annotation models and views used by `TripMapKitView`. Three kinds:
//
//    • TripPlaceAnnotation     — numbered day pin (day color + sort order).
//    • BookingAnnotation       — booking diamond (e.g. flight, hotel).
//    • SearchResultAnnotation  — exploratory search hit. Clusters.
//
//  Trip and booking pins MUST NOT cluster — sort-order semantics make
//  adjacent merging meaningless. Only `SearchResultAnnotation` carries a
//  `clusteringIdentifier` so dense category searches collapse into bubbles.
//

import MapKit
import SwiftUI
import UIKit

// MARK: - Annotation models

/// Stable identity for diffing across SwiftUI updates. The id is the place
/// row's UUID string so adding/removing annotations in `updateUIView`
/// doesn't recreate views the user is interacting with.
final class TripPlaceAnnotation: NSObject, MKAnnotation {
    let id: String
    let placeId: UUID
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String?
    let dayNumber: Int
    /// 1-indexed position used as the pin label.
    let sortLabel: Int

    init(place: Place, dayNumber: Int) {
        self.id = place.id.uuidString
        self.placeId = place.id
        self.coordinate = place.coordinate
        self.title = place.name
        self.dayNumber = dayNumber
        self.sortLabel = place.sortOrder + 1
        super.init()
    }

    /// Visual fingerprint for diffing — when this changes, the annotation
    /// view needs to redraw (day color or label changed) but we keep the
    /// same MKAnnotation instance so MKMapView doesn't kill the view.
    var visualFingerprint: String {
        "\(dayNumber)|\(sortLabel)|\(coordinate.latitude)|\(coordinate.longitude)|\(title ?? "")"
    }
}

/// Booking pin (rotated rounded square with a category glyph).
final class BookingAnnotation: NSObject, MKAnnotation {
    let id: String
    let placeId: UUID
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String?
    let bookingCategory: BookingCategory?

    init(place: Place) {
        self.id = place.id.uuidString
        self.placeId = place.id
        self.coordinate = place.coordinate
        self.title = place.name
        self.bookingCategory = place.bookingCategoryEnum
        super.init()
    }

    var visualFingerprint: String {
        "\(bookingCategory?.rawValue ?? "")|\(coordinate.latitude)|\(coordinate.longitude)|\(title ?? "")"
    }
}

/// Search-result pin. Always carries the underlying `MapSearchPreview` so
/// the SwiftUI layer can present the preview sheet without rebuilding it
/// from `MKMapItem`.
final class SearchResultAnnotation: NSObject, MKAnnotation {
    static let clusterId = "search-results"

    let id: String
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String?
    var subtitle: String?
    let isOwnedRow: Bool
    let preview: MapSearchPreview

    init(preview: MapSearchPreview) {
        self.id = preview.id
        self.coordinate = preview.coordinate
        self.title = preview.name
        self.subtitle = preview.subtitle.isEmpty ? nil : preview.subtitle
        self.isOwnedRow = preview.isOwnedRow
        self.preview = preview
        super.init()
    }
}

// MARK: - Annotation views

/// Numbered circle in the day color. Drawn with CALayer + a UILabel for
/// crisp text without re-rendering SwiftUI per pin. No clustering.
final class TripPlaceAnnotationView: MKAnnotationView {
    static let reuseId = "TripPlaceAnnotationView"

    private let circle = CAShapeLayer()
    private let label = UILabel()

    override var annotation: MKAnnotation? {
        didSet { configure() }
    }

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 28, height: 28)
        canShowCallout = false
        // Trip pins MUST NOT cluster — sort order matters.
        clusteringIdentifier = nil
        displayPriority = .required
        setupLayers()
        configure()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setupLayers() {
        circle.frame = bounds
        circle.path = UIBezierPath(ovalIn: bounds).cgPath
        circle.shadowColor = UIColor.black.cgColor
        circle.shadowOpacity = 0.18
        circle.shadowRadius = 2
        circle.shadowOffset = CGSize(width: 0, height: 1)
        layer.addSublayer(circle)

        label.frame = bounds
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 12, weight: .bold)
        label.textColor = .white
        label.adjustsFontForContentSizeCategory = false
        addSubview(label)
    }

    private func configure() {
        guard let pin = annotation as? TripPlaceAnnotation else { return }
        let dayColor = UIColor(AppColors.dayColor(for: pin.dayNumber))
        circle.fillColor = dayColor.cgColor
        label.text = "\(pin.sortLabel)"
        accessibilityLabel = "\(pin.title ?? "Place"), Day \(pin.dayNumber), stop \(pin.sortLabel)"
        isAccessibilityElement = true
    }
}

/// Rotated rounded-square diamond + glyph. No clustering.
final class BookingAnnotationView: MKAnnotationView {
    static let reuseId = "BookingAnnotationView"

    private let diamondContainer = UIView()
    private let diamond = CAShapeLayer()
    private let glyph = UIImageView()

    override var annotation: MKAnnotation? {
        didSet { configure() }
    }

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 28, height: 28)
        canShowCallout = false
        clusteringIdentifier = nil
        displayPriority = .required
        setupLayers()
        configure()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setupLayers() {
        diamondContainer.frame = CGRect(x: 4, y: 4, width: 20, height: 20)
        diamondContainer.transform = CGAffineTransform(rotationAngle: .pi / 4)
        addSubview(diamondContainer)

        diamond.frame = diamondContainer.bounds
        diamond.path = UIBezierPath(
            roundedRect: diamondContainer.bounds,
            cornerRadius: 4
        ).cgPath
        diamond.shadowColor = UIColor.black.cgColor
        diamond.shadowOpacity = 0.18
        diamond.shadowRadius = 2
        diamond.shadowOffset = CGSize(width: 0, height: 1)
        diamondContainer.layer.addSublayer(diamond)

        glyph.frame = bounds
        glyph.contentMode = .center
        glyph.tintColor = .white
        glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        addSubview(glyph)
    }

    private func configure() {
        guard let pin = annotation as? BookingAnnotation else { return }
        let color = pin.bookingCategory?.color ?? AppColors.appPrimary
        diamond.fillColor = UIColor(color).cgColor
        let symbolName = pin.bookingCategory?.sfSymbol ?? "ticket.fill"
        glyph.image = UIImage(systemName: symbolName)
        accessibilityLabel = "Booking, \(pin.title ?? "")"
        isAccessibilityElement = true
    }
}

/// Search-result marker — neutral material drop pin. The lower-trailing
/// corner gets a small accent-colored dot when `isOwnedRow == true` so the
/// user can tell at a glance which results came from a row we already
/// paid to enrich.
final class SearchResultAnnotationView: MKMarkerAnnotationView {
    static let reuseId = "SearchResultAnnotationView"

    private let ownedDot = CAShapeLayer()

    override var annotation: MKAnnotation? {
        didSet { configure() }
    }

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        clusteringIdentifier = SearchResultAnnotation.clusterId
        canShowCallout = false
        animatesWhenAdded = !UIAccessibility.isReduceMotionEnabled
        markerTintColor = .systemOrange
        glyphImage = UIImage(systemName: "magnifyingglass")
        glyphTintColor = .white

        // Owned-row dot, hidden until configure() turns it on.
        let dotSize: CGFloat = 8
        ownedDot.frame = CGRect(
            x: bounds.width - dotSize - 2,
            y: bounds.height - dotSize - 2,
            width: dotSize,
            height: dotSize
        )
        ownedDot.path = UIBezierPath(ovalIn: ownedDot.bounds).cgPath
        ownedDot.fillColor = UIColor(AppColors.appAccent).cgColor
        ownedDot.strokeColor = UIColor.white.cgColor
        ownedDot.lineWidth = 1
        ownedDot.isHidden = true
        layer.addSublayer(ownedDot)

        configure()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func configure() {
        guard let pin = annotation as? SearchResultAnnotation else { return }
        ownedDot.isHidden = !pin.isOwnedRow
        // Re-anchor the dot every layout pass — the marker view's bounds
        // are stable but reuse can put the layer on a freshly-sized view.
        let dotSize: CGFloat = 8
        ownedDot.frame = CGRect(
            x: bounds.width - dotSize - 2,
            y: bounds.height - dotSize - 2,
            width: dotSize,
            height: dotSize
        )
        ownedDot.path = UIBezierPath(ovalIn: ownedDot.bounds).cgPath

        let ownedSuffix = pin.isOwnedRow ? ", saved in this city" : ""
        accessibilityLabel = "Search result: \(pin.title ?? "")\(ownedSuffix)"
        isAccessibilityElement = true
    }
}

/// System cluster bubble with a count and an accessibility label that
/// reads as "12 places" instead of the default "marker".
final class SearchResultClusterView: MKAnnotationView {
    static let reuseId = "SearchResultClusterView"

    private let circle = CAShapeLayer()
    private let label = UILabel()

    override var annotation: MKAnnotation? {
        didSet { configure() }
    }

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 36, height: 36)
        canShowCallout = false
        displayPriority = .required
        setupLayers()
        configure()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setupLayers() {
        circle.frame = bounds
        circle.path = UIBezierPath(ovalIn: bounds).cgPath
        circle.fillColor = UIColor.systemOrange.cgColor
        circle.strokeColor = UIColor.white.cgColor
        circle.lineWidth = 2
        circle.shadowColor = UIColor.black.cgColor
        circle.shadowOpacity = 0.2
        circle.shadowRadius = 3
        circle.shadowOffset = CGSize(width: 0, height: 2)
        layer.addSublayer(circle)

        label.frame = bounds
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 13, weight: .bold)
        label.textColor = .white
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        addSubview(label)
    }

    private func configure() {
        guard let cluster = annotation as? MKClusterAnnotation else { return }
        let count = cluster.memberAnnotations.count
        label.text = "\(count)"
        accessibilityLabel = "\(count) places"
        accessibilityHint = "Double tap to expand cluster"
        isAccessibilityElement = true
    }
}

// =============================================================================
