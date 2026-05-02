-- Explicit user-id membership check for service-role Edge (mirrors can_view_trip semantics:
-- trip owner, or collaborator with accepted/pending status).

CREATE OR REPLACE FUNCTION public.is_trip_member(p_trip_id uuid, p_user_id uuid)
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
      AND t.user_id = p_user_id
  )
  OR EXISTS (
    SELECT 1
    FROM public.trip_collaborators tc
    WHERE tc.trip_id = p_trip_id
      AND tc.user_id = p_user_id
      AND tc.status IN ('accepted', 'pending')
  );
$$;

REVOKE ALL ON FUNCTION public.is_trip_member(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_trip_member(uuid, uuid) TO service_role;
