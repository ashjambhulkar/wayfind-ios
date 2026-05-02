-- Trip members UI needs display labels for accepted collaborators. Direct
-- trip_collaborators → profiles embed often returns null under RLS for other users.
-- Same access bar as get_trip_owner_profile_snippet: caller must can_view_trip.

CREATE OR REPLACE FUNCTION public.list_trip_collaborator_profile_snippets(p_trip_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $fn$
BEGIN
  IF p_trip_id IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;

  IF NOT public.can_view_trip(p_trip_id) THEN
    RETURN '[]'::jsonb;
  END IF;

  RETURN COALESCE(
    (
      SELECT jsonb_agg(
        jsonb_build_object(
          'user_id', x.user_id,
          'display_name', x.display_name,
          'username', x.username,
          'avatar_url', x.avatar_url,
          'email', x.email
        )
        ORDER BY x.user_id
      )
      FROM (
        SELECT
          tc.user_id,
          p.display_name,
          p.username,
          p.avatar_url,
          au.email::text AS email
        FROM public.trip_collaborators tc
        LEFT JOIN public.profiles p ON p.id = tc.user_id
        LEFT JOIN auth.users au ON au.id = tc.user_id
        WHERE tc.trip_id = p_trip_id
          AND tc.status = 'accepted'
          AND tc.user_id IS NOT NULL
      ) x
    ),
    '[]'::jsonb
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.list_trip_collaborator_profile_snippets(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_trip_collaborator_profile_snippets(uuid) TO authenticated;
