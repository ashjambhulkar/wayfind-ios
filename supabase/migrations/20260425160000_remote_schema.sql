create extension if not exists "pg_cron" with schema "pg_catalog";

alter table "public"."checklist_items" drop constraint "checklist_items_user_id_fkey";

alter table "public"."trip_activities" drop constraint "trip_activities_day_id_fkey";

alter table "public"."trip_activities" drop constraint "trip_activities_user_id_fkey";

alter table "public"."trip_bookings" drop constraint "trip_bookings_user_id_fkey";

alter table "public"."trip_checklists" drop constraint "trip_checklists_user_id_fkey";

alter table "public"."trip_collaborators" drop constraint "trip_collaborators_role_check";

alter table "public"."trip_days" drop constraint "trip_days_user_id_fkey";

alter table "public"."trip_expenses" drop constraint "trip_expenses_amount_check";

alter table "public"."trip_notes" drop constraint "trip_notes_user_id_fkey";

alter table "public"."trips" drop constraint "trips_user_id_fkey";


  create table "public"."expense_splits" (
    "id" uuid not null default gen_random_uuid(),
    "expense_id" uuid not null,
    "user_id" uuid not null,
    "owed_amount" numeric not null default 0,
    "created_at" timestamp with time zone not null default now()
      );


alter table "public"."expense_splits" enable row level security;


  create table "public"."fcm_tokens" (
    "id" uuid not null default gen_random_uuid(),
    "user_id" uuid not null,
    "token" text not null,
    "platform" text not null,
    "created_at" timestamp with time zone not null default now(),
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."fcm_tokens" enable row level security;


  create table "public"."notifications" (
    "id" uuid not null default gen_random_uuid(),
    "user_id" uuid not null,
    "type" text not null,
    "title" text not null,
    "body" text not null,
    "data" jsonb default '{}'::jsonb,
    "idempotency_key" text,
    "is_read" boolean not null default false,
    "created_at" timestamp with time zone not null default now()
      );


alter table "public"."notifications" enable row level security;


  create table "public"."pin_photos" (
    "id" uuid not null default gen_random_uuid(),
    "pin_id" uuid not null,
    "user_id" uuid not null,
    "image_url" text not null,
    "caption" text,
    "created_at" timestamp with time zone not null default now()
      );


alter table "public"."pin_photos" enable row level security;


  create table "public"."pins" (
    "id" uuid not null default gen_random_uuid(),
    "user_id" uuid not null,
    "name" text not null,
    "description" text,
    "latitude" double precision not null,
    "longitude" double precision not null,
    "place_id" text,
    "address" text,
    "country" text,
    "country_code" text,
    "pin_color" text default '#2563EB'::text,
    "pin_type" text not null default 'visited'::text,
    "visited_at" date,
    "created_at" timestamp with time zone not null default now(),
    "source" text not null default 'manual'::text
      );


alter table "public"."pins" enable row level security;


  create table "public"."stop_photos" (
    "id" uuid not null default gen_random_uuid(),
    "stop_id" uuid not null,
    "user_id" uuid not null,
    "image_url" text not null,
    "caption" text,
    "sort_order" integer not null default 0,
    "created_at" timestamp with time zone not null default now()
      );


alter table "public"."stop_photos" enable row level security;


  create table "public"."stops" (
    "id" uuid not null default gen_random_uuid(),
    "trip_id" uuid not null,
    "user_id" uuid not null,
    "name" text not null,
    "description" text,
    "latitude" double precision not null,
    "longitude" double precision not null,
    "place_id" text,
    "address" text,
    "country" text,
    "country_code" text,
    "pin_color" text default '#2563EB'::text,
    "arrived_at" timestamp with time zone,
    "departed_at" timestamp with time zone,
    "sort_order" integer not null default 0,
    "created_at" timestamp with time zone not null default now()
      );


alter table "public"."stops" enable row level security;


  create table "public"."track_points" (
    "id" uuid not null default gen_random_uuid(),
    "trip_id" uuid not null,
    "user_id" uuid not null,
    "latitude" double precision not null,
    "longitude" double precision not null,
    "altitude" double precision,
    "speed" double precision,
    "accuracy" double precision,
    "recorded_at" timestamp with time zone not null,
    "created_at" timestamp with time zone not null default now()
      );


alter table "public"."track_points" enable row level security;


  create table "public"."trip_booking_attachments" (
    "id" uuid not null default gen_random_uuid(),
    "booking_id" uuid not null,
    "user_id" uuid not null,
    "storage_path" text not null,
    "original_filename" text,
    "mime_type" text,
    "file_size_bytes" integer,
    "created_at" timestamp with time zone not null default now(),
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."trip_booking_attachments" enable row level security;


  create table "public"."trip_budgets" (
    "id" uuid not null default gen_random_uuid(),
    "trip_id" uuid not null,
    "user_id" uuid not null,
    "category" text not null,
    "planned_amount" numeric not null default 0,
    "spent_amount" numeric not null default 0,
    "currency" text not null default 'USD'::text,
    "created_at" timestamp with time zone not null default now(),
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."trip_budgets" enable row level security;


  create table "public"."trip_routes" (
    "id" uuid not null default gen_random_uuid(),
    "trip_id" uuid not null,
    "day_number" integer not null,
    "origin_lat" double precision not null,
    "origin_lng" double precision not null,
    "dest_lat" double precision not null,
    "dest_lng" double precision not null,
    "travel_mode" text not null default 'driving'::text,
    "encoded_polyline" text,
    "created_at" timestamp with time zone default now()
      );


alter table "public"."trip_routes" enable row level security;


  create table "public"."user_forwarding_addresses" (
    "id" uuid not null default gen_random_uuid(),
    "user_id" uuid not null,
    "trip_id" uuid not null,
    "address_token" text not null,
    "is_active" boolean not null default true,
    "created_at" timestamp with time zone not null default now()
      );


alter table "public"."user_forwarding_addresses" enable row level security;


  create table "public"."user_stats" (
    "user_id" uuid not null,
    "countries_visited" integer not null default 0,
    "total_trips" integer not null default 0,
    "total_distance_km" double precision not null default 0,
    "total_pins" integer not null default 0,
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."user_stats" enable row level security;

alter table "public"."checklist_items" drop column "due_at";

alter table "public"."email_forwarding_queue" add column "error_message" text;

alter table "public"."email_forwarding_queue" add column "extracted_bookings" jsonb;

alter table "public"."email_forwarding_queue" add column "message_id_hash" text not null;

alter table "public"."email_forwarding_queue" add column "processed_at" timestamp with time zone;

alter table "public"."email_forwarding_queue" add column "raw_email_storage_path" text;

alter table "public"."email_forwarding_queue" add column "sender_email" text not null;

alter table "public"."email_forwarding_queue" add column "status" text not null default 'pending'::text;

alter table "public"."email_forwarding_queue" add column "subject" text;

alter table "public"."email_forwarding_queue" add column "trip_id" uuid;

alter table "public"."email_forwarding_queue" add column "user_id" uuid;

alter table "public"."email_forwarding_queue" enable row level security;

alter table "public"."place_cache" drop column "formatted_address";

alter table "public"."place_cache" add column "address" text;

alter table "public"."place_cache" add column "details_json" jsonb;

alter table "public"."place_cache" add column "fetched_at" timestamp with time zone not null default now();

alter table "public"."place_cache" add column "name" text;

alter table "public"."place_cache" add column "price_level" integer;

alter table "public"."place_cache" add column "rating" double precision;

alter table "public"."place_cache" add column "types" text[];

alter table "public"."place_cache" enable row level security;

alter table "public"."profiles" add column "avatar_url" text;

alter table "public"."profiles" add column "bio" text;

alter table "public"."profiles" add column "default_pin_color" text default '#E53935'::text;

alter table "public"."profiles" add column "display_name" text;

alter table "public"."profiles" add column "updated_at" timestamp with time zone not null default now();

alter table "public"."profiles" add column "username" text not null;

alter table "public"."profiles" enable row level security;

alter table "public"."trip_activities" add column "created_at" timestamp with time zone not null default now();

alter table "public"."trip_activities" add column "updated_at" timestamp with time zone not null default now();

alter table "public"."trip_activities" alter column "day_id" set not null;

alter table "public"."trip_activities" alter column "name" set not null;

alter table "public"."trip_activities" alter column "rating" set data type double precision using "rating"::double precision;

alter table "public"."trip_activities" alter column "source" set default 'manual'::text;

alter table "public"."trip_activities" alter column "source" set not null;

alter table "public"."trip_activities" alter column "user_id" set not null;

alter table "public"."trip_activities" enable row level security;

alter table "public"."trip_activity_attachments" add column "file_size_bytes" integer;

alter table "public"."trip_activity_attachments" add column "label" text;

alter table "public"."trip_activity_attachments" add column "original_filename" text;

alter table "public"."trip_activity_attachments" add column "storage_path" text;

alter table "public"."trip_activity_attachments" add column "trip_id" uuid not null;

alter table "public"."trip_activity_attachments" add column "updated_at" timestamp with time zone not null default now();

alter table "public"."trip_activity_attachments" add column "url" text;

alter table "public"."trip_activity_attachments" add column "user_id" uuid not null;

alter table "public"."trip_activity_attachments" alter column "attachment_type" set not null;

alter table "public"."trip_activity_attachments" enable row level security;

alter table "public"."trip_bookings" add column "confirmation_code" text;

alter table "public"."trip_bookings" add column "created_at" timestamp with time zone not null default now();

alter table "public"."trip_bookings" add column "currency" text default 'USD'::text;

alter table "public"."trip_bookings" add column "details_json" jsonb default '{}'::jsonb;

alter table "public"."trip_bookings" add column "end_lat" double precision;

alter table "public"."trip_bookings" add column "end_lng" double precision;

alter table "public"."trip_bookings" add column "end_location" text;

alter table "public"."trip_bookings" add column "ends_at" timestamp with time zone;

alter table "public"."trip_bookings" add column "provider" text;

alter table "public"."trip_bookings" add column "sort_order" integer not null default 0;

alter table "public"."trip_bookings" add column "source" text not null default 'manual'::text;

alter table "public"."trip_bookings" add column "start_lat" double precision;

alter table "public"."trip_bookings" add column "start_lng" double precision;

alter table "public"."trip_bookings" add column "start_location" text;

alter table "public"."trip_bookings" add column "starts_at" timestamp with time zone;

alter table "public"."trip_bookings" add column "title" text not null;

alter table "public"."trip_bookings" add column "total_price" numeric;

alter table "public"."trip_bookings" add column "updated_at" timestamp with time zone not null default now();

alter table "public"."trip_bookings" alter column "kind" drop default;

alter table "public"."trip_bookings" alter column "user_id" set not null;

alter table "public"."trip_bookings" enable row level security;

alter table "public"."trip_collaborators" add column "accepted_at" timestamp with time zone;

alter table "public"."trip_collaborators" add column "can_see_documents" boolean not null default false;

alter table "public"."trip_collaborators" add column "can_see_notes" boolean not null default false;

alter table "public"."trip_collaborators" add column "invite_count" integer not null default 1;

alter table "public"."trip_collaborators" add column "invited_at" timestamp with time zone not null default now();

alter table "public"."trip_collaborators" alter column "created_at" drop not null;

alter table "public"."trip_collaborators" alter column "role" set default 'viewer'::text;

alter table "public"."trip_collaborators" alter column "status" set default 'pending'::text;

alter table "public"."trip_collaborators" alter column "updated_at" drop not null;

alter table "public"."trip_collaborators" alter column "user_id" drop not null;

alter table "public"."trip_days" add column "created_at" timestamp with time zone not null default now();

alter table "public"."trip_days" add column "day_number" integer not null default 1;

alter table "public"."trip_days" add column "notes" text;

alter table "public"."trip_days" add column "timezone" text;

alter table "public"."trip_days" add column "updated_at" timestamp with time zone not null default now();

alter table "public"."trip_days" alter column "user_id" set not null;

alter table "public"."trip_days" enable row level security;

alter table "public"."trip_expenses" add column "booking_id" uuid;

alter table "public"."trip_expenses" add column "expense_date" date not null default CURRENT_DATE;

alter table "public"."trip_expenses" add column "split_type" text not null default 'equal'::text;

alter table "public"."trip_expenses" alter column "amount" set data type numeric using "amount"::numeric;

alter table "public"."trip_expenses" alter column "category" set not null;

alter table "public"."trip_expenses" alter column "title" drop default;

alter table "public"."trip_expenses" alter column "user_id" drop not null;

alter table "public"."trip_notes" add column "is_private" boolean not null default true;

alter table "public"."trip_notes" alter column "body" drop default;

alter table "public"."trip_notes" alter column "body" drop not null;

alter table "public"."trip_notes" alter column "title" drop default;

alter table "public"."trip_notes" alter column "title" drop not null;

alter table "public"."trips" add column "budget_currency" text not null default 'USD'::text;

alter table "public"."trips" add column "cover_attribution" text;

alter table "public"."trips" add column "cover_image_url" text;

alter table "public"."trips" add column "created_at" timestamp with time zone not null default now();

alter table "public"."trips" add column "description" text;

alter table "public"."trips" add column "destination_place_id" text;

alter table "public"."trips" add column "destinations" jsonb;

alter table "public"."trips" add column "is_active" boolean not null default false;

alter table "public"."trips" add column "privacy" text not null default 'private'::text;

alter table "public"."trips" add column "status" text not null default 'planned'::text;

alter table "public"."trips" add column "total_budget" numeric default 0;

alter table "public"."trips" add column "updated_at" timestamp with time zone not null default now();

alter table "public"."trips" alter column "destination" set default ''::text;

alter table "public"."trips" alter column "destination" set not null;

alter table "public"."trips" alter column "name" set not null;

alter table "public"."trips" enable row level security;

CREATE INDEX checklist_items_checklist_id_idx ON public.checklist_items USING btree (checklist_id);

CREATE UNIQUE INDEX email_forwarding_queue_message_id_hash_key ON public.email_forwarding_queue USING btree (message_id_hash);

CREATE INDEX email_forwarding_queue_status_idx ON public.email_forwarding_queue USING btree (status);

CREATE INDEX email_forwarding_queue_user_id_idx ON public.email_forwarding_queue USING btree (user_id);

CREATE INDEX expense_splits_expense_id_idx ON public.expense_splits USING btree (expense_id);

CREATE UNIQUE INDEX expense_splits_expense_id_user_id_key ON public.expense_splits USING btree (expense_id, user_id);

CREATE UNIQUE INDEX expense_splits_pkey ON public.expense_splits USING btree (id);

CREATE INDEX expense_splits_user_id_idx ON public.expense_splits USING btree (user_id);

CREATE UNIQUE INDEX fcm_tokens_pkey ON public.fcm_tokens USING btree (id);

CREATE INDEX fcm_tokens_user_id_idx ON public.fcm_tokens USING btree (user_id);

CREATE UNIQUE INDEX fcm_tokens_user_id_token_key ON public.fcm_tokens USING btree (user_id, token);

CREATE INDEX idx_activity_attachments_activity ON public.trip_activity_attachments USING btree (activity_id);

CREATE INDEX idx_activity_attachments_trip ON public.trip_activity_attachments USING btree (trip_id);

CREATE INDEX idx_place_cache_fetched ON public.place_cache USING btree (fetched_at);

CREATE INDEX idx_trip_routes_trip_day ON public.trip_routes USING btree (trip_id, day_number);

CREATE UNIQUE INDEX notifications_pkey ON public.notifications USING btree (id);

CREATE INDEX notifications_user_id_created_at_idx ON public.notifications USING btree (user_id, created_at DESC);

CREATE UNIQUE INDEX notifications_user_id_idempotency_key_key ON public.notifications USING btree (user_id, idempotency_key);

CREATE INDEX notifications_user_id_unread_idx ON public.notifications USING btree (user_id) WHERE (is_read = false);

CREATE INDEX pin_photos_pin_id_idx ON public.pin_photos USING btree (pin_id);

CREATE UNIQUE INDEX pin_photos_pkey ON public.pin_photos USING btree (id);

CREATE INDEX pins_pin_type_idx ON public.pins USING btree (pin_type);

CREATE UNIQUE INDEX pins_pkey ON public.pins USING btree (id);

CREATE INDEX pins_user_id_idx ON public.pins USING btree (user_id);

CREATE UNIQUE INDEX profiles_username_key ON public.profiles USING btree (username);

CREATE UNIQUE INDEX stop_photos_pkey ON public.stop_photos USING btree (id);

CREATE INDEX stop_photos_stop_id_idx ON public.stop_photos USING btree (stop_id);

CREATE UNIQUE INDEX stops_pkey ON public.stops USING btree (id);

CREATE INDEX stops_trip_id_idx ON public.stops USING btree (trip_id);

CREATE INDEX stops_user_id_idx ON public.stops USING btree (user_id);

CREATE UNIQUE INDEX track_points_pkey ON public.track_points USING btree (id);

CREATE INDEX track_points_recorded_at_idx ON public.track_points USING btree (recorded_at);

CREATE INDEX track_points_trip_id_idx ON public.track_points USING btree (trip_id);

CREATE INDEX trip_activities_day_id_idx ON public.trip_activities USING btree (day_id);

CREATE INDEX trip_activities_trip_id_idx ON public.trip_activities USING btree (trip_id);

CREATE INDEX trip_booking_attachments_booking_id_idx ON public.trip_booking_attachments USING btree (booking_id);

CREATE UNIQUE INDEX trip_booking_attachments_pkey ON public.trip_booking_attachments USING btree (id);

CREATE INDEX trip_bookings_trip_id_idx ON public.trip_bookings USING btree (trip_id);

CREATE INDEX trip_bookings_user_id_idx ON public.trip_bookings USING btree (user_id);

CREATE UNIQUE INDEX trip_budgets_pkey ON public.trip_budgets USING btree (id);

CREATE UNIQUE INDEX trip_budgets_trip_id_category_key ON public.trip_budgets USING btree (trip_id, category);

CREATE INDEX trip_budgets_trip_id_idx ON public.trip_budgets USING btree (trip_id);

CREATE INDEX trip_checklists_trip_id_idx ON public.trip_checklists USING btree (trip_id);

CREATE INDEX trip_collaborators_trip_id_idx ON public.trip_collaborators USING btree (trip_id);

CREATE UNIQUE INDEX trip_days_trip_id_date_idx ON public.trip_days USING btree (trip_id, date);

CREATE INDEX trip_days_trip_id_idx ON public.trip_days USING btree (trip_id);

CREATE INDEX trip_expenses_trip_id_idx ON public.trip_expenses USING btree (trip_id);

CREATE INDEX trip_notes_trip_id_idx ON public.trip_notes USING btree (trip_id);

CREATE UNIQUE INDEX trip_routes_pkey ON public.trip_routes USING btree (id);

CREATE UNIQUE INDEX trip_routes_trip_id_day_number_origin_lat_origin_lng_dest_l_key ON public.trip_routes USING btree (trip_id, day_number, origin_lat, origin_lng, dest_lat, dest_lng, travel_mode);

CREATE INDEX trips_status_idx ON public.trips USING btree (status);

CREATE INDEX trips_user_id_idx ON public.trips USING btree (user_id);

CREATE UNIQUE INDEX user_forwarding_addresses_address_token_key ON public.user_forwarding_addresses USING btree (address_token);

CREATE UNIQUE INDEX user_forwarding_addresses_pkey ON public.user_forwarding_addresses USING btree (id);

CREATE INDEX user_forwarding_addresses_token_idx ON public.user_forwarding_addresses USING btree (address_token);

CREATE UNIQUE INDEX user_forwarding_addresses_user_trip_unique ON public.user_forwarding_addresses USING btree (user_id, trip_id);

CREATE UNIQUE INDEX user_stats_pkey ON public.user_stats USING btree (user_id);

alter table "public"."expense_splits" add constraint "expense_splits_pkey" PRIMARY KEY using index "expense_splits_pkey";

alter table "public"."fcm_tokens" add constraint "fcm_tokens_pkey" PRIMARY KEY using index "fcm_tokens_pkey";

alter table "public"."notifications" add constraint "notifications_pkey" PRIMARY KEY using index "notifications_pkey";

alter table "public"."pin_photos" add constraint "pin_photos_pkey" PRIMARY KEY using index "pin_photos_pkey";

alter table "public"."pins" add constraint "pins_pkey" PRIMARY KEY using index "pins_pkey";

alter table "public"."stop_photos" add constraint "stop_photos_pkey" PRIMARY KEY using index "stop_photos_pkey";

alter table "public"."stops" add constraint "stops_pkey" PRIMARY KEY using index "stops_pkey";

alter table "public"."track_points" add constraint "track_points_pkey" PRIMARY KEY using index "track_points_pkey";

alter table "public"."trip_booking_attachments" add constraint "trip_booking_attachments_pkey" PRIMARY KEY using index "trip_booking_attachments_pkey";

alter table "public"."trip_budgets" add constraint "trip_budgets_pkey" PRIMARY KEY using index "trip_budgets_pkey";

alter table "public"."trip_routes" add constraint "trip_routes_pkey" PRIMARY KEY using index "trip_routes_pkey";

alter table "public"."user_forwarding_addresses" add constraint "user_forwarding_addresses_pkey" PRIMARY KEY using index "user_forwarding_addresses_pkey";

alter table "public"."user_stats" add constraint "user_stats_pkey" PRIMARY KEY using index "user_stats_pkey";

alter table "public"."email_forwarding_queue" add constraint "email_forwarding_queue_message_id_hash_key" UNIQUE using index "email_forwarding_queue_message_id_hash_key";

alter table "public"."email_forwarding_queue" add constraint "email_forwarding_queue_status_check" CHECK ((status = ANY (ARRAY['received'::text, 'pending'::text, 'processing'::text, 'processed'::text, 'failed'::text, 'no_user'::text, 'needs_assignment'::text]))) not valid;

alter table "public"."email_forwarding_queue" validate constraint "email_forwarding_queue_status_check";

alter table "public"."email_forwarding_queue" add constraint "email_forwarding_queue_trip_id_fkey" FOREIGN KEY (trip_id) REFERENCES public.trips(id) ON DELETE SET NULL not valid;

alter table "public"."email_forwarding_queue" validate constraint "email_forwarding_queue_trip_id_fkey";

alter table "public"."email_forwarding_queue" add constraint "email_forwarding_queue_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE SET NULL not valid;

alter table "public"."email_forwarding_queue" validate constraint "email_forwarding_queue_user_id_fkey";

alter table "public"."expense_splits" add constraint "expense_splits_expense_id_fkey" FOREIGN KEY (expense_id) REFERENCES public.trip_expenses(id) ON DELETE CASCADE not valid;

alter table "public"."expense_splits" validate constraint "expense_splits_expense_id_fkey";

alter table "public"."expense_splits" add constraint "expense_splits_expense_id_user_id_key" UNIQUE using index "expense_splits_expense_id_user_id_key";

alter table "public"."expense_splits" add constraint "expense_splits_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE not valid;

alter table "public"."expense_splits" validate constraint "expense_splits_user_id_fkey";

alter table "public"."fcm_tokens" add constraint "fcm_tokens_platform_check" CHECK ((platform = ANY (ARRAY['android'::text, 'ios'::text]))) not valid;

alter table "public"."fcm_tokens" validate constraint "fcm_tokens_platform_check";

alter table "public"."fcm_tokens" add constraint "fcm_tokens_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE not valid;

alter table "public"."fcm_tokens" validate constraint "fcm_tokens_user_id_fkey";

alter table "public"."fcm_tokens" add constraint "fcm_tokens_user_id_token_key" UNIQUE using index "fcm_tokens_user_id_token_key";

alter table "public"."notifications" add constraint "notifications_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE not valid;

alter table "public"."notifications" validate constraint "notifications_user_id_fkey";

alter table "public"."notifications" add constraint "notifications_user_id_idempotency_key_key" UNIQUE using index "notifications_user_id_idempotency_key_key";

alter table "public"."pin_photos" add constraint "pin_photos_pin_id_fkey" FOREIGN KEY (pin_id) REFERENCES public.pins(id) ON DELETE CASCADE not valid;

alter table "public"."pin_photos" validate constraint "pin_photos_pin_id_fkey";

alter table "public"."pin_photos" add constraint "pin_photos_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE not valid;

alter table "public"."pin_photos" validate constraint "pin_photos_user_id_fkey";

alter table "public"."pins" add constraint "pins_pin_type_check" CHECK ((pin_type = ANY (ARRAY['visited'::text, 'bucket_list'::text]))) not valid;

alter table "public"."pins" validate constraint "pins_pin_type_check";

alter table "public"."pins" add constraint "pins_source_check" CHECK ((source = ANY (ARRAY['manual'::text, 'photo_library'::text]))) not valid;

alter table "public"."pins" validate constraint "pins_source_check";

alter table "public"."pins" add constraint "pins_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE not valid;

alter table "public"."pins" validate constraint "pins_user_id_fkey";

alter table "public"."profiles" add constraint "profiles_username_key" UNIQUE using index "profiles_username_key";

alter table "public"."stop_photos" add constraint "stop_photos_stop_id_fkey" FOREIGN KEY (stop_id) REFERENCES public.stops(id) ON DELETE CASCADE not valid;

alter table "public"."stop_photos" validate constraint "stop_photos_stop_id_fkey";

alter table "public"."stop_photos" add constraint "stop_photos_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE not valid;

alter table "public"."stop_photos" validate constraint "stop_photos_user_id_fkey";

alter table "public"."stops" add constraint "stops_trip_id_fkey" FOREIGN KEY (trip_id) REFERENCES public.trips(id) ON DELETE CASCADE not valid;

alter table "public"."stops" validate constraint "stops_trip_id_fkey";

alter table "public"."stops" add constraint "stops_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE not valid;

alter table "public"."stops" validate constraint "stops_user_id_fkey";

alter table "public"."track_points" add constraint "track_points_trip_id_fkey" FOREIGN KEY (trip_id) REFERENCES public.trips(id) ON DELETE CASCADE not valid;

alter table "public"."track_points" validate constraint "track_points_trip_id_fkey";

alter table "public"."track_points" add constraint "track_points_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE not valid;

alter table "public"."track_points" validate constraint "track_points_user_id_fkey";

alter table "public"."trip_activities" add constraint "trip_activities_booking_id_fkey" FOREIGN KEY (booking_id) REFERENCES public.trip_bookings(id) ON DELETE SET NULL not valid;

alter table "public"."trip_activities" validate constraint "trip_activities_booking_id_fkey";

alter table "public"."trip_activities" add constraint "trip_activities_category_check" CHECK ((category = ANY (ARRAY['attraction'::text, 'restaurant'::text, 'transport'::text, 'shopping'::text, 'nature'::text, 'nightlife'::text, 'custom'::text]))) not valid;

alter table "public"."trip_activities" validate constraint "trip_activities_category_check";

alter table "public"."trip_activities" add constraint "trip_activities_source_check" CHECK ((source = ANY (ARRAY['manual'::text, 'ai_suggestion'::text, 'search'::text]))) not valid;

alter table "public"."trip_activities" validate constraint "trip_activities_source_check";

alter table "public"."trip_activities" add constraint "valid_travel_mode" CHECK ((travel_mode = ANY (ARRAY['driving'::text, 'walking'::text, 'transit'::text, 'bicycling'::text]))) not valid;

alter table "public"."trip_activities" validate constraint "valid_travel_mode";

alter table "public"."trip_activity_attachments" add constraint "trip_activity_attachments_attachment_type_check" CHECK ((attachment_type = ANY (ARRAY['photo'::text, 'file'::text, 'link'::text]))) not valid;

alter table "public"."trip_activity_attachments" validate constraint "trip_activity_attachments_attachment_type_check";

alter table "public"."trip_activity_attachments" add constraint "trip_activity_attachments_trip_id_fkey" FOREIGN KEY (trip_id) REFERENCES public.trips(id) ON DELETE CASCADE not valid;

alter table "public"."trip_activity_attachments" validate constraint "trip_activity_attachments_trip_id_fkey";

alter table "public"."trip_activity_attachments" add constraint "trip_activity_attachments_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE not valid;

alter table "public"."trip_activity_attachments" validate constraint "trip_activity_attachments_user_id_fkey";

alter table "public"."trip_activity_attachments" add constraint "valid_attachment" CHECK ((((attachment_type = ANY (ARRAY['photo'::text, 'file'::text])) AND (storage_path IS NOT NULL)) OR ((attachment_type = 'link'::text) AND (url IS NOT NULL)))) not valid;

alter table "public"."trip_activity_attachments" validate constraint "valid_attachment";

alter table "public"."trip_booking_attachments" add constraint "trip_booking_attachments_booking_id_fkey" FOREIGN KEY (booking_id) REFERENCES public.trip_bookings(id) ON DELETE CASCADE not valid;

alter table "public"."trip_booking_attachments" validate constraint "trip_booking_attachments_booking_id_fkey";

alter table "public"."trip_booking_attachments" add constraint "trip_booking_attachments_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE not valid;

alter table "public"."trip_booking_attachments" validate constraint "trip_booking_attachments_user_id_fkey";

alter table "public"."trip_bookings" add constraint "trip_bookings_kind_check" CHECK ((kind = ANY (ARRAY['flight'::text, 'car'::text, 'lodging'::text, 'restaurant'::text, 'train'::text, 'bus'::text, 'ferry'::text, 'cruise'::text, 'concert'::text, 'theater'::text, 'tour'::text]))) not valid;

alter table "public"."trip_bookings" validate constraint "trip_bookings_kind_check";

alter table "public"."trip_bookings" add constraint "trip_bookings_source_check" CHECK ((source = ANY (ARRAY['manual'::text, 'upload'::text, 'email'::text]))) not valid;

alter table "public"."trip_bookings" validate constraint "trip_bookings_source_check";

alter table "public"."trip_budgets" add constraint "trip_budgets_category_check" CHECK ((category = ANY (ARRAY['flight'::text, 'lodging'::text, 'car'::text, 'food'::text, 'activities'::text, 'shopping'::text, 'transport'::text, 'other'::text]))) not valid;

alter table "public"."trip_budgets" validate constraint "trip_budgets_category_check";

alter table "public"."trip_budgets" add constraint "trip_budgets_trip_id_category_key" UNIQUE using index "trip_budgets_trip_id_category_key";

alter table "public"."trip_budgets" add constraint "trip_budgets_trip_id_fkey" FOREIGN KEY (trip_id) REFERENCES public.trips(id) ON DELETE CASCADE not valid;

alter table "public"."trip_budgets" validate constraint "trip_budgets_trip_id_fkey";

alter table "public"."trip_budgets" add constraint "trip_budgets_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE not valid;

alter table "public"."trip_budgets" validate constraint "trip_budgets_user_id_fkey";

alter table "public"."trip_expenses" add constraint "trip_expenses_booking_id_fkey" FOREIGN KEY (booking_id) REFERENCES public.trip_bookings(id) ON DELETE SET NULL not valid;

alter table "public"."trip_expenses" validate constraint "trip_expenses_booking_id_fkey";

alter table "public"."trip_expenses" add constraint "trip_expenses_category_check" CHECK ((category = ANY (ARRAY['flight'::text, 'lodging'::text, 'car'::text, 'food'::text, 'activities'::text, 'shopping'::text, 'transport'::text, 'other'::text]))) not valid;

alter table "public"."trip_expenses" validate constraint "trip_expenses_category_check";

alter table "public"."trip_expenses" add constraint "trip_expenses_split_type_check" CHECK ((split_type = ANY (ARRAY['equal'::text, 'exact'::text, 'percentage'::text, 'full'::text]))) not valid;

alter table "public"."trip_expenses" validate constraint "trip_expenses_split_type_check";

alter table "public"."trip_routes" add constraint "trip_routes_trip_id_day_number_origin_lat_origin_lng_dest_l_key" UNIQUE using index "trip_routes_trip_id_day_number_origin_lat_origin_lng_dest_l_key";

alter table "public"."trip_routes" add constraint "trip_routes_trip_id_fkey" FOREIGN KEY (trip_id) REFERENCES public.trips(id) ON DELETE CASCADE not valid;

alter table "public"."trip_routes" validate constraint "trip_routes_trip_id_fkey";

alter table "public"."trips" add constraint "trips_privacy_check" CHECK ((privacy = ANY (ARRAY['private'::text, 'public'::text]))) not valid;

alter table "public"."trips" validate constraint "trips_privacy_check";

alter table "public"."trips" add constraint "trips_status_check" CHECK ((status = ANY (ARRAY['planned'::text, 'active'::text, 'completed'::text]))) not valid;

alter table "public"."trips" validate constraint "trips_status_check";

alter table "public"."user_forwarding_addresses" add constraint "user_forwarding_addresses_address_token_key" UNIQUE using index "user_forwarding_addresses_address_token_key";

alter table "public"."user_forwarding_addresses" add constraint "user_forwarding_addresses_trip_id_fkey" FOREIGN KEY (trip_id) REFERENCES public.trips(id) ON DELETE CASCADE not valid;

alter table "public"."user_forwarding_addresses" validate constraint "user_forwarding_addresses_trip_id_fkey";

alter table "public"."user_forwarding_addresses" add constraint "user_forwarding_addresses_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE not valid;

alter table "public"."user_forwarding_addresses" validate constraint "user_forwarding_addresses_user_id_fkey";

alter table "public"."user_forwarding_addresses" add constraint "user_forwarding_addresses_user_trip_unique" UNIQUE using index "user_forwarding_addresses_user_trip_unique";

alter table "public"."user_stats" add constraint "user_stats_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE not valid;

alter table "public"."user_stats" validate constraint "user_stats_user_id_fkey";

alter table "public"."checklist_items" add constraint "checklist_items_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE not valid;

alter table "public"."checklist_items" validate constraint "checklist_items_user_id_fkey";

alter table "public"."trip_activities" add constraint "trip_activities_day_id_fkey" FOREIGN KEY (day_id) REFERENCES public.trip_days(id) ON DELETE CASCADE not valid;

alter table "public"."trip_activities" validate constraint "trip_activities_day_id_fkey";

alter table "public"."trip_activities" add constraint "trip_activities_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE not valid;

alter table "public"."trip_activities" validate constraint "trip_activities_user_id_fkey";

alter table "public"."trip_bookings" add constraint "trip_bookings_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE not valid;

alter table "public"."trip_bookings" validate constraint "trip_bookings_user_id_fkey";

alter table "public"."trip_checklists" add constraint "trip_checklists_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE not valid;

alter table "public"."trip_checklists" validate constraint "trip_checklists_user_id_fkey";

alter table "public"."trip_collaborators" add constraint "trip_collaborators_role_check" CHECK ((role = ANY (ARRAY['viewer'::text, 'editor'::text]))) not valid;

alter table "public"."trip_collaborators" validate constraint "trip_collaborators_role_check";

alter table "public"."trip_days" add constraint "trip_days_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE not valid;

alter table "public"."trip_days" validate constraint "trip_days_user_id_fkey";

alter table "public"."trip_expenses" add constraint "trip_expenses_amount_check" CHECK ((amount > (0)::numeric)) not valid;

alter table "public"."trip_expenses" validate constraint "trip_expenses_amount_check";

alter table "public"."trip_notes" add constraint "trip_notes_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE not valid;

alter table "public"."trip_notes" validate constraint "trip_notes_user_id_fkey";

alter table "public"."trips" add constraint "trips_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE not valid;

alter table "public"."trips" validate constraint "trips_user_id_fkey";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.current_user_is_trip_editor(p_trip_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select public.is_trip_editor(p_trip_id, auth.uid());
$function$
;

CREATE OR REPLACE FUNCTION public.handle_new_profile()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  insert into public.user_stats (user_id) values (new.id);
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  insert into public.profiles (id, username, display_name)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'username', split_part(new.email, '@', 1)),
    coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email, '@', 1))
  );
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.handle_pins_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  affected_uid uuid;
begin
  affected_uid := case TG_OP when 'DELETE' then old.user_id else new.user_id end;
  perform public.recalculate_user_stats(affected_uid);
  return null;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.handle_trips_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  affected_uid uuid;
begin
  affected_uid := case TG_OP when 'DELETE' then old.user_id else new.user_id end;
  perform public.recalculate_user_stats(affected_uid);
  return null;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.handle_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  new.updated_at = now();
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.is_trip_owner(p_trip_id uuid, p_user_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1 from public.trips t
    where t.id = p_trip_id and t.user_id = p_user_id
  );
$function$
;

CREATE OR REPLACE FUNCTION public.notify_todays_bookings()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r record;
begin
  for r in
    select b.id as booking_id, b.title, b.kind, b.user_id,
           t.id as trip_id, t.name as trip_name
    from trip_bookings b
    join trips t on t.id = b.trip_id
    where b.starts_at::date = current_date
  loop
    perform send_push_notification(
      r.user_id,
      'booking_reminder',
      'Booking today',
      r.title || ' is today (' || r.trip_name || ').',
      jsonb_build_object('tripId', r.trip_id, 'bookingId', r.booking_id),
      'booking_reminder:' || r.booking_id || ':' || current_date
    );
  end loop;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.notify_upcoming_trips()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r record;
begin
  for r in
    select t.id as trip_id, t.user_id, t.name as trip_name
    from trips t
    where t.start_date = current_date + 1
      and t.status = 'planned'
  loop
    perform send_push_notification(
      r.user_id,
      'trip_reminder',
      'Trip starts tomorrow',
      'Your trip "' || r.trip_name || '" starts tomorrow. Have a great time!',
      jsonb_build_object('tripId', r.trip_id),
      'trip_reminder:' || r.trip_id || ':' || current_date
    );
  end loop;

  for r in
    select tc.collaborator_id as user_id, t.id as trip_id, t.name as trip_name
    from trips t
    join trip_collaborators tc on tc.trip_id = t.id
    where t.start_date = current_date + 1
      and t.status = 'planned'
      and tc.status = 'accepted'
  loop
    perform send_push_notification(
      r.user_id,
      'trip_reminder',
      'Trip starts tomorrow',
      'The trip "' || r.trip_name || '" starts tomorrow. Have a great time!',
      jsonb_build_object('tripId', r.trip_id),
      'trip_reminder:' || r.trip_id || ':' || r.user_id || ':' || current_date
    );
  end loop;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.recalculate_user_stats(uid uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  insert into public.user_stats (
    user_id,
    countries_visited,
    total_trips,
    total_distance_km,
    total_pins,
    updated_at
  )
  values (
    uid,
    (select count(distinct country_code)
       from public.pins
      where user_id = uid and country_code is not null),
    (select count(*) from public.trips where user_id = uid),
    0,  -- distance is tracked separately via trip routes
    (select count(*) from public.pins where user_id = uid),
    now()
  )
  on conflict (user_id) do update set
    countries_visited = excluded.countries_visited,
    total_trips       = excluded.total_trips,
    total_distance_km = excluded.total_distance_km,
    total_pins        = excluded.total_pins,
    updated_at        = excluded.updated_at;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.send_push_notification(p_user_id uuid, p_type text, p_title text, p_body text, p_data jsonb DEFAULT '{}'::jsonb, p_idempotency text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_url  text;
  v_key  text;
  v_body jsonb;
begin
  v_url := current_setting('app.settings.supabase_url', true)
           || '/functions/v1/send-notification';
  v_key := current_setting('app.settings.service_role_key', true);

  if v_url is null or v_url = '' then
    v_url := (select decrypted_secret from vault.decrypted_secrets where name = 'supabase_url' limit 1)
             || '/functions/v1/send-notification';
  end if;
  if v_key is null or v_key = '' then
    v_key := (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key' limit 1);
  end if;

  v_body := jsonb_build_object(
    'userId', p_user_id,
    'type', p_type,
    'title', p_title,
    'body', p_body,
    'data', p_data
  );
  if p_idempotency is not null then
    v_body := v_body || jsonb_build_object('idempotencyKey', p_idempotency);
  end if;

  perform net.http_post(
    url     := v_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_key
    ),
    body    := v_body
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.trips_prevent_collaborator_rename()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if auth.uid() is distinct from new.user_id
     and new.name is distinct from old.name then
    raise exception 'ONLY_OWNER_CAN_RENAME_TRIP'
      using errcode = 'P0001',
            message = 'Only the trip owner can change the trip name';
  end if;
  return new;
end;
$function$
;

grant delete on table "public"."expense_splits" to "anon";

grant insert on table "public"."expense_splits" to "anon";

grant references on table "public"."expense_splits" to "anon";

grant select on table "public"."expense_splits" to "anon";

grant trigger on table "public"."expense_splits" to "anon";

grant truncate on table "public"."expense_splits" to "anon";

grant update on table "public"."expense_splits" to "anon";

grant delete on table "public"."expense_splits" to "authenticated";

grant insert on table "public"."expense_splits" to "authenticated";

grant references on table "public"."expense_splits" to "authenticated";

grant select on table "public"."expense_splits" to "authenticated";

grant trigger on table "public"."expense_splits" to "authenticated";

grant truncate on table "public"."expense_splits" to "authenticated";

grant update on table "public"."expense_splits" to "authenticated";

grant delete on table "public"."expense_splits" to "service_role";

grant insert on table "public"."expense_splits" to "service_role";

grant references on table "public"."expense_splits" to "service_role";

grant select on table "public"."expense_splits" to "service_role";

grant trigger on table "public"."expense_splits" to "service_role";

grant truncate on table "public"."expense_splits" to "service_role";

grant update on table "public"."expense_splits" to "service_role";

grant delete on table "public"."fcm_tokens" to "anon";

grant insert on table "public"."fcm_tokens" to "anon";

grant references on table "public"."fcm_tokens" to "anon";

grant select on table "public"."fcm_tokens" to "anon";

grant trigger on table "public"."fcm_tokens" to "anon";

grant truncate on table "public"."fcm_tokens" to "anon";

grant update on table "public"."fcm_tokens" to "anon";

grant delete on table "public"."fcm_tokens" to "authenticated";

grant insert on table "public"."fcm_tokens" to "authenticated";

grant references on table "public"."fcm_tokens" to "authenticated";

grant select on table "public"."fcm_tokens" to "authenticated";

grant trigger on table "public"."fcm_tokens" to "authenticated";

grant truncate on table "public"."fcm_tokens" to "authenticated";

grant update on table "public"."fcm_tokens" to "authenticated";

grant delete on table "public"."fcm_tokens" to "service_role";

grant insert on table "public"."fcm_tokens" to "service_role";

grant references on table "public"."fcm_tokens" to "service_role";

grant select on table "public"."fcm_tokens" to "service_role";

grant trigger on table "public"."fcm_tokens" to "service_role";

grant truncate on table "public"."fcm_tokens" to "service_role";

grant update on table "public"."fcm_tokens" to "service_role";

grant delete on table "public"."notifications" to "anon";

grant insert on table "public"."notifications" to "anon";

grant references on table "public"."notifications" to "anon";

grant select on table "public"."notifications" to "anon";

grant trigger on table "public"."notifications" to "anon";

grant truncate on table "public"."notifications" to "anon";

grant update on table "public"."notifications" to "anon";

grant delete on table "public"."notifications" to "authenticated";

grant insert on table "public"."notifications" to "authenticated";

grant references on table "public"."notifications" to "authenticated";

grant select on table "public"."notifications" to "authenticated";

grant trigger on table "public"."notifications" to "authenticated";

grant truncate on table "public"."notifications" to "authenticated";

grant update on table "public"."notifications" to "authenticated";

grant delete on table "public"."notifications" to "service_role";

grant insert on table "public"."notifications" to "service_role";

grant references on table "public"."notifications" to "service_role";

grant select on table "public"."notifications" to "service_role";

grant trigger on table "public"."notifications" to "service_role";

grant truncate on table "public"."notifications" to "service_role";

grant update on table "public"."notifications" to "service_role";

grant delete on table "public"."pin_photos" to "anon";

grant insert on table "public"."pin_photos" to "anon";

grant references on table "public"."pin_photos" to "anon";

grant select on table "public"."pin_photos" to "anon";

grant trigger on table "public"."pin_photos" to "anon";

grant truncate on table "public"."pin_photos" to "anon";

grant update on table "public"."pin_photos" to "anon";

grant delete on table "public"."pin_photos" to "authenticated";

grant insert on table "public"."pin_photos" to "authenticated";

grant references on table "public"."pin_photos" to "authenticated";

grant select on table "public"."pin_photos" to "authenticated";

grant trigger on table "public"."pin_photos" to "authenticated";

grant truncate on table "public"."pin_photos" to "authenticated";

grant update on table "public"."pin_photos" to "authenticated";

grant delete on table "public"."pin_photos" to "service_role";

grant insert on table "public"."pin_photos" to "service_role";

grant references on table "public"."pin_photos" to "service_role";

grant select on table "public"."pin_photos" to "service_role";

grant trigger on table "public"."pin_photos" to "service_role";

grant truncate on table "public"."pin_photos" to "service_role";

grant update on table "public"."pin_photos" to "service_role";

grant delete on table "public"."pins" to "anon";

grant insert on table "public"."pins" to "anon";

grant references on table "public"."pins" to "anon";

grant select on table "public"."pins" to "anon";

grant trigger on table "public"."pins" to "anon";

grant truncate on table "public"."pins" to "anon";

grant update on table "public"."pins" to "anon";

grant delete on table "public"."pins" to "authenticated";

grant insert on table "public"."pins" to "authenticated";

grant references on table "public"."pins" to "authenticated";

grant select on table "public"."pins" to "authenticated";

grant trigger on table "public"."pins" to "authenticated";

grant truncate on table "public"."pins" to "authenticated";

grant update on table "public"."pins" to "authenticated";

grant delete on table "public"."pins" to "service_role";

grant insert on table "public"."pins" to "service_role";

grant references on table "public"."pins" to "service_role";

grant select on table "public"."pins" to "service_role";

grant trigger on table "public"."pins" to "service_role";

grant truncate on table "public"."pins" to "service_role";

grant update on table "public"."pins" to "service_role";

grant delete on table "public"."stop_photos" to "anon";

grant insert on table "public"."stop_photos" to "anon";

grant references on table "public"."stop_photos" to "anon";

grant select on table "public"."stop_photos" to "anon";

grant trigger on table "public"."stop_photos" to "anon";

grant truncate on table "public"."stop_photos" to "anon";

grant update on table "public"."stop_photos" to "anon";

grant delete on table "public"."stop_photos" to "authenticated";

grant insert on table "public"."stop_photos" to "authenticated";

grant references on table "public"."stop_photos" to "authenticated";

grant select on table "public"."stop_photos" to "authenticated";

grant trigger on table "public"."stop_photos" to "authenticated";

grant truncate on table "public"."stop_photos" to "authenticated";

grant update on table "public"."stop_photos" to "authenticated";

grant delete on table "public"."stop_photos" to "service_role";

grant insert on table "public"."stop_photos" to "service_role";

grant references on table "public"."stop_photos" to "service_role";

grant select on table "public"."stop_photos" to "service_role";

grant trigger on table "public"."stop_photos" to "service_role";

grant truncate on table "public"."stop_photos" to "service_role";

grant update on table "public"."stop_photos" to "service_role";

grant delete on table "public"."stops" to "anon";

grant insert on table "public"."stops" to "anon";

grant references on table "public"."stops" to "anon";

grant select on table "public"."stops" to "anon";

grant trigger on table "public"."stops" to "anon";

grant truncate on table "public"."stops" to "anon";

grant update on table "public"."stops" to "anon";

grant delete on table "public"."stops" to "authenticated";

grant insert on table "public"."stops" to "authenticated";

grant references on table "public"."stops" to "authenticated";

grant select on table "public"."stops" to "authenticated";

grant trigger on table "public"."stops" to "authenticated";

grant truncate on table "public"."stops" to "authenticated";

grant update on table "public"."stops" to "authenticated";

grant delete on table "public"."stops" to "service_role";

grant insert on table "public"."stops" to "service_role";

grant references on table "public"."stops" to "service_role";

grant select on table "public"."stops" to "service_role";

grant trigger on table "public"."stops" to "service_role";

grant truncate on table "public"."stops" to "service_role";

grant update on table "public"."stops" to "service_role";

grant delete on table "public"."track_points" to "anon";

grant insert on table "public"."track_points" to "anon";

grant references on table "public"."track_points" to "anon";

grant select on table "public"."track_points" to "anon";

grant trigger on table "public"."track_points" to "anon";

grant truncate on table "public"."track_points" to "anon";

grant update on table "public"."track_points" to "anon";

grant delete on table "public"."track_points" to "authenticated";

grant insert on table "public"."track_points" to "authenticated";

grant references on table "public"."track_points" to "authenticated";

grant select on table "public"."track_points" to "authenticated";

grant trigger on table "public"."track_points" to "authenticated";

grant truncate on table "public"."track_points" to "authenticated";

grant update on table "public"."track_points" to "authenticated";

grant delete on table "public"."track_points" to "service_role";

grant insert on table "public"."track_points" to "service_role";

grant references on table "public"."track_points" to "service_role";

grant select on table "public"."track_points" to "service_role";

grant trigger on table "public"."track_points" to "service_role";

grant truncate on table "public"."track_points" to "service_role";

grant update on table "public"."track_points" to "service_role";

grant delete on table "public"."trip_booking_attachments" to "anon";

grant insert on table "public"."trip_booking_attachments" to "anon";

grant references on table "public"."trip_booking_attachments" to "anon";

grant select on table "public"."trip_booking_attachments" to "anon";

grant trigger on table "public"."trip_booking_attachments" to "anon";

grant truncate on table "public"."trip_booking_attachments" to "anon";

grant update on table "public"."trip_booking_attachments" to "anon";

grant delete on table "public"."trip_booking_attachments" to "authenticated";

grant insert on table "public"."trip_booking_attachments" to "authenticated";

grant references on table "public"."trip_booking_attachments" to "authenticated";

grant select on table "public"."trip_booking_attachments" to "authenticated";

grant trigger on table "public"."trip_booking_attachments" to "authenticated";

grant truncate on table "public"."trip_booking_attachments" to "authenticated";

grant update on table "public"."trip_booking_attachments" to "authenticated";

grant delete on table "public"."trip_booking_attachments" to "service_role";

grant insert on table "public"."trip_booking_attachments" to "service_role";

grant references on table "public"."trip_booking_attachments" to "service_role";

grant select on table "public"."trip_booking_attachments" to "service_role";

grant trigger on table "public"."trip_booking_attachments" to "service_role";

grant truncate on table "public"."trip_booking_attachments" to "service_role";

grant update on table "public"."trip_booking_attachments" to "service_role";

grant delete on table "public"."trip_budgets" to "anon";

grant insert on table "public"."trip_budgets" to "anon";

grant references on table "public"."trip_budgets" to "anon";

grant select on table "public"."trip_budgets" to "anon";

grant trigger on table "public"."trip_budgets" to "anon";

grant truncate on table "public"."trip_budgets" to "anon";

grant update on table "public"."trip_budgets" to "anon";

grant delete on table "public"."trip_budgets" to "authenticated";

grant insert on table "public"."trip_budgets" to "authenticated";

grant references on table "public"."trip_budgets" to "authenticated";

grant select on table "public"."trip_budgets" to "authenticated";

grant trigger on table "public"."trip_budgets" to "authenticated";

grant truncate on table "public"."trip_budgets" to "authenticated";

grant update on table "public"."trip_budgets" to "authenticated";

grant delete on table "public"."trip_budgets" to "service_role";

grant insert on table "public"."trip_budgets" to "service_role";

grant references on table "public"."trip_budgets" to "service_role";

grant select on table "public"."trip_budgets" to "service_role";

grant trigger on table "public"."trip_budgets" to "service_role";

grant truncate on table "public"."trip_budgets" to "service_role";

grant update on table "public"."trip_budgets" to "service_role";

grant delete on table "public"."trip_routes" to "anon";

grant insert on table "public"."trip_routes" to "anon";

grant references on table "public"."trip_routes" to "anon";

grant select on table "public"."trip_routes" to "anon";

grant trigger on table "public"."trip_routes" to "anon";

grant truncate on table "public"."trip_routes" to "anon";

grant update on table "public"."trip_routes" to "anon";

grant delete on table "public"."trip_routes" to "authenticated";

grant insert on table "public"."trip_routes" to "authenticated";

grant references on table "public"."trip_routes" to "authenticated";

grant select on table "public"."trip_routes" to "authenticated";

grant trigger on table "public"."trip_routes" to "authenticated";

grant truncate on table "public"."trip_routes" to "authenticated";

grant update on table "public"."trip_routes" to "authenticated";

grant delete on table "public"."trip_routes" to "service_role";

grant insert on table "public"."trip_routes" to "service_role";

grant references on table "public"."trip_routes" to "service_role";

grant select on table "public"."trip_routes" to "service_role";

grant trigger on table "public"."trip_routes" to "service_role";

grant truncate on table "public"."trip_routes" to "service_role";

grant update on table "public"."trip_routes" to "service_role";

grant delete on table "public"."user_forwarding_addresses" to "anon";

grant insert on table "public"."user_forwarding_addresses" to "anon";

grant references on table "public"."user_forwarding_addresses" to "anon";

grant select on table "public"."user_forwarding_addresses" to "anon";

grant trigger on table "public"."user_forwarding_addresses" to "anon";

grant truncate on table "public"."user_forwarding_addresses" to "anon";

grant update on table "public"."user_forwarding_addresses" to "anon";

grant delete on table "public"."user_forwarding_addresses" to "authenticated";

grant insert on table "public"."user_forwarding_addresses" to "authenticated";

grant references on table "public"."user_forwarding_addresses" to "authenticated";

grant select on table "public"."user_forwarding_addresses" to "authenticated";

grant trigger on table "public"."user_forwarding_addresses" to "authenticated";

grant truncate on table "public"."user_forwarding_addresses" to "authenticated";

grant update on table "public"."user_forwarding_addresses" to "authenticated";

grant delete on table "public"."user_forwarding_addresses" to "service_role";

grant insert on table "public"."user_forwarding_addresses" to "service_role";

grant references on table "public"."user_forwarding_addresses" to "service_role";

grant select on table "public"."user_forwarding_addresses" to "service_role";

grant trigger on table "public"."user_forwarding_addresses" to "service_role";

grant truncate on table "public"."user_forwarding_addresses" to "service_role";

grant update on table "public"."user_forwarding_addresses" to "service_role";

grant delete on table "public"."user_stats" to "anon";

grant insert on table "public"."user_stats" to "anon";

grant references on table "public"."user_stats" to "anon";

grant select on table "public"."user_stats" to "anon";

grant trigger on table "public"."user_stats" to "anon";

grant truncate on table "public"."user_stats" to "anon";

grant update on table "public"."user_stats" to "anon";

grant delete on table "public"."user_stats" to "authenticated";

grant insert on table "public"."user_stats" to "authenticated";

grant references on table "public"."user_stats" to "authenticated";

grant select on table "public"."user_stats" to "authenticated";

grant trigger on table "public"."user_stats" to "authenticated";

grant truncate on table "public"."user_stats" to "authenticated";

grant update on table "public"."user_stats" to "authenticated";

grant delete on table "public"."user_stats" to "service_role";

grant insert on table "public"."user_stats" to "service_role";

grant references on table "public"."user_stats" to "service_role";

grant select on table "public"."user_stats" to "service_role";

grant trigger on table "public"."user_stats" to "service_role";

grant truncate on table "public"."user_stats" to "service_role";

grant update on table "public"."user_stats" to "service_role";


  create policy "Editors can delete checklist items"
  on "public"."checklist_items"
  as permissive
  for delete
  to public
using ((EXISTS ( SELECT 1
   FROM public.trip_checklists tc
  WHERE ((tc.id = checklist_items.checklist_id) AND public.is_trip_editor(tc.trip_id, auth.uid())))));



  create policy "Editors can manage checklist items"
  on "public"."checklist_items"
  as permissive
  for insert
  to public
with check ((EXISTS ( SELECT 1
   FROM public.trip_checklists tc
  WHERE ((tc.id = checklist_items.checklist_id) AND public.is_trip_editor(tc.trip_id, auth.uid())))));



  create policy "Editors can update checklist items"
  on "public"."checklist_items"
  as permissive
  for update
  to public
using ((EXISTS ( SELECT 1
   FROM public.trip_checklists tc
  WHERE ((tc.id = checklist_items.checklist_id) AND public.is_trip_editor(tc.trip_id, auth.uid())))));



  create policy "Members can view checklist items"
  on "public"."checklist_items"
  as permissive
  for select
  to public
using ((EXISTS ( SELECT 1
   FROM public.trip_checklists tc
  WHERE ((tc.id = checklist_items.checklist_id) AND public.is_trip_member(tc.trip_id, auth.uid())))));



  create policy "Owner full access to checklist items"
  on "public"."checklist_items"
  as permissive
  for all
  to public
using ((auth.uid() = user_id));



  create policy "Users see own forwarded emails"
  on "public"."email_forwarding_queue"
  as permissive
  for select
  to public
using ((auth.uid() = user_id));



  create policy "Expense creator can delete splits"
  on "public"."expense_splits"
  as permissive
  for delete
  to authenticated
using ((EXISTS ( SELECT 1
   FROM public.trip_expenses e
  WHERE ((e.id = expense_splits.expense_id) AND (e.payer_user_id = ( SELECT auth.uid() AS uid))))));



  create policy "Expense creator can update splits"
  on "public"."expense_splits"
  as permissive
  for update
  to authenticated
using ((EXISTS ( SELECT 1
   FROM public.trip_expenses e
  WHERE ((e.id = expense_splits.expense_id) AND (e.payer_user_id = ( SELECT auth.uid() AS uid))))));



  create policy "Members can insert splits"
  on "public"."expense_splits"
  as permissive
  for insert
  to public
with check ((EXISTS ( SELECT 1
   FROM public.trip_expenses te
  WHERE ((te.id = expense_splits.expense_id) AND public.is_trip_member(te.trip_id, auth.uid())))));



  create policy "Members can view splits"
  on "public"."expense_splits"
  as permissive
  for select
  to public
using ((EXISTS ( SELECT 1
   FROM public.trip_expenses te
  WHERE ((te.id = expense_splits.expense_id) AND public.is_trip_member(te.trip_id, auth.uid())))));



  create policy "Users manage own FCM tokens"
  on "public"."fcm_tokens"
  as permissive
  for all
  to public
using ((auth.uid() = user_id))
with check ((auth.uid() = user_id));



  create policy "Service role can insert notifications"
  on "public"."notifications"
  as permissive
  for insert
  to public
with check (true);



  create policy "Users can mark own notifications as read"
  on "public"."notifications"
  as permissive
  for update
  to public
using ((auth.uid() = user_id))
with check ((auth.uid() = user_id));



  create policy "Users can read own notifications"
  on "public"."notifications"
  as permissive
  for select
  to public
using ((auth.uid() = user_id));



  create policy "Users can delete their own pin photos"
  on "public"."pin_photos"
  as permissive
  for delete
  to public
using ((auth.uid() = user_id));



  create policy "Users can insert their own pin photos"
  on "public"."pin_photos"
  as permissive
  for insert
  to public
with check ((auth.uid() = user_id));



  create policy "Users can view their own pin photos"
  on "public"."pin_photos"
  as permissive
  for select
  to public
using ((auth.uid() = user_id));



  create policy "Users can create pins"
  on "public"."pins"
  as permissive
  for insert
  to public
with check ((auth.uid() = user_id));



  create policy "Users can delete their own pins"
  on "public"."pins"
  as permissive
  for delete
  to public
using ((auth.uid() = user_id));



  create policy "Users can update their own pins"
  on "public"."pins"
  as permissive
  for update
  to public
using ((auth.uid() = user_id));



  create policy "Users can view their own pins"
  on "public"."pins"
  as permissive
  for select
  to public
using ((auth.uid() = user_id));



  create policy "Service role full access on place_cache"
  on "public"."place_cache"
  as permissive
  for all
  to public
using (true)
with check (true);



  create policy "Public profiles are viewable by everyone"
  on "public"."profiles"
  as permissive
  for select
  to public
using (true);



  create policy "Users can delete their own profile"
  on "public"."profiles"
  as permissive
  for delete
  to public
using ((auth.uid() = id));



  create policy "Users can insert their own profile"
  on "public"."profiles"
  as permissive
  for insert
  to public
with check ((auth.uid() = id));



  create policy "Users can update their own profile"
  on "public"."profiles"
  as permissive
  for update
  to public
using ((auth.uid() = id));



  create policy "Stop photos of public trips are viewable"
  on "public"."stop_photos"
  as permissive
  for select
  to public
using ((EXISTS ( SELECT 1
   FROM (public.stops s
     JOIN public.trips t ON ((t.id = s.trip_id)))
  WHERE ((s.id = stop_photos.stop_id) AND (t.privacy = 'public'::text)))));



  create policy "Users can delete their own stop photos"
  on "public"."stop_photos"
  as permissive
  for delete
  to public
using ((auth.uid() = user_id));



  create policy "Users can insert their own stop photos"
  on "public"."stop_photos"
  as permissive
  for insert
  to public
with check ((auth.uid() = user_id));



  create policy "Users can view their own stop photos"
  on "public"."stop_photos"
  as permissive
  for select
  to public
using ((auth.uid() = user_id));



  create policy "Stops of public trips are viewable by everyone"
  on "public"."stops"
  as permissive
  for select
  to public
using ((EXISTS ( SELECT 1
   FROM public.trips t
  WHERE ((t.id = stops.trip_id) AND (t.privacy = 'public'::text)))));



  create policy "Users can create stops for their own trips"
  on "public"."stops"
  as permissive
  for insert
  to public
with check ((auth.uid() = user_id));



  create policy "Users can delete their own stops"
  on "public"."stops"
  as permissive
  for delete
  to public
using ((auth.uid() = user_id));



  create policy "Users can update their own stops"
  on "public"."stops"
  as permissive
  for update
  to public
using ((auth.uid() = user_id));



  create policy "Users can view stops of their own trips"
  on "public"."stops"
  as permissive
  for select
  to public
using ((auth.uid() = user_id));



  create policy "Users can delete their own track points"
  on "public"."track_points"
  as permissive
  for delete
  to public
using ((auth.uid() = user_id));



  create policy "Users can insert their own track points"
  on "public"."track_points"
  as permissive
  for insert
  to public
with check ((auth.uid() = user_id));



  create policy "Users can view their own track points"
  on "public"."track_points"
  as permissive
  for select
  to public
using ((auth.uid() = user_id));



  create policy "Editors can delete activities"
  on "public"."trip_activities"
  as permissive
  for delete
  to public
using (public.is_trip_editor(trip_id, auth.uid()));



  create policy "Editors can manage activities"
  on "public"."trip_activities"
  as permissive
  for insert
  to public
with check (public.is_trip_editor(trip_id, auth.uid()));



  create policy "Editors can update activities"
  on "public"."trip_activities"
  as permissive
  for update
  to public
using (public.is_trip_editor(trip_id, auth.uid()));



  create policy "Members can view activities"
  on "public"."trip_activities"
  as permissive
  for select
  to public
using (public.is_trip_member(trip_id, auth.uid()));



  create policy "Owner full access to activities"
  on "public"."trip_activities"
  as permissive
  for all
  to public
using ((auth.uid() = user_id));



  create policy "Owner full access to activity attachments"
  on "public"."trip_activity_attachments"
  as permissive
  for all
  to authenticated
using ((user_id = auth.uid()))
with check ((user_id = auth.uid()));



  create policy "Trip owner can delete booking attachments"
  on "public"."trip_booking_attachments"
  as permissive
  for delete
  to public
using ((EXISTS ( SELECT 1
   FROM public.trip_bookings tb
  WHERE ((tb.id = trip_booking_attachments.booking_id) AND public.is_trip_owner(tb.trip_id, auth.uid())))));



  create policy "Trip owner can insert booking attachments"
  on "public"."trip_booking_attachments"
  as permissive
  for insert
  to public
with check (((auth.uid() = user_id) AND (EXISTS ( SELECT 1
   FROM public.trip_bookings tb
  WHERE ((tb.id = trip_booking_attachments.booking_id) AND public.is_trip_owner(tb.trip_id, auth.uid()))))));



  create policy "Trip owner can update booking attachments"
  on "public"."trip_booking_attachments"
  as permissive
  for update
  to public
using ((EXISTS ( SELECT 1
   FROM public.trip_bookings tb
  WHERE ((tb.id = trip_booking_attachments.booking_id) AND public.is_trip_owner(tb.trip_id, auth.uid())))));



  create policy "Collaborators can view bookings"
  on "public"."trip_bookings"
  as permissive
  for select
  to public
using (public.is_trip_member(trip_id, auth.uid()));



  create policy "Trip owner can delete bookings"
  on "public"."trip_bookings"
  as permissive
  for delete
  to public
using (public.is_trip_owner(trip_id, auth.uid()));



  create policy "Trip owner can insert bookings"
  on "public"."trip_bookings"
  as permissive
  for insert
  to public
with check (public.is_trip_owner(trip_id, auth.uid()));



  create policy "Trip owner can update bookings"
  on "public"."trip_bookings"
  as permissive
  for update
  to public
using (public.is_trip_owner(trip_id, auth.uid()));



  create policy "Editors can update spent amounts"
  on "public"."trip_budgets"
  as permissive
  for update
  to public
using (public.is_trip_editor(trip_id, auth.uid()));



  create policy "Members can view budgets"
  on "public"."trip_budgets"
  as permissive
  for select
  to public
using (public.is_trip_member(trip_id, auth.uid()));



  create policy "Owner full access to budgets"
  on "public"."trip_budgets"
  as permissive
  for all
  to public
using ((auth.uid() = user_id));



  create policy "Editors can delete checklists"
  on "public"."trip_checklists"
  as permissive
  for delete
  to public
using (public.is_trip_editor(trip_id, auth.uid()));



  create policy "Editors can manage checklists"
  on "public"."trip_checklists"
  as permissive
  for insert
  to public
with check (public.is_trip_editor(trip_id, auth.uid()));



  create policy "Editors can update checklists"
  on "public"."trip_checklists"
  as permissive
  for update
  to public
using (public.is_trip_editor(trip_id, auth.uid()));



  create policy "Members can view checklists"
  on "public"."trip_checklists"
  as permissive
  for select
  to public
using (public.is_trip_member(trip_id, auth.uid()));



  create policy "Owner full access to checklists"
  on "public"."trip_checklists"
  as permissive
  for all
  to public
using ((auth.uid() = user_id));



  create policy "Editors can manage days"
  on "public"."trip_days"
  as permissive
  for insert
  to public
with check (public.is_trip_editor(trip_id, auth.uid()));



  create policy "Editors can update days"
  on "public"."trip_days"
  as permissive
  for update
  to public
using (public.is_trip_editor(trip_id, auth.uid()));



  create policy "Members can view days"
  on "public"."trip_days"
  as permissive
  for select
  to public
using (public.is_trip_member(trip_id, auth.uid()));



  create policy "Owner full access to days"
  on "public"."trip_days"
  as permissive
  for all
  to public
using ((auth.uid() = user_id));



  create policy "Members can insert expenses"
  on "public"."trip_expenses"
  as permissive
  for insert
  to public
with check (public.is_trip_member(trip_id, auth.uid()));



  create policy "Members can view expenses"
  on "public"."trip_expenses"
  as permissive
  for select
  to public
using (public.is_trip_member(trip_id, auth.uid()));



  create policy "Owner full access to notes"
  on "public"."trip_notes"
  as permissive
  for all
  to public
using ((auth.uid() = user_id));



  create policy "trip_routes_delete"
  on "public"."trip_routes"
  as permissive
  for delete
  to public
using (public.is_trip_editor(trip_id, auth.uid()));



  create policy "trip_routes_insert"
  on "public"."trip_routes"
  as permissive
  for insert
  to public
with check (public.is_trip_editor(trip_id, auth.uid()));



  create policy "trip_routes_select"
  on "public"."trip_routes"
  as permissive
  for select
  to public
using (public.is_trip_member(trip_id, auth.uid()));



  create policy "trip_routes_update"
  on "public"."trip_routes"
  as permissive
  for update
  to public
using (public.is_trip_editor(trip_id, auth.uid()));



  create policy "Editors can update shared trips"
  on "public"."trips"
  as permissive
  for update
  to public
using (public.is_trip_editor(id, auth.uid()))
with check (public.is_trip_editor(id, auth.uid()));



  create policy "Public trips are viewable by everyone"
  on "public"."trips"
  as permissive
  for select
  to public
using ((privacy = 'public'::text));



  create policy "Users can create trips"
  on "public"."trips"
  as permissive
  for insert
  to public
with check ((auth.uid() = user_id));



  create policy "Users can delete their own trips"
  on "public"."trips"
  as permissive
  for delete
  to public
using ((auth.uid() = user_id));



  create policy "Users can update their own trips"
  on "public"."trips"
  as permissive
  for update
  to public
using ((auth.uid() = user_id));



  create policy "Users can view their own trips"
  on "public"."trips"
  as permissive
  for select
  to public
using ((auth.uid() = user_id));



  create policy "Users manage own forwarding addresses"
  on "public"."user_forwarding_addresses"
  as permissive
  for all
  to public
using ((auth.uid() = user_id));



  create policy "Users see own forwarding addresses"
  on "public"."user_forwarding_addresses"
  as permissive
  for select
  to public
using ((auth.uid() = user_id));



  create policy "Stats are updatable by owner only"
  on "public"."user_stats"
  as permissive
  for update
  to public
using ((auth.uid() = user_id));



  create policy "Users can view their own stats"
  on "public"."user_stats"
  as permissive
  for select
  to public
using ((auth.uid() = user_id));


CREATE TRIGGER set_checklist_items_updated_at BEFORE UPDATE ON public.checklist_items FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();

CREATE TRIGGER set_fcm_tokens_updated_at BEFORE UPDATE ON public.fcm_tokens FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();

CREATE TRIGGER on_pins_change AFTER INSERT OR DELETE OR UPDATE ON public.pins FOR EACH ROW EXECUTE FUNCTION public.handle_pins_change();

CREATE TRIGGER on_profile_created AFTER INSERT ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.handle_new_profile();

CREATE TRIGGER set_profiles_updated_at BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();

CREATE TRIGGER set_trip_activities_updated_at BEFORE UPDATE ON public.trip_activities FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();

CREATE TRIGGER set_activity_attachments_updated_at BEFORE UPDATE ON public.trip_activity_attachments FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();

CREATE TRIGGER trip_activity_log_to_collaboration_notify AFTER INSERT ON public.trip_activity_log FOR EACH ROW EXECUTE FUNCTION supabase_functions.http_request('https://zmkbdnutedbwkinjukbg.supabase.co/functions/v1/collaboration-notify', 'POST', '{"Content-type":"application/json","X-Wayfind-Collab-Secret":"ZiY66CHpUYwXV5hm1fuuHcvm+OQUgAXLPCi5DCGtO/c="}', '{}', '5000');

CREATE TRIGGER set_trip_booking_attachments_updated_at BEFORE UPDATE ON public.trip_booking_attachments FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();

CREATE TRIGGER set_trip_bookings_updated_at BEFORE UPDATE ON public.trip_bookings FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();

CREATE TRIGGER set_trip_budgets_updated_at BEFORE UPDATE ON public.trip_budgets FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();

CREATE TRIGGER set_trip_checklists_updated_at BEFORE UPDATE ON public.trip_checklists FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();

CREATE TRIGGER set_trip_days_updated_at BEFORE UPDATE ON public.trip_days FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();

CREATE TRIGGER set_trip_expenses_updated_at BEFORE UPDATE ON public.trip_expenses FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();

CREATE TRIGGER set_trip_notes_updated_at BEFORE UPDATE ON public.trip_notes FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();

CREATE TRIGGER on_trips_change AFTER INSERT OR DELETE OR UPDATE ON public.trips FOR EACH ROW EXECUTE FUNCTION public.handle_trips_change();

CREATE TRIGGER set_trips_updated_at BEFORE UPDATE ON public.trips FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();

CREATE TRIGGER trips_prevent_collaborator_rename_trg BEFORE UPDATE ON public.trips FOR EACH ROW EXECUTE FUNCTION public.trips_prevent_collaborator_rename();

CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();


  create policy "Anyone can view avatars"
  on "storage"."objects"
  as permissive
  for select
  to public
using ((bucket_id = 'avatars'::text));



  create policy "Anyone can view pin photos"
  on "storage"."objects"
  as permissive
  for select
  to public
using ((bucket_id = 'pin-photos'::text));



  create policy "Authenticated users can upload their own avatar"
  on "storage"."objects"
  as permissive
  for insert
  to authenticated
with check (((bucket_id = 'avatars'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text)));



  create policy "Place photos are publicly readable"
  on "storage"."objects"
  as permissive
  for select
  to public
using ((bucket_id = 'place-photos'::text));



  create policy "Stop photos are publicly readable"
  on "storage"."objects"
  as permissive
  for select
  to public
using ((bucket_id = 'stop-photos'::text));



  create policy "Trip covers are publicly readable"
  on "storage"."objects"
  as permissive
  for select
  to public
using ((bucket_id = 'trip-covers'::text));



  create policy "Trip owners can read booking documents in their trips"
  on "storage"."objects"
  as permissive
  for select
  to authenticated
using (((bucket_id = 'trip-documents'::text) AND (EXISTS ( SELECT 1
   FROM (public.trip_bookings tb
     JOIN public.trips t ON ((t.id = tb.trip_id)))
  WHERE (((tb.id)::text = (storage.foldername(t.name))[2]) AND (t.user_id = auth.uid()))))));



  create policy "Users can delete their activity attachments"
  on "storage"."objects"
  as permissive
  for delete
  to authenticated
using (((bucket_id = 'activity-attachments'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text)));



  create policy "Users can delete their own avatar"
  on "storage"."objects"
  as permissive
  for delete
  to public
using (((bucket_id = 'avatars'::text) AND ((auth.uid())::text = (storage.foldername(name))[1])));



  create policy "Users can delete their own pin photos"
  on "storage"."objects"
  as permissive
  for delete
  to public
using (((bucket_id = 'pin-photos'::text) AND ((auth.uid())::text = (storage.foldername(name))[1])));



  create policy "Users can delete their own stop photos"
  on "storage"."objects"
  as permissive
  for delete
  to authenticated
using (((bucket_id = 'stop-photos'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text)));



  create policy "Users can delete their own trip covers"
  on "storage"."objects"
  as permissive
  for delete
  to authenticated
using (((bucket_id = 'trip-covers'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text)));



  create policy "Users can delete their own trip documents"
  on "storage"."objects"
  as permissive
  for delete
  to authenticated
using (((bucket_id = 'trip-documents'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text)));



  create policy "Users can delete their own trip photos"
  on "storage"."objects"
  as permissive
  for delete
  to public
using (((bucket_id = 'trip-photos'::text) AND ((auth.uid())::text = (storage.foldername(name))[1])));



  create policy "Users can read their activity attachments"
  on "storage"."objects"
  as permissive
  for select
  to authenticated
using (((bucket_id = 'activity-attachments'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text)));



  create policy "Users can read their own trip documents"
  on "storage"."objects"
  as permissive
  for select
  to authenticated
using (((bucket_id = 'trip-documents'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text)));



  create policy "Users can update their own avatar"
  on "storage"."objects"
  as permissive
  for update
  to public
using (((bucket_id = 'avatars'::text) AND ((auth.uid())::text = (storage.foldername(name))[1])));



  create policy "Users can update their own trip covers"
  on "storage"."objects"
  as permissive
  for update
  to authenticated
using (((bucket_id = 'trip-covers'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text)));



  create policy "Users can upload activity attachments"
  on "storage"."objects"
  as permissive
  for insert
  to authenticated
with check (((bucket_id = 'activity-attachments'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text)));



  create policy "Users can upload pin photos"
  on "storage"."objects"
  as permissive
  for insert
  to public
with check (((bucket_id = 'pin-photos'::text) AND ((auth.uid())::text = (storage.foldername(name))[1])));



  create policy "Users can upload their own stop photos"
  on "storage"."objects"
  as permissive
  for insert
  to authenticated
with check (((bucket_id = 'stop-photos'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text)));



  create policy "Users can upload their own trip covers"
  on "storage"."objects"
  as permissive
  for insert
  to authenticated
with check (((bucket_id = 'trip-covers'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text)));



  create policy "Users can upload their own trip documents"
  on "storage"."objects"
  as permissive
  for insert
  to authenticated
with check (((bucket_id = 'trip-documents'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text)));



  create policy "Users can upload trip photos"
  on "storage"."objects"
  as permissive
  for insert
  to public
with check (((bucket_id = 'trip-photos'::text) AND ((auth.uid())::text = (storage.foldername(name))[1])));



  create policy "Users can view their own trip photos"
  on "storage"."objects"
  as permissive
  for select
  to public
using (((bucket_id = 'trip-photos'::text) AND ((auth.uid())::text = (storage.foldername(name))[1])));



