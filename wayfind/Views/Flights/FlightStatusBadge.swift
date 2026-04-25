//
//  FlightStatusBadge.swift
//  wayfind
//
//  Wave 3.3 — pill-shaped status badge that sits next to the flight
//  number on a flight `trip_booking` row in the timeline.
//
//  Visual contract:
//    • Three colour buckets (green / amber / red) keyed off
//      `FlightStatus.tint(...)`.
//    • A pulsing dot for live flights — but only when the OS-level
//      `accessibilityReduceMotion` flag is off, per HIG.
//    • Stale subtitle (e.g. "Updated 35 min ago") when the latest
//      poll is older than the freshness window.
//    • Voice-Over reads the colour, flight number, and primary status
//      reason ("On time", "Delayed 25 min", "Cancelled").
//
//  Pro gating:
//    • If `isProUser == false`, the dot doesn't pulse and tapping the
//      badge calls `onUpsellTap` (router presents the Pro paywall).
//    • Free users still see the LATEST cached status — we don't gate
//      the *value*, just the live-update behaviour. This makes the
//      Pro upsell honest ("upgrade for live updates") instead of
//      paywalling visible information.
//

import SwiftUI

struct FlightStatusBadge: View {
    let status: FlightStatus?
    let isStale: Bool
    let tint: FlightStatus.DisplayState.Tint
    let isProUser: Bool
    var onUpsellTap: (() -> Void)? = nil
    var onTap: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Button(action: handleTap) {
            HStack(spacing: AppSpacing.xs) {
                indicator
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.appSmall.weight(.semibold))
                        .foregroundStyle(textForeground)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(secondaryForeground)
                    }
                }
                if !isProUser {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(secondaryForeground)
                        .accessibilityLabel("Pro feature")
                }
            }
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, 4)
            .background(background, in: Capsule())
            .overlay(Capsule().strokeBorder(borderColor, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .onAppear { startPulseIfNeeded() }
        .onChange(of: pulseShouldRun) { _, shouldRun in
            if shouldRun { startPulseIfNeeded() } else { pulse = false }
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private var indicator: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 8, height: 8)
            .scaleEffect(pulseShouldRun && pulse ? 1.35 : 1.0)
            .opacity(pulseShouldRun && pulse ? 0.55 : 1.0)
            .animation(
                pulseShouldRun ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : .default,
                value: pulse
            )
    }

    // MARK: - Copy

    private var headline: String {
        guard let status else { return "Tap to track" }
        switch status.displayState {
        case .scheduled:
            if let delay = status.delayMinutes, delay >= 5 { return "Delayed \(delay)m" }
            return "On time"
        case .active: return "In flight"
        case .landed: return "Landed"
        case .cancelled: return "Cancelled"
        case .diverted: return "Diverted"
        case .unknown: return "Status unknown"
        }
    }

    private var subtitle: String? {
        guard let status else { return "Free preview" }
        if isStale {
            let minutes = max(1, Int(Date().timeIntervalSince(status.polledAt) / 60))
            return "Updated \(minutes)m ago"
        }
        if let gate = status.gateOrigin, !gate.isEmpty { return "Gate \(gate)" }
        if status.displayState == .landed, let claim = status.baggageClaim { return "Belt \(claim)" }
        return nil
    }

    // MARK: - Colour

    private var dotColor: Color {
        switch tint {
        case .green: return AppColors.appSuccess
        case .amber: return AppColors.appWarning
        case .red:   return AppColors.appError
        case .neutral: return AppColors.textSecondary
        }
    }

    private var background: Color {
        dotColor.opacity(0.12)
    }

    private var borderColor: Color {
        dotColor.opacity(0.35)
    }

    private var textForeground: Color { AppColors.textPrimary }
    private var secondaryForeground: Color { AppColors.textSecondary }

    // MARK: - Pulse

    /// We only pulse when (a) the user is Pro, (b) the flight is
    /// actively in motion, (c) accessibility settings allow it. The
    /// HIG explicitly calls out repeating animations as a Reduce-Motion
    /// trigger.
    private var pulseShouldRun: Bool {
        guard isProUser, !reduceMotion else { return false }
        switch status?.displayState {
        case .active, .scheduled: return true
        default: return false
        }
    }

    private func startPulseIfNeeded() {
        if pulseShouldRun {
            pulse = true
        }
    }

    private func handleTap() {
        if !isProUser, let onUpsellTap {
            onUpsellTap()
        } else if let onTap {
            onTap()
        }
    }

    // MARK: - Accessibility

    private var accessibilityLabel: String {
        guard let status else {
            return isProUser ? "Tap to start tracking this flight" : "Flight tracking is a Pro feature. Tap to learn more."
        }
        let coreLabel: String
        switch status.displayState {
        case .scheduled: coreLabel = (status.delayMinutes ?? 0) >= 5 ? "Delayed \(status.delayMinutes ?? 0) minutes" : "On time"
        case .active:    coreLabel = "In flight"
        case .landed:    coreLabel = "Landed"
        case .cancelled: coreLabel = "Cancelled"
        case .diverted:  coreLabel = "Diverted"
        case .unknown:   coreLabel = "Status unknown"
        }
        let staleSuffix = isStale ? ". Status may be out of date." : ""
        let proSuffix = isProUser ? "" : ". Live updates require Wayfind Pro."
        return "\(status.carrierIata) \(status.flightNumber). \(coreLabel)\(staleSuffix)\(proSuffix)"
    }
}
