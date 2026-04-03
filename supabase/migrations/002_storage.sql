-- Storage bucket for trip cover photos (public read)

insert into storage.buckets (id, name, public)
values ('cover-photos', 'cover-photos', true)
on conflict (id) do update
set
  name = excluded.name,
  public = excluded.public;

drop policy if exists "Users upload own cover photos" on storage.objects;
drop policy if exists "Anyone can view cover photos" on storage.objects;
drop policy if exists "Users delete own cover photos" on storage.objects;

-- Upload policy: authenticated users upload to their own folder
create policy "Users upload own cover photos"
  on storage.objects for insert
  with check (
    bucket_id = 'cover-photos'
    and auth.role() = 'authenticated'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- Read policy: anyone can view cover photos (public bucket)
create policy "Anyone can view cover photos"
  on storage.objects for select
  using (bucket_id = 'cover-photos');

-- Delete policy: users can delete their own photos
create policy "Users delete own cover photos"
  on storage.objects for delete
  using (
    bucket_id = 'cover-photos'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
