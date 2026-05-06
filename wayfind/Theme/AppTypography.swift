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

    /// Primary title on timeline / trip-detail dense list rows — semibold headline (lighter than `.bold`).
    static var timelineRowTitle: Font {
        .system(.headline, design: .rounded).weight(.semibold)
    }

    static var appBody: Font {
        .system(.body, design: .rounded)
    }

    static var appCaption: Font {
        .system(.caption, design: .rounded)
    }

    /// Dense secondary lines on timeline cards (eyebrow, subtitle, travel segment).
    static var appFootnote: Font {
        .system(.footnote, design: .rounded)
    }

    static var appSmall: Font {
        .system(.caption2, design: .rounded).weight(.medium)
    }

    /// Category / booking SF Symbol inside the map-style timeline spine pin.
    static var timelineSpinePinIcon: Font {
        .system(.subheadline, design: .rounded).weight(.bold)
    }

    /// Travel mode SF Symbol (between-stops spine + directions). The hub uses this font with `Image.imageScale(.small)` so filled glyphs clear the ring.
    static var timelineSpineTravelModeIcon: Font {
        appSmall.weight(.semibold)
    }

    /// 12-hour spine teardrop — “AM/PM” under the clock digits (smaller than the `appSmall` time line).
    static var timelinePinMeridiem: Font {
        .system(size: 6, design: .rounded).weight(.medium)
    }

    static var appButton: Font {
        .system(.headline, design: .rounded)
    }
}


// =============================================================================

