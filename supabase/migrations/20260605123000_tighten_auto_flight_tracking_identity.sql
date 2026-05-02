-- Tighten automatic flight tracking identity extraction.
--
-- The first auto-tracking migration intentionally accepted old free-text title
-- rows as a fallback. That can turn arbitrary text into bogus airline codes.
-- New iOS saves explicit carrier_iata; email imports often have airline names.

BEGIN;

CREATE OR REPLACE FUNCTION public.flight_carrier_iata_from_airline_name(p_airline text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE lower(trim(coalesce(p_airline, '')))
    WHEN 'american airlines' THEN 'AA'
    WHEN 'delta air lines' THEN 'DL'
    WHEN 'delta airlines' THEN 'DL'
    WHEN 'united airlines' THEN 'UA'
    WHEN 'southwest airlines' THEN 'WN'
    WHEN 'jetblue' THEN 'B6'
    WHEN 'jetblue airways' THEN 'B6'
    WHEN 'alaska airlines' THEN 'AS'
    WHEN 'air canada' THEN 'AC'
    WHEN 'british airways' THEN 'BA'
    WHEN 'air france' THEN 'AF'
    WHEN 'klm royal dutch airlines' THEN 'KL'
    WHEN 'klm' THEN 'KL'
    WHEN 'lufthansa' THEN 'LH'
    WHEN 'iberia' THEN 'IB'
    WHEN 'aer lingus' THEN 'EI'
    WHEN 'virgin atlantic' THEN 'VS'
    WHEN 'emirates' THEN 'EK'
    WHEN 'qatar airways' THEN 'QR'
    WHEN 'etihad airways' THEN 'EY'
    WHEN 'turkish airlines' THEN 'TK'
    WHEN 'singapore airlines' THEN 'SQ'
    WHEN 'cathay pacific' THEN 'CX'
    WHEN 'qantas' THEN 'QF'
    WHEN 'air new zealand' THEN 'NZ'
    WHEN 'japan airlines' THEN 'JL'
    WHEN 'ana' THEN 'NH'
    WHEN 'all nippon airways' THEN 'NH'
    WHEN 'korean air' THEN 'KE'
    WHEN 'air india' THEN 'AI'
    WHEN 'indigo' THEN '6E'
    WHEN 'vistara' THEN 'UK'
    WHEN 'ryanair' THEN 'FR'
    WHEN 'easyjet' THEN 'U2'
    WHEN 'wizz air' THEN 'W6'
    WHEN 'sas' THEN 'SK'
    WHEN 'swiss' THEN 'LX'
    WHEN 'austrian airlines' THEN 'OS'
    WHEN 'tap air portugal' THEN 'TP'
    WHEN 'ita airways' THEN 'AZ'
    WHEN 'alitalia' THEN 'AZ'
    WHEN 'finnair' THEN 'AY'
    WHEN 'lot polish airlines' THEN 'LO'
    WHEN 'aeromexico' THEN 'AM'
    WHEN 'latam airlines' THEN 'LA'
    WHEN 'avianca' THEN 'AV'
    WHEN 'copa airlines' THEN 'CM'
    ELSE NULL
  END;
$$;

CREATE OR REPLACE FUNCTION public.extract_flight_carrier_iata(p_booking public.trip_bookings)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_candidate text;
  v_flight_number text;
BEGIN
  v_candidate := upper(nullif(trim(coalesce(
    p_booking.details_json->>'carrier_iata',
    p_booking.details_json->>'carrierIATA',
    p_booking.details_json->>'iata',
    p_booking.details_json->>'airline_iata'
  )), ''));

  IF v_candidate ~ '^[A-Z0-9]{2,3}$' THEN
    RETURN v_candidate;
  END IF;

  v_candidate := public.flight_carrier_iata_from_airline_name(coalesce(
    p_booking.details_json->>'airline',
    p_booking.provider
  ));

  IF v_candidate IS NOT NULL THEN
    RETURN v_candidate;
  END IF;

  v_flight_number := upper(regexp_replace(coalesce(
    p_booking.details_json->>'flight_number',
    p_booking.details_json->>'flightNumber'
  ), '\s+', '', 'g'));

  v_candidate := substring(v_flight_number from '^[A-Z]{2,3}');
  IF v_candidate ~ '^[A-Z]{2,3}$' THEN
    RETURN v_candidate;
  END IF;

  RETURN NULL;
END;
$$;

-- Remove rows that were created from unstructured titles only. Valid rows will
-- be recreated by updating their booking or by future structured saves.
DELETE FROM public.flight_statuses fs
USING public.trip_bookings b
WHERE b.id = fs.booking_id
  AND b.kind = 'flight'
  AND public.extract_flight_carrier_iata(b) IS NULL;

COMMIT;
