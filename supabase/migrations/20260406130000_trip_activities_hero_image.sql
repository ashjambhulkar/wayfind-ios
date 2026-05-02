-- Persist Unsplash (or other) hero image URL + attribution for place detail sheet, mirroring trips.cover_*.
ALTER TABLE public.trip_activities
  ADD COLUMN IF NOT EXISTS hero_image_url text NULL,
  ADD COLUMN IF NOT EXISTS hero_attribution text NULL;

COMMENT ON COLUMN public.trip_activities.hero_image_url IS 'Optional hero image URL for activity/place detail (e.g. Unsplash CDN).';
COMMENT ON COLUMN public.trip_activities.hero_attribution IS 'Attribution line for hero_image_url (e.g. Photo by … on Unsplash).';
