---
name: wayfind-swiftui-ui
description: >-
  Designs and implements SwiftUI UI for the native wayfind-ios app using Apple HIG,
  existing theme tokens, and safe layout patterns. Use when editing SwiftUI views in
  wayfind-ios, building screens, navigation chrome, sheets, lists, maps, trip detail,
  tab bars, floating controls, animations, accessibility, or when the user asks for
  iOS UI polish in this repository. Prefer the apple-docs MCP server for official
  SwiftUI, UIKit, and framework API details when it is enabled.
---

# Wayfind iOS — SwiftUI UI skill

## Apple documentation (MCP)

When the **apple-docs** MCP server is enabled (see `.cursor/mcp.json`), use it for official API behavior before guessing: e.g. **`search_apple_docs`**, **`get_apple_doc_content`**, **`search_framework_symbols`** (SwiftUI/UIKit), **`get_related_apis`**, and WWDC tools when the question is session- or migration-specific. This repo does not mirror Apple’s JSON docs locally.

## Project anchors (use these first)

- **Spacing**: `AppSpacing` (`wayfind/Theme/AppSpacing.swift`) — prefer `xs/sm/md/lg/xl` over raw numbers.
- **Color**: `AppColors` (`wayfind/Theme/AppColors.swift`) — no ad‑hoc hex in views unless adding a named token.
- **Type**: `AppTypography` / `.font(.appBody)` etc. from `AppTypography.swift`.
- **Motion**: `AppSpring.smooth`, `AppSpring.bouncy` from `AppAnimations.swift` — prefer springs over implicit `withAnimation` defaults for chrome and collapses.

## Human Interface Guidelines (default stance)

- Prefer **system materials and controls** where they match the job (`NavigationStack`, `toolbar`, `TabView`, `confirmationDialog`, standard list rows). **Trip detail** uses a native SwiftUI **`TabView`**: Itinerary, Map, Budget, Bookings, plus a **system tab bar**; **Add** (place / booking) lives in the **navigation bar** (no custom bottom bar).
- **Bottom chrome**: for non-tab screens, dock with **`VStack { Spacer(); … }`** or explicit **`alignment: .bottom`** — never give **`UIViewRepresentable`** or compact bars **`maxHeight: .infinity`** without **`fixedSize(horizontal:vertical:)`** or **`sizeThatFits`**, or UIKit views will stretch.
- **Safe areas**: respect home indicator. **`KeyWindowSafeArea.bottomInset`** is for overlays when environment insets are wrong; it is not needed for the **system** tab bar, which the OS lays out.
- **Hit targets**: keep tappable areas ≥ 44pt; use **`contentShape`** when labels are small.

## Layout checklist (before shipping UI)

1. **Proposed size**: What does `GeometryReader` / `ZStack` / parent **`frame(maxHeight:)`** pass to children? Avoid infinite vertical proposals on non‑flexible UIKit hosts.
2. **Cluster alignment**: Trailing clusters use **`Spacer(minLength: 0)`** before the group; leading clusters omit it.
3. **Scroll underlays**: the **itinerary** `ScrollView` in trip detail can use a small **`contentMargins(.bottom, …, for: .scrollContent)`** above the **system** tab bar — avoid double-padding with extra manual bottom insets.
4. **Dark mode**: verify **`AppColors`** light/dark pairs and SF Symbol rendering on both appearances.

## SwiftUI patterns that match this codebase

- **Observation / `@Environment(Type.self)`**: match existing stores (`DataService`, `ToastManager`, `AuthViewModel`).
- **Sheets / navigation**: follow existing `navigationDestination` / `sheet` patterns in `TripDetailView` and peers.
- **UIKit in SwiftUI**: only when a system control truly requires it; use **`sizeThatFits`** / intrinsic sizing and avoid giving UIKit hosts unbounded height proposals.

## Don’t (regressions seen in this repo)

- Don’t stack **bottom** UI in a root **`ZStack`** as a substitute for **`safeAreaInset`** on scroll screens that need a custom inset (non-tab) — it breaks scroll safe-area integration and reads as a floating chip. Trip detail **no longer** uses a custom bottom bar; use the **system** `TabView` instead.

## When designing new screens

- Start from **closest existing screen** (copy structure, spacing, navigation).
- Prefer **one strong visual surface** per region (hero, card, bar) — avoid nested unrelated materials.
- Add **VoiceOver labels** for non‑obvious icon‑only controls (e.g. **Add** and **More** in the trip detail toolbar).

## Optional deep dive

For Apple‑only API details, read official SwiftUI/UIKit docs when behavior is ambiguous; this skill stays project‑ and pattern‑focused.
