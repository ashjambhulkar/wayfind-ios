-- Align with V1 product policy: no Google Places photos (category icons + user attachments).
-- IF EXISTS: safe if bootstrap or remote schema omitted a table.
ALTER TABLE IF EXISTS public.trip_activities DROP COLUMN IF EXISTS place_photo_ref;
ALTER TABLE IF EXISTS public.place_cache DROP COLUMN IF EXISTS photo_reference;
