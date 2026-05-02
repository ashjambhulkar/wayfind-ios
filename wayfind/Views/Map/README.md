# Map Feature README

Read this before changing map search, suggested places, preview sheets, day pills, or map bottom controls.

## Purpose

The map feature lets a user understand the current trip spatially, filter itinerary places by day, discover nearby/suggested places, preview a place, and add it to a trip day.

## Main Files

- `TripMapView.swift`: feature orchestrator. Owns most map UI state, sheet sequencing, day filter state, selected places, and handoff to app-level map tab state.
- `TripMapKitView.swift`: MapKit bridge and map rendering.
- `TripMapState.swift`: search/map state shared by map subviews.
- `MapSearchOverlay.swift`: search sheet UI, typed search, category pills, suggested places entry.
- `MapSearchPreviewSheet.swift`: selected search/suggested place preview.
- `MapAddToDaySheet.swift`: add selected preview result to a trip day.
- `TripMapPlacesSheet.swift`: minimized day-filter accessory and expanded places sheet.
- `SuggestedPlacesAllSheet.swift`: full suggested places browser.
- `MapSearchResultMerger.swift`: combines owned itinerary places and external search results.
- `AppleMapSearchService.swift`: Apple MapKit search/autocomplete/Look Around support.
- `CityPlacesSearchService.swift`: Supabase `city_places` suggested-place reads.
- `PlaceIdBridgeService.swift`: Apple-to-Google `place_id` bridge.

## State Ownership

`TripMapView` currently owns:

- Loaded itinerary places, wishlist places, scheduled days, and day ID mapping.
- Day filter state.
- Selected itinerary place.
- Search overlay presentation.
- Search preview presentation and detent.
- Add-to-day presentation.
- Suggested places browser presentation.
- Return-path flags for "close preview and reopen the source browser".
- Last category/search region state for "Search this area".
- The bottom map places accessory and expanded sheet handoff.

`TripMapState` owns search-specific state that child views need to share, including selected search result and search results.

If this file becomes harder to reason about, extract a `TripMapCoordinator` or similar `@Observable` owner for sheet/search sequencing before adding more flags.

## Sheet Flow

SwiftUI should only present one sheet from this flow at a time.

```text
Bottom tab search field
  -> MapSearchOverlay
     -> pick typed/suggested result
        -> dismiss search source
        -> MapSearchPreviewSheet
           -> Add to itinerary
              -> dismiss preview
              -> MapAddToDaySheet
           -> Close preview
              -> optionally reopen MapSearchOverlay or SuggestedPlacesAllSheet
```

Do not present `MapAddToDaySheet` while `MapSearchPreviewSheet` is still active.

## Suggested Places Rules

Suggested places should exclude places already in the current trip itinerary. The exclusion set is built from scheduled itinerary places and wishlist/Ideas places. When changing this logic, verify:

- Existing trip activity IDs are excluded.
- Known Google place IDs are excluded.
- Wishlist day IDs are handled correctly.
- The suggested places browser refreshes when the exclusion set changes.

## Search Rules

- Opening search from the bottom tab search field should show the input already focused.
- The close button should dismiss the search sheet, not leave an unfocused intermediate state.
- Category pills should write their label into the search field and keep the input focused.
- Search text from a category pill should persist when the search sheet closes/reopens.
- "Search this area" should only appear when there is typed/submitted search content and the map has drifted.

## Bottom Accessory Rules

The compact day-filter control is not a normal small sheet. It is a floating `safeAreaInset` accessory so it can sit above the tab bar. Expanded medium/large browsing uses a native SwiftUI sheet.

For the minimized accessory:

- Keep it compact and capsule-shaped.
- Keep the drag handle attached to the top.
- Keep day pills vertically centered.
- Tap or upward drag should expand to the native sheet.

## Backend Touchpoints

- `city_places`: suggested places and city pools.
- `city_profiles`: city matching/context.
- `city_travel_times`: cached travel legs.
- `place_id_bridge`: Apple-to-Google place ID matching.
- `trip_activities` and `trip_days`: itinerary places and add-to-day writes.

Update `docs/SUPABASE_BACKEND.md` when any of these schemas or function flows change.

## Verification Checklist

After map changes, manually verify:

- Bottom search opens directly focused with keyboard.
- Search close dismisses the sheet.
- Typed search results scroll and keyboard dismisses on scroll.
- Category pill writes text into the search field.
- Suggested places exclude itinerary places.
- Preview close returns to the correct source browser.
- Add-to-itinerary does not trigger a multiple-sheet warning.
- Minimized day accessory sits above the tab bar and expands on tap/drag.
