-- Phase 6 of the collaborative-budget rollout: the SettlementCompleteSheet
-- needs Venmo / PayPal handles for the *recipient* of a settlement so it can
-- assemble venmo:// or https://paypal.me deep links. Profiles RLS does not
-- expose other users' rows by default, so we extend the two SECURITY DEFINER
-- snippet RPCs that already gate by `can_view_trip(...)` to also surface the
-- two new payment-handle columns.
--
-- Backwards compatible: callers that ignore the new keys keep working. Both
-- handles default to NULL when the user hasn't filled them in from Edit
-- Profile.

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
  v_venmo text;
  v_paypal text;
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

  SELECT p.display_name, p.avatar_url, p.username, p.venmo_username, p.paypal_username
  INTO v_display, v_avatar, v_username, v_venmo, v_paypal
  FROM public.profiles p
  WHERE p.id = v_owner_id;

  RETURN jsonb_build_object(
    'display_name', v_display,
    'avatar_url', v_avatar,
    'username', v_username,
    'venmo_username', v_venmo,
    'paypal_username', v_paypal
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.get_trip_owner_profile_snippet(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_trip_owner_profile_snippet(uuid) TO authenticated;


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
          'email', x.email,
          'venmo_username', x.venmo_username,
          'paypal_username', x.paypal_username
        )
        ORDER BY x.user_id
      )
      FROM (
        SELECT
          tc.user_id,
          p.display_name,
          p.username,
          p.avatar_url,
          au.email::text AS email,
          p.venmo_username,
          p.paypal_username
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
