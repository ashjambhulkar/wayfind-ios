-- Legacy `collaborator_id NOT NULL` predates V2c; canonical row key is `id` (uuid PK).
-- Inserts (accept_invite, Edge Functions, etc.) omit collaborator_id.

ALTER TABLE public.trip_collaborators
  DROP COLUMN IF EXISTS collaborator_id CASCADE;
