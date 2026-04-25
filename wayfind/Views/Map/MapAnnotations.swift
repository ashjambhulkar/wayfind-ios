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

/// Search-result marker — Apple Maps-style red drop pin. The lower-trailing
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
        markerTintColor = .systemRed
        glyphImage = nil
        glyphText = nil
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
        circle.fillColor = UIColor.systemRed.cgColor
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

// MARK: - Route badge (mode + minutes capsule on each polyline)

/// Floating capsule placed at the midpoint of a route polyline that
/// shows the chosen transport mode (walk / drive / transit) and the
/// estimated travel minutes. This is the readability layer for the
/// dashed-vs-dotted-vs-solid line styles — most users will not decode
/// "dotted means walking" without a glyph alongside it.
final class RouteBadgeAnnotation: NSObject, MKAnnotation {
    let id: String              // e.g. "<segmentId>.badge"
    let segmentId: String
    @objc dynamic var coordinate: CLLocationCoordinate2D
    let mode: AppleTravelTimesService.Mode?
    let minutes: Int?
    let dayColor: UIColor

    init(
        segmentId: String,
        coordinate: CLLocationCoordinate2D,
        mode: AppleTravelTimesService.Mode?,
        minutes: Int?,
        dayColor: UIColor
    ) {
        self.id = "\(segmentId).badge"
        self.segmentId = segmentId
        self.coordinate = coordinate
        self.mode = mode
        self.minutes = minutes
        self.dayColor = dayColor
        super.init()
    }

    /// Visual fingerprint for diffing.
    var visualFingerprint: String {
        let lat = String(format: "%.5f", coordinate.latitude)
        let lng = String(format: "%.5f", coordinate.longitude)
        let modeKey = mode?.rawValue ?? "fallback"
        let mins = minutes.map(String.init) ?? "-"
        // Pull RGBA so day-color swaps trigger redraw.
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        dayColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        let colorKey = String(format: "%.2f-%.2f-%.2f-%.2f", r, g, b, a)
        return "\(lat)|\(lng)|\(modeKey)|\(mins)|\(colorKey)"
    }
}

/// Tinted capsule with an SF Symbol + minutes label. Sized to its
/// content so different durations don't shift the layout. Hidden by
/// the coordinator when the map is too zoomed out for the badge to
/// be readable.
final class RouteBadgeAnnotationView: MKAnnotationView {
    static let reuseId = "RouteBadgeAnnotationView"

    private let container = UIView()
    private let stack = UIStackView()
    private let symbol = UIImageView()
    private let label = UILabel()

    override var annotation: MKAnnotation? {
        didSet { configure() }
    }

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        canShowCallout = false
        // Below trip pins so badges never occlude a numbered stop.
        displayPriority = .defaultLow
        // Don't cluster — we want one per leg, always.
        clusteringIdentifier = nil
        // Not interactive: tapping the badge would compete with
        // tapping the pin behind it. Keep it as decoration.
        isUserInteractionEnabled = false
        setupViews()
        configure()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setupViews() {
        container.translatesAutoresizingMaskIntoConstraints = false
        container.layer.cornerRadius = 11
        container.layer.shadowColor = UIColor.black.cgColor
        container.layer.shadowOpacity = 0.20
        container.layer.shadowRadius = 2
        container.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(container)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 3
        container.addSubview(stack)

        symbol.contentMode = .center
        symbol.tintColor = .white
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 10,
            weight: .semibold
        )
        stack.addArrangedSubview(symbol)

        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.adjustsFontForContentSizeCategory = false
        stack.addArrangedSubview(label)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -3),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 7),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -7),
        ])
    }

    private func configure() {
        guard let badge = annotation as? RouteBadgeAnnotation else { return }
        container.backgroundColor = badge.dayColor

        let symbolName: String
        let modeWord: String
        switch badge.mode {
        case .walking:
            symbolName = "figure.walk"
            modeWord = "walking"
        case .driving:
            symbolName = "car.fill"
            modeWord = "driving"
        case .transit:
            symbolName = "tram.fill"
            modeWord = "transit"
        case .none:
            // Haversine fallback — show a generic "directions" glyph
            // and skip the minutes (we don't have a real estimate).
            symbolName = "arrow.triangle.swap"
            modeWord = "estimated"
        }
        symbol.image = UIImage(systemName: symbolName)

        if let minutes = badge.minutes, minutes > 0 {
            label.text = "\(minutes) min"
            label.isHidden = false
            accessibilityLabel = "\(minutes) minute \(modeWord)"
        } else {
            // Don't show "0 min" / nil — collapse to just the symbol.
            label.text = ""
            label.isHidden = true
            accessibilityLabel = "\(modeWord) leg"
        }
        isAccessibilityElement = true
        accessibilityTraits = .staticText

        setNeedsLayout()
        invalidateIntrinsicContentSize()
        // Match the intrinsic size of the stack so MKMapView centers
        // us correctly on the coordinate.
        layoutIfNeeded()
        let target = stack.systemLayoutSizeFitting(
            UIView.layoutFittingCompressedSize
        )
        // Pad for the container insets (3 + 3 / 7 + 7).
        frame.size = CGSize(width: target.width + 14, height: target.height + 6)
        // Anchor by the visual center, not the default top-left.
        centerOffset = .zero
    }
}

// =============================================================================
