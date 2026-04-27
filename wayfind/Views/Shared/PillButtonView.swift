import SwiftUI

// MARK: - Trip tool icon accents (Checklist / Notes / Documents)

/// Distinct, readable icon colors for the trip detail tool strip. Capsule chrome stays neutral; only the SF Symbol uses these tints.
enum TripToolPillIconAccent {
    /// Deep teal — progress / tasks.
    static let checklist = Color(
        light: Color(red: 0.07, green: 0.52, blue: 0.46),
        dark: Color(red: 0.35, green: 0.88, blue: 0.78)
    )
    /// Indigo — writing / notes.
    static let notes = Color(
        light: Color(red: 0.39, green: 0.40, blue: 0.86),
        dark: Color(red: 0.63, green: 0.64, blue: 1.0)
    )
    /// Warm amber — documents / files.
    static let documents = Color(
        light: Color(red: 0.86, green: 0.42, blue: 0.16),
        dark: Color(red: 0.98, green: 0.64, blue: 0.35)
    )
}

// MARK: - Trip tool capsule metrics (aligned with `TripMembersInviteButton`)

private enum TripToolCapsuleMetrics {
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 8
    static let contentSpacing: CGFloat = 5
    static let iconFontSize: CGFloat = 14
}

// MARK: - Trip tool pill button style

/// Press feedback aligned with compact trip-tool capsules (Share, Checklist, …).
struct TripToolPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.32, dampingFraction: 0.78), value: configuration.isPressed)
    }
}

// MARK: - Pill button

struct PillButtonView: View {
    let sfSymbol: String
    let label: String
    /// Optional suffix after the label (e.g. `" 2/10"` for checklist progress, `" 3"` for note count).
    var trailingDetail: String?
    var badgeCount: Int?
    var showPulseDot: Bool = false
    var isActive: Bool = true
    /// When set, only the leading SF Symbol uses this color; label stays neutral.
    var iconTint: Color? = nil
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var showComingSoon = false
    @State private var pulsing = false

    var body: some View {
        Group {
            if isActive {
                Button(action: action) {
                    pillChrome
                }
                .buttonStyle(TripToolPillButtonStyle())
            } else {
                Button {
                    showComingSoon = true
                } label: {
                    pillChrome
                }
                .buttonStyle(TripToolPillButtonStyle())
                .popover(isPresented: $showComingSoon) {
                    Text("Coming Soon")
                        .font(.appBody)
                        .padding(AppSpacing.md)
                }
            }
        }
    }

    private var pillChrome: some View {
        HStack(spacing: TripToolCapsuleMetrics.contentSpacing) {
            Image(systemName: sfSymbol)
                .font(.system(size: TripToolCapsuleMetrics.iconFontSize, weight: .semibold))
                .imageScale(.medium)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(iconForeground)

            pillTitleText

            if let badgeCount {
                Text("\(badgeCount)")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(isActive ? AppColors.textSecondary : AppColors.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(AppColors.appDivider.opacity(isActive ? 1 : 0.7))
                    )
            }

            if showPulseDot {
                Circle()
                    .fill(isActive ? (iconTint ?? AppColors.appPrimary) : AppColors.textTertiary)
                    .frame(width: 6, height: 6)
                    .scaleEffect(pulsing ? 1.5 : 1.0)
                    .opacity(pulsing ? 0.6 : 1.0)
                    .onAppear {
                        guard !accessibilityReduceMotion else { return }
                        withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                            pulsing = true
                        }
                    }
            }
        }
        .padding(.horizontal, TripToolCapsuleMetrics.horizontalPadding)
        .padding(.vertical, TripToolCapsuleMetrics.verticalPadding)
        .background(pillBackground)
        .overlay(pillStroke)
        .clipShape(Capsule(style: .continuous))
        .contentShape(Capsule())
        .accessibilityLabel(
            "\(label)\(trailingDetail.map { "\($0)" } ?? "")\(badgeCount.map { ", \($0) items" } ?? "")"
        )
    }

    private var iconForeground: Color {
        guard isActive else { return AppColors.textTertiary }
        return iconTint ?? AppColors.textPrimary
    }

    @ViewBuilder
    private var pillTitleText: some View {
        let detail = trailingDetail ?? ""
        let titleTint = isActive ? AppColors.textPrimary : AppColors.textTertiary
        if detail.isEmpty {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(titleTint)
        } else {
            (Text(label)
                .fontWeight(.semibold)
                .foregroundStyle(titleTint)
                + Text(detail)
                .fontWeight(.regular)
                .foregroundStyle(isActive ? AppColors.textSecondary : AppColors.textTertiary))
                .font(.subheadline)
        }
    }

    private var pillBackground: some View {
        Group {
            if isActive {
                AppColors.appSurface
            } else {
                AppColors.appSurface.opacity(0.55)
            }
        }
    }

    private var pillStroke: some View {
        Capsule(style: .continuous)
            .strokeBorder(
                isActive ? AppColors.appDivider : AppColors.appDivider.opacity(0.65),
                lineWidth: 0.5
            )
    }
}


// =============================================================================


#if DEBUG
#Preview("Pill buttons") {
    ZStack {
        AppColors.appBackground
        VStack(spacing: 12) {
            PillButtonView(sfSymbol: "map", label: "Map", action: {})
            PillButtonView(sfSymbol: "ticket", label: "Bookings", badgeCount: 3, action: {})
            PillButtonView(sfSymbol: "checklist", label: "Checklist", trailingDetail: " 4/10", action: {})
            PillButtonView(sfSymbol: "note.text", label: "Notes", showPulseDot: true, action: {})
            PillButtonView(sfSymbol: "clock", label: "Coming soon", isActive: false, action: {})
        }
        .padding()
    }
}
#endif
