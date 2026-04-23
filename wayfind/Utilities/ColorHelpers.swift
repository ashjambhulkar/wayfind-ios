//
//  ColorHelpers.swift
//  wayfind
//
//  Created by Ashish Jambhulkar on 4/2/26.
//

import SwiftUI

enum ColorHelpers {
    static func gradientPair(for name: String?) -> (Color, Color) {
        let pairs: [(Color, Color)] = [
            (
                Color(red: 0.76, green: 0.43, blue: 0.32),
                Color(red: 0.95, green: 0.62, blue: 0.42)
            ),
            (
                Color(red: 0.18, green: 0.45, blue: 0.71),
                Color(red: 0.35, green: 0.68, blue: 0.88)
            ),
            (
                Color(red: 0.18, green: 0.49, blue: 0.32),
                Color(red: 0.35, green: 0.65, blue: 0.45)
            ),
            (
                Color(red: 0.93, green: 0.62, blue: 0.22),
                Color(red: 0.98, green: 0.78, blue: 0.45)
            ),
        ]

        let key = name ?? ""
        var hash: UInt64 = 5381
        for byte in key.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        let index = Int(hash % UInt64(pairs.count))
        return pairs[index]
    }
}

