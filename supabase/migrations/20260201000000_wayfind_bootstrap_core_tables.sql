-- Fresh local / empty DB: later migrations ALTER these tables but historically the repo had no
-- baseline CREATE for core trip + place_cache tables. IF NOT EXISTS keeps linked/prod safe.

CREATE TABLE IF NOT EXISTS public.profiles (
  id uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.trips (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  name text,
  destination text,
  start_date date,
  end_date date,
  display_timezone text
);

CREATE TABLE IF NOT EXISTS public.trip_days (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  trip_id uuid NOT NULL REFERENCES public.trips (id) ON DELETE CASCADE,
  date date NOT NULL,
  label text
);

CREATE TABLE IF NOT EXISTS public.trip_activities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  trip_id uuid NOT NULL REFERENCES public.trips (id) ON DELETE CASCADE,
  day_id uuid REFERENCES public.trip_days (id) ON DELETE SET NULL,
  user_id uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  name text,
  description text,
  category text,
  starts_at timestamptz,
  duration_minutes integer,
  latitude double precision,
  longitude double precision,
  address text,
  place_id text,
  estimated_cost numeric,
  currency text,
  rating real,
  price_level integer,
  sort_order integer NOT NULL DEFAULT 0,
  travel_from_previous_minutes integer,
  directions_url text,
  travel_mode text NOT NULL DEFAULT 'driving',
  source text,
  booking_id uuid,
  hero_image_url text,
  hero_attribution text,
  place_search_query text,
  meal_anchor boolean NOT NULL DEFAULT false
);

CREATE TABLE IF NOT EXISTS public.trip_bookings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  trip_id uuid NOT NULL REFERENCES public.trips (id) ON DELETE CASCADE,
  kind text NOT NULL DEFAULT 'activity'
);

CREATE TABLE IF NOT EXISTS public.place_cache (
  place_id text PRIMARY KEY,
  latitude double precision,
  longitude double precision,
  formatted_address text,
  photo_reference text
);

CREATE TABLE IF NOT EXISTS public.trip_activity_attachments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  activity_id uuid NOT NULL REFERENCES public.trip_activities (id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  mime_type text,
  attachment_type text
);

CREATE TABLE IF NOT EXISTS public.email_forwarding_queue (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at timestamptz NOT NULL DEFAULT now()
);
