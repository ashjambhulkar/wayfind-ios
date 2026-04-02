//
//  AppAnimations.swift
//  wayfind
//
//  Created by Ashish Jambhulkar on 4/2/26.
//

import SwiftUI

enum AppSpring {
    static var snappy: Animation {
        .spring(response: 0.2, dampingFraction: 0.7)
    }

    static var smooth: Animation {
        .spring(response: 0.35, dampingFraction: 0.8)
    }

    static var bouncy: Animation {
        .spring(response: 0.4, dampingFraction: 0.6)
    }

    static var heavy: Animation {
        .spring(response: 0.3, dampingFraction: 1.0)
    }
}
