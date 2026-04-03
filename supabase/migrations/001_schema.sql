-- Wayfind core schema: tables, indexes, RLS, triggers, Realtime
-- gen_random_uuid() is built-in on PostgreSQL 13+ (Supabase default)

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text,
  avatar_url text,
  forwarding_email text unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.trips (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  title text not null,
  destination text not null,
  lat double precision,
  lng double precision,
  start_date timestamptz not null,
  end_date timestamptz not null,
  cover_image_url text,
  cover_image_attribution text,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.itinerary_days (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references public.trips (id) on delete cascade,
  day_number integer not null,
  date timestamptz,
  unique (trip_id, day_number)
);

create table public.places (
  id uuid primary key default gen_random_uuid(),
  itinerary_day_id uuid not null references public.itinerary_days (id) on delete cascade,
  name text not null,
  address text,
  lat double precision,
  lng double precision,
  category text,
  notes text,
  sort_order integer not null default 0,
  start_time timestamptz,
  end_time timestamptz,
  is_booking boolean not null default false,
  booking_type text,
  confirmation_number text,
  booking_details jsonb,
  google_place_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.parsed_bookings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  trip_id uuid not null references public.trips (id) on delete cascade,
  status text not null default 'pending'
    check (status in ('pending', 'parsed', 'confirmed', 'failed')),
  parsed_data jsonb,
  raw_email_body text,
  created_at timestamptz not null default now()
);

create table public.device_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  token text not null unique,
  platform text not null default 'ios',
  created_at timestamptz not null default now()
);

create table public.place_details_cache (
  google_place_id text primary key,
  name text,
  rating numeric,
  user_rating_count integer,
  price_level text,
  editorial_summary text,
  opening_hours jsonb,
  reviews jsonb,
  website_uri text,
  phone_number text,
  cached_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '30 days')
);

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------

create index trips_user_id_idx on public.trips (user_id);
create index itinerary_days_trip_id_idx on public.itinerary_days (trip_id);
create index places_itinerary_day_id_idx on public.places (itinerary_day_id);
create index parsed_bookings_trip_id_idx on public.parsed_bookings (trip_id);
create index device_tokens_user_id_idx on public.device_tokens (user_id);
create index place_details_cache_expires_at_idx on public.place_details_cache (expires_at);

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------

alter table public.profiles enable row level security;
alter table public.trips enable row level security;
alter table public.itinerary_days enable row level security;
alter table public.places enable row level security;
alter table public.parsed_bookings enable row level security;
alter table public.device_tokens enable row level security;
alter table public.place_details_cache enable row level security;

-- profiles
create policy "profiles_select_own"
  on public.profiles for select
  using (auth.uid() = id);

create policy "profiles_insert_own"
  on public.profiles for insert
  with check (auth.uid() = id);

create policy "profiles_update_own"
  on public.profiles for update
  using (auth.uid() = id)
  with check (auth.uid() = id);

create policy "profiles_delete_own"
  on public.profiles for delete
  using (auth.uid() = id);

-- trips
create policy "trips_select_own"
  on public.trips for select
  using (auth.uid() = user_id);

create policy "trips_insert_own"
  on public.trips for insert
  with check (auth.uid() = user_id);

create policy "trips_update_own"
  on public.trips for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "trips_delete_own"
  on public.trips for delete
  using (auth.uid() = user_id);

-- itinerary_days (via owning trip)
create policy "itinerary_days_select_via_trip"
  on public.itinerary_days for select
  using (
    exists (
      select 1
      from public.trips t
      where t.id = itinerary_days.trip_id
        and t.user_id = auth.uid()
    )
  );

create policy "itinerary_days_insert_via_trip"
  on public.itinerary_days for insert
  with check (
    exists (
      select 1
      from public.trips t
      where t.id = itinerary_days.trip_id
        and t.user_id = auth.uid()
    )
  );

create policy "itinerary_days_update_via_trip"
  on public.itinerary_days for update
  using (
    exists (
      select 1
      from public.trips t
      where t.id = itinerary_days.trip_id
        and t.user_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1
      from public.trips t
      where t.id = itinerary_days.trip_id
        and t.user_id = auth.uid()
    )
  );

create policy "itinerary_days_delete_via_trip"
  on public.itinerary_days for delete
  using (
    exists (
      select 1
      from public.trips t
      where t.id = itinerary_days.trip_id
        and t.user_id = auth.uid()
    )
  );

-- places (via itinerary day -> trip)
create policy "places_select_via_trip"
  on public.places for select
  using (
    exists (
      select 1
      from public.itinerary_days d
      join public.trips t on t.id = d.trip_id
      where d.id = places.itinerary_day_id
        and t.user_id = auth.uid()
    )
  );

create policy "places_insert_via_trip"
  on public.places for insert
  with check (
    exists (
      select 1
      from public.itinerary_days d
      join public.trips t on t.id = d.trip_id
      where d.id = places.itinerary_day_id
        and t.user_id = auth.uid()
    )
  );

create policy "places_update_via_trip"
  on public.places for update
  using (
    exists (
      select 1
      from public.itinerary_days d
      join public.trips t on t.id = d.trip_id
      where d.id = places.itinerary_day_id
        and t.user_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1
      from public.itinerary_days d
      join public.trips t on t.id = d.trip_id
      where d.id = places.itinerary_day_id
        and t.user_id = auth.uid()
    )
  );

create policy "places_delete_via_trip"
  on public.places for delete
  using (
    exists (
      select 1
      from public.itinerary_days d
      join public.trips t on t.id = d.trip_id
      where d.id = places.itinerary_day_id
        and t.user_id = auth.uid()
    )
  );

-- parsed_bookings
create policy "parsed_bookings_select_own"
  on public.parsed_bookings for select
  using (auth.uid() = user_id);

create policy "parsed_bookings_insert_own"
  on public.parsed_bookings for insert
  with check (auth.uid() = user_id);

create policy "parsed_bookings_update_own"
  on public.parsed_bookings for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "parsed_bookings_delete_own"
  on public.parsed_bookings for delete
  using (auth.uid() = user_id);

-- device_tokens
create policy "device_tokens_select_own"
  on public.device_tokens for select
  using (auth.uid() = user_id);

create policy "device_tokens_insert_own"
  on public.device_tokens for insert
  with check (auth.uid() = user_id);

create policy "device_tokens_update_own"
  on public.device_tokens for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "device_tokens_delete_own"
  on public.device_tokens for delete
  using (auth.uid() = user_id);

-- place_details_cache: authenticated read-only; writes via service_role (bypasses RLS in Supabase)
create policy "place_details_cache_select_authenticated"
  on public.place_details_cache for select
  to authenticated
  using (auth.uid() is not null);

create policy "place_details_cache_service_role_all"
  on public.place_details_cache for all
  to service_role
  using (true)
  with check (true);

-- ---------------------------------------------------------------------------
-- Functions & triggers: updated_at
-- ---------------------------------------------------------------------------

create or replace function public.update_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger update_updated_at
  before update on public.profiles
  for each row
  execute function public.update_updated_at();

create trigger update_updated_at
  before update on public.trips
  for each row
  execute function public.update_updated_at();

create trigger update_updated_at
  before update on public.places
  for each row
  execute function public.update_updated_at();

-- ---------------------------------------------------------------------------
-- Auth: create profile on signup
-- ---------------------------------------------------------------------------

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_display text;
  v_forward text;
begin
  v_display := coalesce(
    nullif(trim(new.raw_user_meta_data->>'full_name'), ''),
    new.email
  );

  v_forward := substr(gen_random_uuid()::text, 1, 8) || '@wayfind.app';

  insert into public.profiles (id, display_name, forwarding_email)
  values (new.id, v_display, v_forward);

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row
  execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- Trips: seed itinerary days (wishlist + numbered days)
-- ---------------------------------------------------------------------------

create or replace function public.handle_new_trip()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_span_days integer;
  v_n integer;
  v_day integer;
begin
  insert into public.itinerary_days (trip_id, day_number, date)
  values (new.id, 0, null);

  v_span_days := (new.end_date::date - new.start_date::date) + 1;
  v_n := greatest(v_span_days, 1);

  for v_day in 1..v_n loop
    insert into public.itinerary_days (trip_id, day_number, date)
    values (
      new.id,
      v_day,
      (new.start_date::date + (v_day - 1))::timestamptz
    );
  end loop;

  return new;
end;
$$;

create trigger on_trip_created
  after insert on public.trips
  for each row
  execute function public.handle_new_trip();

-- ---------------------------------------------------------------------------
-- Realtime: parsed_bookings
-- ---------------------------------------------------------------------------

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'parsed_bookings'
  ) then
    alter publication supabase_realtime add table public.parsed_bookings;
  end if;
end
$$;
