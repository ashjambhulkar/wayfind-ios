import SwiftUI

struct TimelinePlaceCardView: View {
    let place: Place
    let dayNumber: Int

    var onEdit: () -> Void = {}
    var onMoveToDay: () -> Void = {}
    var onMoveToIdeas: () -> Void = {}
    var onDelete: () -> Void = {}

    private var familyColor: Color {
        place.categoryEnum.color
    }

    private var subtitleParts: [String] {
        var parts: [String] = []
        if let dur = durationLabel(start: place.startTime, end: place.endTime) {
            parts.append(dur)
        }
        if let area = neighborhood(from: place.address) {
            parts.append(area)
        }
        parts.append(place.categoryEnum.label)
        return parts
    }

    var body: some View {
        HStack(alignment: .center, spacing: AppSpacing.xs) {
            leadingMarker
            cardSurface
        }
        .contextMenu {
            Button("Edit", action: onEdit)
            Button("Move to Day", action: onMoveToDay)
            if dayNumber != 0 {
                Button("Move to Ideas", action: onMoveToIdeas)
            }
            Button("Delete", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Leading marker

    @ViewBuilder
    private var leadingMarker: some View {
        if let start = place.startTime {
            TimePinView(time: start, tint: familyColor)
        } else {
            UnscheduledMarkerView(tint: familyColor)
        }
    }

    // MARK: - Card surface

    private var cardSurface: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(familyColor)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(place.name)
                    .font(.cardTitle)
                    .foregroundStyle(AppColors.textPrimary)

                Text(subtitleParts.joined(separator: " · "))
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
            }
            .padding(AppSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AppColors.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
        .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 2)
    }

    // MARK: - Accessibility

    private var accessibilityDescription: String {
        var pieces = ["\(place.categoryEnum.label): \(place.name)"]
        if let start = place.startTime {
            if let end = place.endTime {
                pieces.append("\(start.timeFormatted) to \(end.timeFormatted)")
            } else {
                pieces.append(start.timeFormatted)
            }
        }
        if let area = neighborhood(from: place.address) {
            pieces.append("in \(area)")
        }
        return pieces.joined(separator: ", ")
    }
}

// MARK: - Time pin (Apple-Maps callout balloon)

/// Compact rounded balloon with a right-pointing tail, evoking an Apple Maps
/// callout. Renders the start time as a single-line 24-hour `HH:mm` glyph so
/// every pin in a day is the same width — a clean leading column of times.
private struct TimePinView: View {
    let time: Date
    let tint: Color

    private static let tailSize: CGFloat = 5
    private static let cornerRadius: CGFloat = 8

    var body: some View {
        Text(hourMinuteString(time))
            .font(.appSmall.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(AppColors.textPrimary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.leading, 8)
            .padding(.trailing, 8 + Self.tailSize)
            .padding(.vertical, 5)
            .background(
                BalloonShape(tailSize: Self.tailSize, cornerRadius: Self.cornerRadius)
                    .fill(tint.opacity(0.16))
            )
            .overlay(
                BalloonShape(tailSize: Self.tailSize, cornerRadius: Self.cornerRadius)
                    .strokeBorder(tint.opacity(0.4), lineWidth: 0.6)
            )
    }
}

/// Quiet anchor for stops with no scheduled time — small family-tinted dot.
private struct UnscheduledMarkerView: View {
    let tint: Color

    var body: some View {
        Circle()
            .fill(tint.opacity(0.55))
            .frame(width: 8, height: 8)
            .padding(.horizontal, 14)
    }
}

/// Rounded-rectangle balloon with a small triangular tail centered on the
/// trailing edge — like an iMessage bubble pointing right into the card.
private struct BalloonShape: InsettableShape {
    var tailSize: CGFloat
    var cornerRadius: CGFloat
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let bodyRect = CGRect(
            x: r.minX,
            y: r.minY,
            width: max(0, r.width - tailSize),
            height: r.height
        )
        var path = Path(roundedRect: bodyRect, cornerRadius: cornerRadius, style: .continuous)

        let tipY = bodyRect.midY
        path.move(to: CGPoint(x: bodyRect.maxX, y: tipY - tailSize))
        path.addLine(to: CGPoint(x: bodyRect.maxX + tailSize, y: tipY))
        path.addLine(to: CGPoint(x: bodyRect.maxX, y: tipY + tailSize))
        path.closeSubpath()

        return path
    }

    func inset(by amount: CGFloat) -> some InsettableShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

// MARK: - Helpers

/// Returns a 24-hour `HH:mm` time string with leading zeros so every pin in a
/// timeline column has identical width.
///
/// Locale-independent on purpose — the visual timeline reads better with a
/// single, predictable format. The locale-aware string lives in the
/// accessibility label via `Date.timeFormatted`.
private func hourMinuteString(_ date: Date) -> String {
    let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
    let hour = comps.hour ?? 0
    let minute = comps.minute ?? 0
    return String(format: "%02d:%02d", hour, minute)
}

/// Human duration string like "1h 30m" / "45m" / "2h".
/// Defaults to a 60-minute window when `endTime` is missing.
private func durationLabel(start: Date?, end: Date?) -> String? {
    guard let start else { return nil }
    let endResolved = end ?? start.addingTimeInterval(60 * 60)
    let minutes = max(0, Int(endResolved.timeIntervalSince(start) / 60))
    if minutes == 0 { return nil }
    let h = minutes / 60
    let m = minutes % 60
    if h > 0 && m > 0 { return "\(h)h \(m)m" }
    if h > 0 { return "\(h)h" }
    return "\(m)m"
}

/// Returns a likely neighborhood from a free-form address by splitting on `,` and `-`
/// and grabbing the second-to-last non-empty segment.
///
/// - "1 Sheikh Mohammed Bin Rashid Blvd, Downtown Dubai, Dubai, UAE" → "Dubai"
/// - "Burj Khalifa - Downtown Dubai - Dubai - UAE" → "Dubai"
/// - "Tokyo" → nil
private func neighborhood(from address: String?) -> String? {
    guard let address, !address.isEmpty else { return nil }
    let parts = address
        .components(separatedBy: CharacterSet(charactersIn: ",-"))
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    guard parts.count >= 2 else { return nil }
    return parts[parts.count - 2]
}


// =============================================================================
