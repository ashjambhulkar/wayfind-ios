create table if not exists public.feedback (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid references auth.users(id) on delete set null,
  category    text not null check (category in ('bug', 'feature', 'general', 'other')),
  message     text not null check (char_length(message) >= 10 and char_length(message) <= 2000),
  app_version text,
  created_at  timestamptz not null default now()
);

alter table public.feedback enable row level security;

-- Users can insert their own feedback (authenticated and anonymous with null user_id)
create policy "Users can submit feedback"
  on public.feedback
  for insert
  to authenticated
  with check (user_id = auth.uid());

-- Users can read only their own feedback submissions
create policy "Users can view own feedback"
  on public.feedback
  for select
  to authenticated
  using (user_id = auth.uid());
