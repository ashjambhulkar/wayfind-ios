//
//  AirlineBranding.swift
//  wayfind
//

import SwiftUI

/// Centralized Kiwi.com public CDN URLs for airline square logos — no API key.
/// Docs / pattern (Tequila/Skypicker ecosystem): `GET https://images.kiwi.com/airlines/<size>/<IATA>.png`
/// Example: `https://images.kiwi.com/airlines/64/UA.png` (64px; other sizes supported).
enum AirlineLogoURL {
    /// Default fetch size aligned with ~30pt UI; Kiwi serves multiple sizes without auth.
    private static let defaultPixelSize = 64

    static func logoURL(carrierCode: String?, pixelSize: Int = defaultPixelSize) -> URL? {
        guard let code = normalizedTwoLetterIATAPrefix(carrierCode) else { return nil }
        return URL(string: "https://images.kiwi.com/airlines/\(pixelSize)/\(code).png")
    }

    /// Kiwi expects a 2-character designator; we strip noise and prefix (e.g. `U2`, `UAL` → first two glyphs).
    /// Three-letter ICAO stored as IATA can resolve to an incorrect Kiwi asset — rare; logo may be generic upstream.
    static func normalizedTwoLetterIATAPrefix(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let compact = trimmed.filter { $0.isLetter || $0.isNumber }
        guard compact.count >= 2 else { return nil }
        return String(compact.prefix(2))
    }
}

// MARK: - Logo view

struct AirlineLogoView: View {
    let carrierIATA: String?
    /// Shown alongside the logo when no URL resolves (VoiceOver grouping).
    var airlineNameFallback: String
    /// Visual treatment for contrasting backgrounds (booking pass footer vs timeline surface).
    var variant: Variant

    private static let logoDimension: CGFloat = 30
    /// Same footprint as timeline activity / booking solid leading tiles (`TimelineCardLeadingIconMetrics`).
    private static let timelineDayLeadingSide: CGFloat = TimelineCardLeadingIconMetrics.solidSquareSideLength

    enum Variant {
        case bookingPassFooter
        case timelineCard
        /// Rounded square matching timeline activity / booking leading `MapStyleIcon` tiles; full-bleed logo when available.
        case timelineDayLeading
    }

    var body: some View {
        switch variant {
        case .timelineDayLeading:
            timelineDayLeadingBody
        case .bookingPassFooter, .timelineCard:
            compactMarkBody
        }
    }

    private var compactMarkBody: some View {
        Group {
            if let url = AirlineLogoURL.logoURL(carrierCode: carrierIATA) {
                AsyncImage(url: url, transaction: .init(animation: .easeInOut(duration: 0.15))) { phase in
                    switch phase {
                    case .empty:
                        placeholder
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .transition(.opacity)
                    case .failure:
                        fallbackGlyph
                    @unknown default:
                        fallbackGlyph
                    }
                }
            } else {
                fallbackGlyph
            }
        }
        .frame(width: Self.logoDimension, height: Self.logoDimension)
        .padding(variant == .timelineCard ? 1 : 0)
        .background(backgroundForVariant, in: RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous))
        .overlay {
            switch variant {
            case .bookingPassFooter:
                RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.28), .white.opacity(0.10)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            case .timelineCard:
                RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous)
                    .strokeBorder(AppColors.appDivider.opacity(0.75), lineWidth: 0.5)
            case .timelineDayLeading:
                EmptyView()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(true)
    }

    private var timelineDayLeadingBody: some View {
        ZStack {
            if let url = AirlineLogoURL.logoURL(carrierCode: carrierIATA, pixelSize: 128) {
                AsyncImage(url: url, transaction: .init(animation: .easeInOut(duration: 0.15))) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .controlSize(.regular)
                            .tint(AppColors.iconOnColoredSurface)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(BookingCategory.flight.color)
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .transition(.opacity)
                    case .failure:
                        timelineDayLeadingGlyphFallback
                    @unknown default:
                        timelineDayLeadingGlyphFallback
                    }
                }
            } else {
                timelineDayLeadingGlyphFallback
            }
        }
        .frame(width: Self.timelineDayLeadingSide, height: Self.timelineDayLeadingSide)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(true)
    }

    private var timelineDayLeadingGlyphFallback: some View {
        Image(systemName: "airplane")
            .font(.sectionHeader.weight(.semibold))
            .foregroundStyle(AppColors.iconOnColoredSurface)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BookingCategory.flight.color)
    }

    @ViewBuilder
    private var placeholder: some View {
        ProgressView()
            .controlSize(.small)
            .tint(placeholderTint)
            .scaleEffect(0.85)
    }

    @ViewBuilder
    private var fallbackGlyph: some View {
        switch variant {
        case .bookingPassFooter:
            Image(systemName: "airplane")
                .font(.appCaption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.92))
        case .timelineCard:
            Image(systemName: "airplane")
                .font(.appCaption.weight(.semibold))
                .foregroundStyle(BookingCategory.flight.color.opacity(0.95))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .timelineDayLeading:
            timelineDayLeadingGlyphFallback
        }
    }

    /// Full-color airline artwork on Kiwi CDN; keep a subtle plate so tails read on varied maps.
    private var backgroundForVariant: some ShapeStyle {
        switch variant {
        case .bookingPassFooter:
            Color.white.opacity(0.16)
        case .timelineCard:
            AppColors.textPrimary.opacity(0.04)
        case .timelineDayLeading:
            BookingCategory.flight.color
        }
    }

    private var placeholderTint: Color {
        switch variant {
        case .bookingPassFooter:
            return .white.opacity(0.75)
        case .timelineCard:
            return AppColors.textSecondary.opacity(0.85)
        case .timelineDayLeading:
            return AppColors.iconOnColoredSurface.opacity(0.9)
        }
    }
}
