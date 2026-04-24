-- Remove legacy anchor table; curated places live on city_places (and related flows).

DROP TABLE IF EXISTS public.city_anchor_places;
