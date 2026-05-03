-- Ensure booking → trip_expenses sync populates multi-currency FX columns
-- (NOT NULL on originals / fx_rate_at_capture since 20260602120000).
--
-- Note: amounts stay in the booking’s native currency with fx_rate = 1.
-- Converting booking rows into `trips.budget_currency` would require a
-- server-side rate source; iOS-authored booking expenses are normalized
-- through the same client path as manual expenses when created from the app.
--
-- Client UI: when a synced row’s ledger ISO ≠ trips.budget_currency, the
-- Budget tab shows an info banner + row caption so trip-cap totals are not misread.

CREATE OR REPLACE FUNCTION public.tg_sync_booking_expense()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $sync$
DECLARE
  v_category text;
  v_currency text;
  v_title text;
  v_existing_id uuid;
  v_existing_auto boolean;
  v_actor uuid;
  v_spent date;
BEGIN
  IF pg_trigger_depth() > 1 THEN
    RETURN NEW;
  END IF;

  IF NEW.amount IS NULL OR NEW.amount <= 0 THEN
    RETURN NEW;
  END IF;

  v_category := CASE NEW.kind
    WHEN 'flight' THEN 'flight'
    WHEN 'lodging' THEN 'lodging'
    WHEN 'car' THEN 'car'
    WHEN 'restaurant' THEN 'food'
    WHEN 'train' THEN 'transport'
    WHEN 'bus' THEN 'transport'
    WHEN 'ferry' THEN 'transport'
    WHEN 'cruise' THEN 'transport'
    WHEN 'transport' THEN 'transport'
    WHEN 'concert' THEN 'activities'
    WHEN 'theater' THEN 'activities'
    WHEN 'tour' THEN 'activities'
    WHEN 'activity' THEN 'activities'
    WHEN 'activities' THEN 'activities'
    ELSE 'other'
  END;

  v_currency := COALESCE(NULLIF(trim(NEW.currency), ''), 'USD');
  v_title := COALESCE(NULLIF(trim(NEW.title), ''), 'Booking');
  v_actor := COALESCE(
    NEW.user_id,
    (SELECT t.user_id FROM public.trips t WHERE t.id = NEW.trip_id LIMIT 1)
  );
  v_spent := COALESCE(NEW.starts_at::date, CURRENT_DATE);

  IF v_actor IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT te.id, te.is_auto_synced
  INTO v_existing_id, v_existing_auto
  FROM public.trip_expenses te
  WHERE te.booking_id = NEW.id
  LIMIT 1;

  IF v_existing_id IS NULL THEN
    INSERT INTO public.trip_expenses (
      trip_id,
      user_id,
      booking_id,
      title,
      amount,
      currency,
      original_currency,
      original_amount,
      fx_rate_at_capture,
      fx_rate_date,
      category,
      split_type,
      payer_user_id,
      expense_date,
      is_auto_synced
    )
    VALUES (
      NEW.trip_id,
      v_actor,
      NEW.id,
      v_title,
      NEW.amount,
      v_currency,
      v_currency,
      NEW.amount,
      1.0,
      v_spent,
      v_category,
      'full',
      v_actor,
      v_spent,
      true
    );
  ELSIF v_existing_auto THEN
    UPDATE public.trip_expenses
    SET title = v_title,
        amount = NEW.amount,
        currency = v_currency,
        original_currency = v_currency,
        original_amount = NEW.amount,
        fx_rate_at_capture = 1.0,
        fx_rate_date = v_spent,
        category = v_category
    WHERE id = v_existing_id
      AND is_auto_synced = true;
  END IF;

  RETURN NEW;
END;
$sync$;

