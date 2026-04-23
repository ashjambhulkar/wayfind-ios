import SwiftUI

struct PlaceholderGradientView: View {
    let destinationName: String

    private static let pairs: [(Color, Color)] = [
        (Color(red: 194.0 / 255.0, green: 111.0 / 255.0, blue: 75.0 / 255.0), Color(red: 232.0 / 255.0, green: 168.0 / 255.0, blue: 124.0 / 255.0)),
        (Color(red: 74.0 / 255.0, green: 144.0 / 255.0, blue: 217.0 / 255.0), Color(red: 147.0 / 255.0, green: 197.0 / 255.0, blue: 253.0 / 255.0)),
        (Color(red: 5.0 / 255.0, green: 150.0 / 255.0, blue: 105.0 / 255.0), Color(red: 110.0 / 255.0, green: 231.0 / 255.0, blue: 183.0 / 255.0)),
        (Color(red: 217.0 / 255.0, green: 119.0 / 255.0, blue: 6.0 / 255.0), Color(red: 252.0 / 255.0, green: 211.0 / 255.0, blue: 77.0 / 255.0)),
    ]

    private var pair: (Color, Color) {
        var hash: UInt64 = 5381
        for byte in destinationName.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        let index = Int(hash % 4)
        return Self.pairs[index]
    }

    var body: some View {
        LinearGradient(
            colors: [pair.0, pair.1],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(alignment: .bottomTrailing) {
            Text("Wayfind")
                .font(.appSmall)
                .foregroundStyle(Color.white.opacity(0.3))
                .padding(AppSpacing.md)
        }
    }
}

