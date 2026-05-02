-- Remote DBs may have checklist_items from an older schema without `title` (CREATE TABLE IF NOT EXISTS skipped our definition).
-- App + RPC expect column `title`.

DO $migration$
DECLARE
  src_col text;
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns c
    WHERE c.table_schema = 'public'
      AND c.table_name = 'checklist_items'
      AND c.column_name = 'title'
  ) THEN
    RETURN;
  END IF;

  IF to_regclass('public.checklist_items') IS NULL THEN
    RETURN;
  END IF;

  SELECT c.column_name
  INTO src_col
  FROM information_schema.columns c
  WHERE c.table_schema = 'public'
    AND c.table_name = 'checklist_items'
    AND c.column_name = ANY (
      ARRAY[
        'label',
        'name',
        'text',
        'content',
        'body',
        'item_text',
        'description'
      ]
    )
  ORDER BY array_position(
    ARRAY['label', 'name', 'text', 'content', 'body', 'item_text', 'description']::text[],
    c.column_name
  )
  LIMIT 1;

  IF src_col IS NOT NULL THEN
    EXECUTE format('ALTER TABLE public.checklist_items RENAME COLUMN %I TO title', src_col);
  ELSE
    ALTER TABLE public.checklist_items
      ADD COLUMN title text NOT NULL DEFAULT '';
    ALTER TABLE public.checklist_items
      ALTER COLUMN title DROP DEFAULT;
  END IF;
END
$migration$;

-- Some legacy schemas used is_checked instead of is_done.
DO $migration$
BEGIN
  IF to_regclass('public.checklist_items') IS NULL THEN
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'checklist_items' AND column_name = 'is_done'
  ) THEN
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'checklist_items' AND column_name = 'is_checked'
  ) THEN
    ALTER TABLE public.checklist_items RENAME COLUMN is_checked TO is_done;
  END IF;
END
$migration$;
