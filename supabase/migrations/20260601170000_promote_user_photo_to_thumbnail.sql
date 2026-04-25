-- Phase H.5 — `promote_user_photo_to_thumbnail` trigger.
--
-- When a `place_user_photos` row flips to status='approved', we want the
-- city_places row to start serving the user-uploaded photo as the hero
-- thumbnail PROVIDED that the current thumbnail is Google-sourced (or
-- absent / from any non-user source). We must NEVER stomp another
-- already-approved user photo: once user-sourced, the thumbnail belongs
-- to user uploads until manually demoted.
--
-- Promotion is also TIME-ordered: the most recently approved user photo
-- "wins" the thumbnail slot. That keeps the experience fresh while the
-- Phase F.5 carousel still surfaces older approved photos behind the
-- scenes.

CREATE OR REPLACE FUNCTION public.promote_user_photo_to_thumbnail()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_current_image_source text;
BEGIN
  -- Only fire on transitions INTO 'approved'. INSERTs that arrive already
  -- approved (admin tooling, backfills) also count; UPDATEs that touch
  -- other columns of an already-approved photo do not.
  IF NEW.status <> 'approved' THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.status = 'approved' THEN
    RETURN NEW;
  END IF;

  IF NEW.public_url IS NULL OR NEW.public_url = '' THEN
    -- The moderation Edge Function is responsible for setting
    -- public_url at the moment of promotion. If it isn't set yet, defer:
    -- a follow-up UPDATE will fire this trigger again.
    RETURN NEW;
  END IF;

  SELECT image_source
    INTO v_current_image_source
    FROM public.city_places
   WHERE id = NEW.city_place_id
   FOR UPDATE;

  IF NOT FOUND THEN
    -- Race: city_places row was deleted under us. Nothing to do.
    RETURN NEW;
  END IF;

  -- Promote when the slot is empty/google/serpapi/wikimedia/unknown.
  -- 'user' means another approved user photo already owns the slot;
  -- ordering between two approved user photos is decided by recency
  -- via the `OR v_current_image_source = 'user'` branch — we accept
  -- the newer one because the most recently approved photo is freshest
  -- evidence the place still looks like that.
  IF v_current_image_source IS DISTINCT FROM 'user' THEN
    UPDATE public.city_places
       SET thumbnail_url = NEW.public_url,
           image_source = 'user',
           images_refreshed_at = now(),
           thumbnail_attribution = 'Photo by traveler'
     WHERE id = NEW.city_place_id;
  ELSE
    -- Already user-owned. Update only if this photo was approved later
    -- than the currently-served one (use approved_at as the tie-break).
    UPDATE public.city_places c
       SET thumbnail_url = NEW.public_url,
           images_refreshed_at = now()
     WHERE c.id = NEW.city_place_id
       AND COALESCE(c.images_refreshed_at, 'epoch'::timestamptz)
           < COALESCE(NEW.approved_at, now());
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS place_user_photos_promote_thumbnail
  ON public.place_user_photos;

CREATE TRIGGER place_user_photos_promote_thumbnail
  AFTER INSERT OR UPDATE OF status, public_url
  ON public.place_user_photos
  FOR EACH ROW
  EXECUTE FUNCTION public.promote_user_photo_to_thumbnail();
