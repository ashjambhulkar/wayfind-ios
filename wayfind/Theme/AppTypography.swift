//
//  AppTypography.swift
//  wayfind
//
//  Created by Ashish Jambhulkar on 4/2/26.
//

import SwiftUI

extension Font {
    static var screenTitle: Font {
        .system(.largeTitle, design: .rounded).weight(.bold)
    }

    static var sectionHeader: Font {
        .system(.title3, design: .rounded).weight(.semibold)
    }

    /// Trip detail cover / hero headline (above date range).
    static var tripDetailHeroTitle: Font {
        .system(.title, design: .rounded).weight(.bold)
    }

    static var cardTitle: Font {
        .system(.headline, design: .rounded)
    }

    static var appBody: Font {
        .system(.body, design: .rounded)
    }

    static var appCaption: Font {
        .system(.caption, design: .rounded)
    }

    static var appSmall: Font {
        .system(.caption2, design: .rounded).weight(.medium)
    }

    static var appButton: Font {
        .system(.headline, design: .rounded)
    }
}


// =============================================================================

