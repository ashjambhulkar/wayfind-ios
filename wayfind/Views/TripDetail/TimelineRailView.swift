import SwiftUI

enum TimelineRailView {
    static func railDot(isBooking: Bool, color: Color) -> some View {
        Group {
            if isBooking {
                Rectangle()
                    .fill(color)
                    .frame(width: 10, height: 10)
                    .rotationEffect(.degrees(45))
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)
            }
        }
    }

    static func railLine() -> some View {
        Rectangle()
            .fill(AppColors.appDivider)
            .frame(width: 2)
    }

    static func railConnector() -> some View {
        Rectangle()
            .fill(AppColors.appDivider)
            .frame(width: 12, height: 2)
    }
}
