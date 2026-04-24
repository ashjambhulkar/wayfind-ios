drop index if exists "public"."idx_city_places_time_spent_queue";

alter table "public"."city_places" drop column "time_spent_enriched_at";

alter table "public"."city_places" drop column "time_spent_max";

alter table "public"."city_places" drop column "time_spent_min";


