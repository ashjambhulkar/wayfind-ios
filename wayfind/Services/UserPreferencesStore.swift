//
//  UserPreferencesStore.swift
//  wayfind
//
//  Persists profile-adjacent preferences. Keys `tw_appearance_pref` and `tw_maps_app_pref`
//  match the Expo app (SecureStore) so a user switching clients sees the same values.
//

import Foundation
import Observation
import SwiftUI

/// Values stored under `tw_appearance_pref` in Expo.
enum WayfindAppearancePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    /// Menu copy aligned with Expo `APPEARANCE_LABEL` (`Auto` for system).
    var menuTitle: String {
        switch self {
        case .system: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Values stored under `tw_maps_app_pref` in Expo.
enum WayfindMapsAppPreference: String, CaseIterable, Identifiable, Sendable {
    case apple
    case google

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .apple: "Apple Maps"
        case .google: "Google Maps"
        }
    }
}

/// Trip list sort; raw values match Expo `TripSortMode` (`utils/tripSort.ts`).
enum TripListSortMode: String, CaseIterable, Identifiable, Sendable {
    case startAsc = "start_asc"
    case startDesc = "start_desc"
    case name
    case updated

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .startAsc: "Start date"
        case .startDesc: "Start date (newest)"
        case .name: "Name"
        case .updated: "Recently updated"
        }
    }
}

private enum PreferenceStorageKey {
    /// Same key as Expo `appearancePreferenceStore`.
    static let appearance = "tw_appearance_pref"
    /// Same key as Expo `travelMapsPreferenceStore`.
    static let mapsApp = "tw_maps_app_pref"
    /// Expo keeps sort in memory only; we persist for a better native UX.
    static let tripSort = "tw_trip_list_sort"
}

@Observable
@MainActor
final class UserPreferencesStore {
    private let defaults: UserDefaults

    var appearancePreference: WayfindAppearancePreference {
        didSet { persistAppearance() }
    }

    var mapsAppPreference: WayfindMapsAppPreference {
        didSet { persistMapsApp() }
    }

    var tripSortMode: TripListSortMode {
        didSet { persistTripSort() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearancePreference = Self.loadAppearance(from: defaults)
        mapsAppPreference = Self.loadMapsApp(from: defaults)
        tripSortMode = Self.loadTripSort(from: defaults)
    }

    func cycleMapsApp() {
        mapsAppPreference = mapsAppPreference == .apple ? .google : .apple
    }

    private func persistAppearance() {
        defaults.set(appearancePreference.rawValue, forKey: PreferenceStorageKey.appearance)
    }

    private func persistMapsApp() {
        defaults.set(mapsAppPreference.rawValue, forKey: PreferenceStorageKey.mapsApp)
    }

    private func persistTripSort() {
        defaults.set(tripSortMode.rawValue, forKey: PreferenceStorageKey.tripSort)
    }

    private static func loadAppearance(from defaults: UserDefaults) -> WayfindAppearancePreference {
        let raw = defaults.string(forKey: PreferenceStorageKey.appearance)
        if let raw, let value = WayfindAppearancePreference(rawValue: raw) { return value }
        return .system
    }

    private static func loadMapsApp(from defaults: UserDefaults) -> WayfindMapsAppPreference {
        let raw = defaults.string(forKey: PreferenceStorageKey.mapsApp)
        if let raw, let value = WayfindMapsAppPreference(rawValue: raw) { return value }
        return .google
    }

    private static func loadTripSort(from defaults: UserDefaults) -> TripListSortMode {
        let raw = defaults.string(forKey: PreferenceStorageKey.tripSort)
        if let raw, let value = TripListSortMode(rawValue: raw) { return value }
        return .startAsc
    }
}

