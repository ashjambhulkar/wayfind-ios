-- One designated cover per activity for timeline thumbnails; gallery rows remain in trip_activity_attachments.

ALTER TABLE public.trip_activity_attachments
  ADD COLUMN IF NOT EXISTS is_cover boolean NOT NULL DEFAULT false;

-- Backfill: mark oldest image-like row per activity as cover (matches pre-migration “first wins” behavior).
WITH image_rows AS (
  SELECT
    id,
    activity_id,
    created_at,
    ROW_NUMBER() OVER (
      PARTITION BY activity_id
      ORDER BY created_at ASC
    ) AS rn
  FROM public.trip_activity_attachments
  WHERE
    (mime_type IS NOT NULL AND mime_type ILIKE 'image/%')
    OR LOWER(COALESCE(attachment_type, '')) IN ('photo', 'image')
)
UPDATE public.trip_activity_attachments t
SET is_cover = true
FROM image_rows ir
WHERE t.id = ir.id AND ir.rn = 1;

COMMENT ON COLUMN public.trip_activity_attachments.is_cover IS 'Timeline cover; exactly one true per activity among image attachments (enforced in app).';
