-- Remote / legacy schemas may use `paid_by` (NOT NULL); app + types use `payer_user_id`.
-- When both columns exist, DROP COLUMN paid_by fails if RLS policies reference it — drop those first, then recreate.

DO $migration$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'trip_expenses'
      AND column_name = 'paid_by'
  ) THEN
    IF NOT EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'trip_expenses'
        AND column_name = 'payer_user_id'
    ) THEN
      ALTER TABLE public.trip_expenses RENAME COLUMN paid_by TO payer_user_id;
    ELSE
      EXECUTE 'DROP POLICY IF EXISTS "Creator or editors can update expenses" ON public.trip_expenses';
      EXECUTE 'DROP POLICY IF EXISTS "Creator or editors can delete expenses" ON public.trip_expenses';

      IF to_regclass('public.expense_splits') IS NOT NULL THEN
        EXECUTE 'DROP POLICY IF EXISTS "Expense creator can update splits" ON public.expense_splits';
        EXECUTE 'DROP POLICY IF EXISTS "Expense creator can delete splits" ON public.expense_splits';
      END IF;

      UPDATE public.trip_expenses te
      SET payer_user_id = COALESCE(te.payer_user_id, te.paid_by)
      WHERE te.payer_user_id IS NULL;

      ALTER TABLE public.trip_expenses DROP COLUMN paid_by;

      -- Restore trip_expenses update/delete if this project never applied trip_expenses_update_editors / _delete_editors.
      IF NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'trip_expenses'
          AND policyname = 'trip_expenses_update_editors'
      ) THEN
        EXECUTE $te_upd$
          CREATE POLICY "Creator or editors can update expenses"
          ON public.trip_expenses
          FOR UPDATE
          TO authenticated
          USING (public.can_edit_trip(trip_id))
          WITH CHECK (public.can_edit_trip(trip_id))
        $te_upd$;
        EXECUTE $te_del$
          CREATE POLICY "Creator or editors can delete expenses"
          ON public.trip_expenses
          FOR DELETE
          TO authenticated
          USING (public.can_edit_trip(trip_id))
        $te_del$;
      END IF;

      IF to_regclass('public.expense_splits') IS NOT NULL THEN
        EXECUTE $es_upd$
          CREATE POLICY "Expense creator can update splits"
          ON public.expense_splits
          FOR UPDATE
          TO authenticated
          USING (
            EXISTS (
              SELECT 1
              FROM public.trip_expenses e
              WHERE e.id = expense_id
                AND e.payer_user_id = (SELECT auth.uid())
            )
          )
        $es_upd$;
        EXECUTE $es_del$
          CREATE POLICY "Expense creator can delete splits"
          ON public.expense_splits
          FOR DELETE
          TO authenticated
          USING (
            EXISTS (
              SELECT 1
              FROM public.trip_expenses e
              WHERE e.id = expense_id
                AND e.payer_user_id = (SELECT auth.uid())
            )
          )
        $es_del$;
      END IF;
    END IF;
  END IF;
END
$migration$;
