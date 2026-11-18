-- Throneyard — community: player profiles, friends, crews, find-players (LFG), respect.
-- Non-destructive. Run after 004.

-- Crew creation checks membership inside a row policy, which runs as the player.
grant execute on function public.is_member(uuid) to authenticated;

-- ---------- Profile extras ----------
alter table public.profiles add column if not exists discord_handle text
  check (discord_handle is null or char_length(discord_handle) <= 40);
alter table public.profiles add column if not exists bio text
  check (bio is null or char_length(bio) <= 160);

insert into public.settings (key, value) values
  ('lfg_free_posts', '1'), ('lfg_member_posts', '3')
on conflict (key) do nothing;

-- ---------- Friends ----------
create table if not exists public.friendships (
  requester uuid not null references public.profiles (id) on delete cascade,
  addressee uuid not null references public.profiles (id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted')),
  created_at timestamptz not null default now(),
  primary key (requester, addressee),
  check (requester <> addressee)
);
create index if not exists friendships_addressee_idx on public.friendships (addressee);
alter table public.friendships enable row level security;
do $$ begin
  create policy "see own friendships" on public.friendships for select to authenticated
    using (requester = (select auth.uid()) or addressee = (select auth.uid()));
  create policy "send friend request" on public.friendships for insert to authenticated
    with check (requester = (select auth.uid()) and status = 'pending');
  create policy "accept request" on public.friendships for update to authenticated
    using (addressee = (select auth.uid())) with check (addressee = (select auth.uid()) and status = 'accepted');
  create policy "remove friendship" on public.friendships for delete to authenticated
    using (requester = (select auth.uid()) or addressee = (select auth.uid()));
exception when duplicate_object then null; end $$;

-- Block duplicate requests in the opposite direction.
create or replace function public.friendships_before_insert()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.friendships f where f.requester = new.addressee and f.addressee = new.requester) then
    raise exception 'You already have a request with this player';
  end if;
  new.created_at := now();
  return new;
end;
$$;
drop trigger if exists friendships_before_insert on public.friendships;
create trigger friendships_before_insert before insert on public.friendships
  for each row execute function public.friendships_before_insert();
revoke execute on function public.friendships_before_insert() from public, anon, authenticated;

-- ---------- Respect ----------
create table if not exists public.respects (
  giver uuid not null references public.profiles (id) on delete cascade,
  receiver uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (giver, receiver),
  check (giver <> receiver)
);
alter table public.respects enable row level security;
do $$ begin
  create policy "respects are public" on public.respects for select using (true);
  create policy "give respect" on public.respects for insert to authenticated with check (giver = (select auth.uid()));
  create policy "take back respect" on public.respects for delete to authenticated using (giver = (select auth.uid()));
exception when duplicate_object then null; end $$;

-- ---------- Crews ----------
create table if not exists public.crews (
  id bigint generated always as identity primary key,
  name text not null check (char_length(name) between 3 and 32),
  tag text not null check (tag ~ '^[A-Za-z0-9]{2,5}$'),
  city text not null check (char_length(city) between 1 and 80),
  country text not null check (char_length(country) between 2 and 56),
  description text not null default '' check (char_length(description) <= 240),
  owner uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now()
);
create unique index if not exists crews_name_key on public.crews (lower(name));
create unique index if not exists crews_tag_key on public.crews (upper(tag));
alter table public.crews enable row level security;

create table if not exists public.crew_members (
  crew_id bigint not null references public.crews (id) on delete cascade,
  user_id uuid not null unique references public.profiles (id) on delete cascade,
  role text not null default 'member' check (role in ('owner', 'member')),
  joined_at timestamptz not null default now(),
  primary key (crew_id, user_id)
);
alter table public.crew_members enable row level security;

do $$ begin
  create policy "crews are public" on public.crews for select using (true);
  create policy "members create crews" on public.crews for insert to authenticated
    with check (owner = (select auth.uid()) and public.is_member((select auth.uid())));
  create policy "owner edits crew" on public.crews for update to authenticated
    using (owner = (select auth.uid())) with check (owner = (select auth.uid()));
  create policy "owner deletes crew" on public.crews for delete to authenticated
    using (owner = (select auth.uid()));
  create policy "crew members are public" on public.crew_members for select using (true);
  create policy "join a crew" on public.crew_members for insert to authenticated
    with check (user_id = (select auth.uid()) and role = 'member');
  create policy "leave or remove" on public.crew_members for delete to authenticated
    using (user_id = (select auth.uid())
           or exists (select 1 from public.crews c where c.id = crew_id and c.owner = (select auth.uid())));
exception when duplicate_object then null; end $$;

-- Creating a crew makes you its owner-member (and you must not already be in a crew).
create or replace function public.crews_after_insert()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.crew_members where user_id = new.owner) then
    raise exception 'Leave your current crew before creating a new one';
  end if;
  insert into public.crew_members (crew_id, user_id, role) values (new.id, new.owner, 'owner');
  return new;
end;
$$;
drop trigger if exists crews_after_insert on public.crews;
create trigger crews_after_insert after insert on public.crews
  for each row execute function public.crews_after_insert();
revoke execute on function public.crews_after_insert() from public, anon, authenticated;

-- An owner leaving disbands the crew.
create or replace function public.crew_members_after_delete()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.role = 'owner' then
    delete from public.crews where id = old.crew_id;
  end if;
  return old;
end;
$$;
drop trigger if exists crew_members_after_delete on public.crew_members;
create trigger crew_members_after_delete after delete on public.crew_members
  for each row execute function public.crew_members_after_delete();
revoke execute on function public.crew_members_after_delete() from public, anon, authenticated;

-- ---------- Find Players (LFG) ----------
create table if not exists public.lfg_posts (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  platform text not null check (platform in ('ps5', 'xbox', 'any')),
  title text not null check (char_length(title) between 4 and 80),
  body text not null default '' check (char_length(body) <= 300),
  play_time text not null default '' check (char_length(play_time) <= 40),
  by_member boolean not null default false,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '7 days'
);
create index if not exists lfg_active_idx on public.lfg_posts (expires_at desc);
alter table public.lfg_posts enable row level security;
do $$ begin
  create policy "lfg is public" on public.lfg_posts for select using (expires_at > now());
  create policy "post lfg" on public.lfg_posts for insert to authenticated with check (user_id = (select auth.uid()));
  create policy "delete own lfg" on public.lfg_posts for delete to authenticated
    using (user_id = (select auth.uid()) or (select public.is_admin()));
exception when duplicate_object then null; end $$;

create or replace function public.lfg_before_insert()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  member boolean := public.is_member(new.user_id);
  cap int := coalesce((select (value #>> '{}')::int from public.settings
                       where key = case when member then 'lfg_member_posts' else 'lfg_free_posts' end), 1);
begin
  if (select count(*) from public.lfg_posts where user_id = new.user_id and expires_at > now()) >= cap then
    raise exception 'You can have % active post(s)%', cap, case when member then '' else '. Members can post 3.' end;
  end if;
  new.by_member := member;
  new.created_at := now();
  new.expires_at := now() + interval '7 days';
  return new;
end;
$$;
drop trigger if exists lfg_before_insert on public.lfg_posts;
create trigger lfg_before_insert before insert on public.lfg_posts
  for each row execute function public.lfg_before_insert();
revoke execute on function public.lfg_before_insert() from public, anon, authenticated;

-- ---------- Read functions ----------
create or replace function public.player_profile(p_gamertag text)
returns table (id uuid, gamertag text, platform text, country text, city text, bio text, discord_handle text,
               member boolean, total_score bigint, verified_runs bigint, global_rank bigint,
               respects bigint, crew_id bigint, crew_name text, crew_tag text, joined date)
language sql stable security definer set search_path = '' as $$
  with me as (select * from public.profiles where lower(gamertag) = lower(p_gamertag) limit 1),
  totals as (
    select s.user_id, sum(s.score)::bigint as pts, count(*) as runs
    from public.submissions s join public.missions m on m.id = s.mission_id
    where s.status = 'verified' and m.kind = 'weekend'
    group by s.user_id
  ),
  ranked as (select user_id, pts, runs, rank() over (order by pts desc) as rk from totals)
  select me.id, me.gamertag, me.platform, me.country, me.city, me.bio, me.discord_handle,
         public.is_member(me.id), coalesce(r.pts, 0), coalesce(r.runs, 0), r.rk,
         (select count(*) from public.respects x where x.receiver = me.id),
         c.id, c.name, c.tag, me.created_at::date
  from me
  left join ranked r on r.user_id = me.id
  left join public.crew_members cm on cm.user_id = me.id
  left join public.crews c on c.id = cm.crew_id;
$$;

create or replace function public.player_runs(p_gamertag text, p_limit int default 10)
returns table (mission text, week_label text, score int, reviewed_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select m.title, m.week_label, s.score, s.reviewed_at
  from public.submissions s
  join public.missions m on m.id = s.mission_id
  join public.profiles p on p.id = s.user_id
  where lower(p.gamertag) = lower(p_gamertag) and s.status = 'verified'
  order by s.reviewed_at desc
  limit least(greatest(coalesce(p_limit, 10), 1), 50);
$$;

create or replace function public.crew_board(p_limit int default 50)
returns table (rank bigint, id bigint, name text, tag text, city text, country text, description text,
               members bigint, score bigint, owner_gamertag text)
language sql stable security definer set search_path = '' as $$
  with pts as (
    select s.user_id, sum(s.score)::bigint as pts
    from public.submissions s join public.missions m on m.id = s.mission_id
    where s.status = 'verified' and m.kind = 'weekend'
    group by s.user_id
  )
  select rank() over (order by coalesce(sum(pts.pts), 0) desc), c.id, c.name, c.tag, c.city, c.country, c.description,
         count(cm.user_id), coalesce(sum(pts.pts), 0)::bigint, o.gamertag
  from public.crews c
  join public.profiles o on o.id = c.owner
  left join public.crew_members cm on cm.crew_id = c.id
  left join pts on pts.user_id = cm.user_id
  group by c.id, o.gamertag
  order by coalesce(sum(pts.pts), 0) desc, c.created_at
  limit least(greatest(coalesce(p_limit, 50), 1), 200);
$$;

create or replace function public.crew_roster(p_crew bigint)
returns table (gamertag text, role text, score bigint, member boolean)
language sql stable security definer set search_path = '' as $$
  select p.gamertag, cm.role,
         coalesce((select sum(s.score) from public.submissions s join public.missions m on m.id = s.mission_id
                   where s.user_id = p.id and s.status = 'verified' and m.kind = 'weekend'), 0)::bigint,
         public.is_member(p.id)
  from public.crew_members cm join public.profiles p on p.id = cm.user_id
  where cm.crew_id = p_crew
  order by 3 desc;
$$;

create or replace function public.lfg_feed(p_platform text default null, p_limit int default 50)
returns table (id bigint, gamertag text, platform text, title text, body text, play_time text,
               city text, country text, discord_handle text, member boolean, created_at timestamptz, mine boolean)
language sql stable security definer set search_path = '' as $$
  select l.id, p.gamertag, l.platform, l.title, l.body, l.play_time, p.city, p.country, p.discord_handle,
         l.by_member, l.created_at, l.user_id = auth.uid()
  from public.lfg_posts l join public.profiles p on p.id = l.user_id
  where l.expires_at > now() and (p_platform is null or l.platform = p_platform or l.platform = 'any')
  order by l.by_member desc, l.created_at desc
  limit least(greatest(coalesce(p_limit, 50), 1), 100);
$$;

-- Signed-in player's friends and requests.
create or replace function public.my_friends()
returns table (gamertag text, city text, country text, status text, direction text, member boolean)
language sql stable security definer set search_path = '' as $$
  select p.gamertag, p.city, p.country, f.status,
         case when f.requester = auth.uid() then 'out' else 'in' end,
         public.is_member(p.id)
  from public.friendships f
  join public.profiles p on p.id = case when f.requester = auth.uid() then f.addressee else f.requester end
  where f.requester = auth.uid() or f.addressee = auth.uid()
  order by f.status, p.gamertag;
$$;

-- You vs your friends, this month.
create or replace function public.friends_board(p_month date default null)
returns table (rank bigint, gamertag text, city text, country text, score bigint, missions bigint, is_me boolean)
language sql stable security definer set search_path = '' as $$
  with bounds as (
    select (date_trunc('month', coalesce(p_month, (now() at time zone 'America/Toronto')::date))::timestamp
              at time zone 'America/Toronto') as s
  ), circle as (
    select auth.uid() as uid
    union
    select case when f.requester = auth.uid() then f.addressee else f.requester end
    from public.friendships f
    where f.status = 'accepted' and (f.requester = auth.uid() or f.addressee = auth.uid())
  ), pts as (
    select c.uid,
           coalesce(sum(s.score) filter (where s.status = 'verified' and m.kind = 'weekend'
                     and m.opens_at >= b.s and m.opens_at < b.s + interval '1 month'), 0)::bigint as score,
           count(s.id) filter (where s.status = 'verified' and m.kind = 'weekend'
                     and m.opens_at >= b.s and m.opens_at < b.s + interval '1 month') as missions
    from circle c cross join bounds b
    left join public.submissions s on s.user_id = c.uid
    left join public.missions m on m.id = s.mission_id
    group by c.uid
  )
  select rank() over (order by pts.score desc), p.gamertag, p.city, p.country, pts.score, pts.missions, p.id = auth.uid()
  from pts join public.profiles p on p.id = pts.uid
  where auth.uid() is not null
  order by pts.score desc, p.gamertag;
$$;
revoke execute on function public.my_friends() from anon;
revoke execute on function public.friends_board(date) from anon;
