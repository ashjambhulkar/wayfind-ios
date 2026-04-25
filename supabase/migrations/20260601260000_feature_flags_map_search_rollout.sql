-- Phase G.3 (places-cost-and-owned-data plan).
--
-- Layered rollout controls for `flag_map_search_provider`:
--
--   * flag_map_search_provider_rollout_pct (int, 0..100)
--     What share of installations see the *default* provider (the
--     value already in `flag_map_search_provider`). The remaining
--     share falls back to legacy Google search so we never gamble
--     100% of users on a fresh provider.
--
--     Operating recipe:
--       Day 0  → 10
--       Day 7  → 25
--       Day 14 → 100   (still revertable per-country)
--
--   * flag_map_search_provider_country_overrides (jsonb object)
--     Per-country override. Keys are ISO 3166-1 alpha-2 codes
--     (uppercase), values are one of "apple", "google",
--     "china_fallback". Wins over the rollout percentage so an
--     emerging issue in a single country (Apple cohort more than
--     10pp lower than Google cohort on autocomplete success rate)
--     can be quarantined immediately by setting
--       {"FR": "google"}
--     without halting the global rollout.
--
-- Both flags are read by `FeatureFlagsService.mapSearchProvider(forCountry:)`
-- on iOS. The legacy `flag_map_search_provider` value remains the
-- single global default and is still readable as before.

INSERT INTO public.feature_flags (flag, value, description) VALUES
  ('flag_map_search_provider_rollout_pct',
   '100'::jsonb,
   'Phase G.3 — Percentage of installations that see flag_map_search_provider. Bucketed by stable_user_hash() (user_id or device_id). Outside the bucket → legacy "google" provider. Range 0..100. 1h client cache.'),
  ('flag_map_search_provider_country_overrides',
   '{}'::jsonb,
   'Phase G.3 — Per-country override map. Keys are ISO 3166-1 alpha-2 codes (uppercase), values are "apple" / "google" / "china_fallback". Wins over rollout pct so a single-country quarantine doesn''t halt the global rollout. 1h client cache.')
ON CONFLICT (flag) DO NOTHING;
