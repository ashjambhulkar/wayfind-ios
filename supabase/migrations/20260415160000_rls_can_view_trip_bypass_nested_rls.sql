-- Fix infinite RLS recursion: trip_collaborators_select used can_view_trip(trip_id), and
-- can_view_trip (SECURITY INVOKER) SELECTs trip_collaborators → same policy → stack depth exceeded.
-- SECURITY DEFINER + row_security off: membership check still filters by auth.uid(); no row data returned.

CREATE OR REPLACE FUNCTION public.can_view_trip(p_trip_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.trips t
    WHERE t.id = p_trip_id
      AND t.user_id = (SELECT auth.uid())
  )
  OR EXISTS (
    SELECT 1
    FROM public.trip_collaborators tc
    WHERE tc.trip_id = p_trip_id
      AND tc.user_id = (SELECT auth.uid())
      AND tc.status IN ('accepted', 'pending')
  );
$$;

CREATE OR REPLACE FUNCTION public.can_edit_trip(p_trip_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.trips t
    WHERE t.id = p_trip_id
      AND t.user_id = (SELECT auth.uid())
  )
  OR EXISTS (
    SELECT 1
    FROM public.trip_collaborators tc
    WHERE tc.trip_id = p_trip_id
      AND tc.user_id = (SELECT auth.uid())
      AND tc.status = 'accepted'
      AND tc.role = 'editor'
  );
$$;

REVOKE ALL ON FUNCTION public.can_view_trip(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.can_view_trip(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_view_trip(uuid) TO anon;

REVOKE ALL ON FUNCTION public.can_edit_trip(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.can_edit_trip(uuid) TO authenticated;
