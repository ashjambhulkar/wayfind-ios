-- Reset cached Unsplash city cover pools and re-queue fetches for every city profile.
-- Pair with deploy of city-cover-images (50 search calls/hour cap, 30 images per search).
--
-- Note: Does not change trips.cover_image_url; existing trip heroes keep prior URLs.

-- CASCADE removes assignment rows that reference cover images (FK order-safe).
TRUNCATE TABLE public.city_profile_cover_images CASCADE;
TRUNCATE TABLE public.city_profile_cover_fetch_jobs;

INSERT INTO public.city_profile_cover_fetch_jobs (city_profile_id, status, run_after)
SELECT id, 'pending', now()
FROM public.city_profiles;
