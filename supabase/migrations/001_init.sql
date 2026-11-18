-- Throneyard — initial schema
-- Waitlist, profiles, missions, submissions (with review), leaderboards, storage.

-- ---------- Settings ----------
create table public.settings (
  key text primary key,
  value jsonb not null
);
alter table public.settings enable row level security;
create policy "settings are public" on public.settings for select using (true);

insert into public.settings (key, value) values
  ('waitlist_base', '672896'),
  ('launch_at', '"2026-11-19T12:00:00-05:00"');

-- ---------- Admins ----------
-- No client policies: only manageable from SQL / dashboard.
create table public.admins (
  user_id uuid primary key references auth.users on delete cascade
);
alter table public.admins enable row level security;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

-- ---------- Waitlist ----------
create table public.waitlist (
  id bigint generated always as identity primary key,
  email text not null check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' and char_length(email) <= 254),
  gamertag text not null check (char_length(gamertag) between 2 and 32),
  platform text not null check (platform in ('ps5', 'xbox')),
  referral_code text not null unique default substr(md5(random()::text || clock_timestamp()::text), 1, 8),
  referred_by text,
  created_at timestamptz not null default now()
);
create unique index waitlist_email_key on public.waitlist (lower(email));
alter table public.waitlist enable row level security;
-- No client policies: emails stay private. Access only via functions below.

create or replace function public.waitlist_count()
returns bigint language sql stable security definer set search_path = '' as $$
  select coalesce((select (value #>> '{}')::bigint from public.settings where key = 'waitlist_base'), 0)
       + (select count(*) from public.waitlist);
$$;

create or replace function public.join_waitlist(p_email text, p_gamertag text, p_platform text, p_ref text default null)
returns table (queue_position bigint, ref_code text, already_joined boolean)
language plpgsql security definer set search_path = '' as $$
declare
  r public.waitlist;
  existed boolean := false;
  base bigint;
begin
  select * into r from public.waitlist w where lower(w.email) = lower(trim(p_email));
  if found then
    existed := true;
  else
    insert into public.waitlist (email, gamertag, platform, referred_by)
    values (lower(trim(p_email)), trim(p_gamertag), p_platform, nullif(left(trim(coalesce(p_ref, '')), 16), ''))
    returning * into r;
  end if;
  select coalesce((value #>> '{}')::bigint, 0) into base from public.settings where key = 'waitlist_base';
  return query
    select base + (select count(*) from public.waitlist w where w.id <= r.id), r.referral_code, existed;
end;
$$;

create or replace function public.referral_count(p_code text)
returns bigint language sql stable security definer set search_path = '' as $$
  select count(*) from public.waitlist where referred_by = p_code;
$$;

-- ---------- Profiles ----------
create table public.profiles (
  id uuid primary key references auth.users on delete cascade,
  gamertag text not null check (char_length(gamertag) between 2 and 32),
  platform text not null check (platform in ('ps5', 'xbox')),
  country text not null check (char_length(country) between 2 and 56),
  city text not null check (char_length(city) between 1 and 80),
  created_at timestamptz not null default now()
);
create unique index profiles_gamertag_key on public.profiles (lower(gamertag));
alter table public.profiles enable row level security;
create policy "profiles are public" on public.profiles for select using (true);
create policy "insert own profile" on public.profiles for insert to authenticated
  with check (id = (select auth.uid()));
create policy "update own profile" on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- ---------- Missions ----------
create table public.missions (
  id bigint generated always as identity primary key,
  title text not null check (char_length(title) between 2 and 120),
  description text not null default '',
  week_label text not null check (char_length(week_label) between 1 and 40),
  max_points int not null default 1000 check (max_points > 0),
  opens_at timestamptz not null,
  closes_at timestamptz not null,
  created_at timestamptz not null default now(),
  check (closes_at > opens_at)
);
alter table public.missions enable row level security;
create policy "missions are public" on public.missions for select using (true);
create policy "admins manage missions" on public.missions for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

-- ---------- Submissions ----------
create table public.submissions (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  mission_id bigint not null references public.missions (id) on delete cascade,
  video_path text not null,
  image_paths text[] not null default '{}',
  notes text not null default '' check (char_length(notes) <= 1000),
  file_checks jsonb not null default '{}',
  status text not null default 'pending' check (status in ('pending', 'verified', 'rejected')),
  score int not null default 0 check (score >= 0),
  reject_reason text,
  reviewed_by uuid references auth.users,
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);
create unique index submissions_one_active on public.submissions (user_id, mission_id) where status <> 'rejected';
create index submissions_status_idx on public.submissions (status, created_at);
create index submissions_mission_idx on public.submissions (mission_id);
alter table public.submissions enable row level security;
create policy "read own or admin" on public.submissions for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_admin()));
create policy "insert own" on public.submissions for insert to authenticated
  with check (user_id = (select auth.uid()));
create policy "admins review" on public.submissions for update to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

create or replace function public.submissions_before_insert()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  m public.missions;
  folder text := auth.uid()::text || '/';
  p text;
begin
  new.status := 'pending';
  new.score := 0;
  new.reject_reason := null;
  new.reviewed_by := null;
  new.reviewed_at := null;
  new.created_at := now();
  select * into m from public.missions where id = new.mission_id;
  if not found then raise exception 'Mission not found'; end if;
  if now() < m.opens_at or now() > m.closes_at then
    raise exception 'This mission is not open for submissions right now';
  end if;
  if left(new.video_path, length(folder)) <> folder then raise exception 'Invalid video path'; end if;
  if coalesce(array_length(new.image_paths, 1), 0) > 6 then raise exception 'Up to 6 screenshots'; end if;
  foreach p in array new.image_paths loop
    if left(p, length(folder)) <> folder then raise exception 'Invalid image path'; end if;
  end loop;
  return new;
end;
$$;
create trigger submissions_before_insert before insert on public.submissions
  for each row execute function public.submissions_before_insert();

create or replace function public.submissions_before_update()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  maxp int;
begin
  -- Only review fields may change.
  new.user_id := old.user_id;
  new.mission_id := old.mission_id;
  new.video_path := old.video_path;
  new.image_paths := old.image_paths;
  new.notes := old.notes;
  new.file_checks := old.file_checks;
  new.created_at := old.created_at;
  select max_points into maxp from public.missions where id = new.mission_id;
  if new.status = 'verified' then
    new.score := least(greatest(new.score, 0), maxp);
    new.reject_reason := null;
  else
    new.score := 0;
  end if;
  new.reviewed_by := auth.uid();
  new.reviewed_at := now();
  return new;
end;
$$;
create trigger submissions_before_update before update on public.submissions
  for each row execute function public.submissions_before_update();

-- ---------- Leaderboards ----------
create or replace function public.leaderboard(
  p_scope text default 'global',
  p_country text default null,
  p_city text default null,
  p_week text default null,
  p_limit int default 50
)
returns table (rank bigint, gamertag text, platform text, country text, city text, missions bigint, score bigint)
language sql stable security definer set search_path = '' as $$
  select
    rank() over (order by sum(s.score) desc) as rank,
    p.gamertag, p.platform, p.country, p.city,
    count(*) as missions,
    sum(s.score)::bigint as score
  from public.submissions s
  join public.profiles p on p.id = s.user_id
  join public.missions m on m.id = s.mission_id
  where s.status = 'verified'
    and (p_week is null or m.week_label = p_week)
    and (
      p_scope = 'global'
      or (p_scope = 'country' and lower(p.country) = lower(p_country))
      or (p_scope = 'city' and lower(p.country) = lower(p_country) and lower(p.city) = lower(p_city))
    )
  group by p.id, p.gamertag, p.platform, p.country, p.city
  order by sum(s.score) desc, min(s.reviewed_at) asc
  limit least(greatest(coalesce(p_limit, 50), 1), 200);
$$;

-- ---------- Storage ----------
insert into storage.buckets (id, name, public, allowed_mime_types)
values ('submissions', 'submissions', false,
        array['video/mp4', 'video/quicktime', 'video/webm', 'image/png', 'image/jpeg', 'image/webp'])
on conflict (id) do nothing;

create policy "upload to own folder" on storage.objects for insert to authenticated
  with check (bucket_id = 'submissions' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "read own files or admin" on storage.objects for select to authenticated
  using (bucket_id = 'submissions' and ((storage.foldername(name))[1] = (select auth.uid())::text or (select public.is_admin())));

-- ---------- Function grants ----------
revoke execute on function public.submissions_before_insert() from public, anon, authenticated;
revoke execute on function public.submissions_before_update() from public, anon, authenticated;
