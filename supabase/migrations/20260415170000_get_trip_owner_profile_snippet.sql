-- Collaborators cannot SELECT the owner's profiles row under normal RLS, but need a display label
-- in Trip members / hero. Expose minimal fields only when the caller can already view the trip.

CREATE OR REPLACE FUNCTION public.get_trip_owner_profile_snippet(p_trip_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $fn$
DECLARE
  v_owner_id uuid;
  v_display text;
  v_avatar text;
  v_username text;
BEGIN
  IF p_trip_id IS NULL THEN
    RETURN NULL::jsonb;
  END IF;

  IF NOT public.can_view_trip(p_trip_id) THEN
    RETURN NULL::jsonb;
  END IF;

  SELECT t.user_id
  INTO v_owner_id
  FROM public.trips t
  WHERE t.id = p_trip_id;

  IF v_owner_id IS NULL THEN
    RETURN NULL::jsonb;
  END IF;

  SELECT p.display_name, p.avatar_url, p.username
  INTO v_display, v_avatar, v_username
  FROM public.profiles p
  WHERE p.id = v_owner_id;

  RETURN jsonb_build_object(
    'display_name', v_display,
    'avatar_url', v_avatar,
    'username', v_username
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.get_trip_owner_profile_snippet(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_trip_owner_profile_snippet(uuid) TO authenticated;
