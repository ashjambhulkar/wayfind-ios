# Decision Log

Append short entries here when you make a choice that future-you should not have to rediscover. Keep entries factual and small.

## Template

```text
YYYY-MM-DD - Title

Decision: What we chose.
Why: The pressure or problem that made this choice useful.
Alternatives: Other options considered, if any.
Follow-up: Any cleanup or revisit condition.
```

## 2026-04-25 - Use A Living Documentation Spine

Decision: Keep architecture, module ownership, Supabase ownership, AI change protocol, and complex feature READMEs in the repo.
Why: The project has grown enough that the sole developer should not need to memorize app flows, table ownership, Edge Function behavior, or past tradeoffs.
Alternatives: Rely on ad hoc AI explanations, long planning docs, or comments only.
Follow-up: Update these docs in the same change as meaningful feature/backend changes.

## 2026-04-25 - Treat Supabase As A First-Class Module

Decision: Track tables, RPCs, triggers, cron jobs, storage buckets, and Edge Functions in `docs/SUPABASE_BACKEND.md`.
Why: AI-generated backend changes can add hidden side effects across migrations, functions, policies, and Swift DTOs. A single ownership map reduces re-discovery.
Alternatives: Only inspect migrations when something breaks.
Follow-up: Add SQL smoke tests for money, permissions, invite acceptance, destructive cleanup, and quota logic as those areas change.

## 2026-04-25 - Map Places Uses A Floating Accessory Plus Expanded Sheet

Decision: The compact day-filter control on the map is a `safeAreaInset` accessory, while medium/large browsing uses a native SwiftUI sheet.
Why: Native small sheet detents could not visually sit above the tab bar without increasing internal sheet height. The accessory gives the desired compact position while the expanded states retain native sheet behavior.
Alternatives: Force all states through a single sheet detent stack, or keep the old tab accessory only.
Follow-up: If this flow grows more state, extract sheet/search sequencing from `TripMapView` into a dedicated coordinator.

## 2026-04-25 - Search Preview Sheet Presents Follow-Up Sheets Sequentially

Decision: Dismiss the place preview sheet before presenting follow-up sheets such as add-to-itinerary, then restore the source browser when needed.
Why: SwiftUI supports only one sheet presentation per presenter at a time. Sequencing avoids runtime warnings and preserves browsing context.
Alternatives: Attach every sheet to separate view presenters, which would make ownership harder to reason about.
Follow-up: Keep this behavior documented in `wayfind/Views/Map/README.md`.
