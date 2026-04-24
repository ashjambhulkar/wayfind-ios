-- Redundant denormalized column; canonical trip owner is trips.user_id (V2c).
-- CASCADE drops RLS policies (or other objects) that still reference owner_id.

DROP TRIGGER IF EXISTS trip_collaborators_fill_owner_id ON public.trip_collaborators;
DROP FUNCTION IF EXISTS public.trip_collaborators_fill_owner_id();

ALTER TABLE public.trip_collaborators
  DROP COLUMN IF EXISTS owner_id CASCADE;
