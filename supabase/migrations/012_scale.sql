-- Throneyard — scale for millions of players.
-- Running totals (updated when runs are reviewed) instead of re-adding every run per page view,
-- indexed leaderboards, sharded waitlist counter, waitlist abuse limits, safer invite codes,
-- and Broadcast-based realtime (Supabase's recommended method at scale).

-- ============ Location on profiles ============
alter table public.profiles add column if not exists continent text;
update public.profiles set continent = public.continent_of(residence) where continent is distinct from public.continent_of(residence);
create index if not exists profiles_city_idx on public.profiles (lower(trim(country)), lower(trim(city)));
create index if not exists profiles_continent_idx on public.profiles (continent);

-- ============ Running totals ============
create table if not exists public.player_stats (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  total_score bigint not null default 0,
  runs int not null default 0,
  first_review timestamptz,
  country_l text, city_l text, continent text, platform text,
  world int not null default 0, cont_b int not null default 0, city_b int not null default 0
);
create index if not exists player_stats_score_idx on public.player_stats (total_score desc, first_review);
create index if not exists player_stats_country_idx on public.player_stats (country_l, total_score desc);
create index if not exists player_stats_city_idx on public.player_stats (country_l, city_l, total_score desc);
alter table public.player_stats enable row level security;

create table if not exists public.player_period_scores (
  period_type text not null check (period_type in ('week', 'month')),
  period_key text not null,
  user_id uuid not null references public.profiles (id) on delete cascade,
  score bigint not null default 0,
  runs int not null default 0,
  first_review timestamptz,
  country_l text, city_l text, continent text, platform text,
  primary key (period_type, period_key, user_id)
);
create index if not exists pps_score_idx on public.player_period_scores (period_type, period_key, score desc, first_review);
create index if not exists pps_continent_idx on public.player_period_scores (period_type, period_key, continent, score desc);
create index if not exists pps_country_idx on public.player_period_scores (period_type, period_key, country_l, score desc);
create index if not exists pps_city_idx on public.player_period_scores (period_type, period_key, country_l, city_l, score desc);
create index if not exists pps_user_idx on public.player_period_scores (user_id);
alter table public.player_period_scores enable row level security;

create table if not exists public.city_period_scores (
  period_key text not null, country_l text not null, city_l text not null,
  city text, country text, score bigint not null default 0, players int not null default 0,
  primary key (period_key, country_l, city_l)
);
create index if not exists cps_score_idx on public.city_period_scores (period_key, score desc);
alter table public.city_period_scores enable row level security;

create table if not exists public.platform_period_scores (
  period_key text not null, platform text not null, score bigint not null default 0, players int not null default 0,
  primary key (period_key, platform)
);
alter table public.platform_period_scores enable row level security;

alter table public.crews add column if not exists score bigint not null default 0;
alter table public.crews add column if not exists members int not null default 0;
create index if not exists crews_score_idx on public.crews (score desc, created_at);

-- Apply a change in verified points for one player on one mission.
create or replace function public.apply_score(p_user uuid, p_mission bigint, p_score int, p_runs int, p_at timestamptz)
returns void language plpgsql security definer set search_path = '' as $$
declare
  m public.missions; pr public.profiles;
  mk text; cl text; ctl text; cont text;
  was_runs int; now_runs int; d_players int;
begin
  select * into m from public.missions where id = p_mission;
  if not found or m.kind <> 'weekend' or (p_score = 0 and p_runs = 0) then return; end if;
  select * into pr from public.profiles where id = p_user;
  if not found then return; end if;
  mk := to_char(m.opens_at at time zone 'America/Toronto', 'YYYY-MM');
  cl := lower(trim(pr.country)); ctl := lower(trim(pr.city)); cont := public.continent_of(pr.residence);

  insert into public.player_stats as s (user_id, total_score, runs, first_review, country_l, city_l, continent, platform)
  values (p_user, p_score, p_runs, p_at, cl, ctl, cont, pr.platform)
  on conflict (user_id) do update set total_score = s.total_score + excluded.total_score, runs = s.runs + excluded.runs,
    first_review = least(s.first_review, excluded.first_review);

  insert into public.player_period_scores as s (period_type, period_key, user_id, score, runs, first_review, country_l, city_l, continent, platform)
  values ('week', m.week_label, p_user, p_score, p_runs, p_at, cl, ctl, cont, pr.platform)
  on conflict (period_type, period_key, user_id) do update set score = s.score + excluded.score, runs = s.runs + excluded.runs,
    first_review = least(s.first_review, excluded.first_review);

  select runs into was_runs from public.player_period_scores where period_type = 'month' and period_key = mk and user_id = p_user;
  was_runs := coalesce(was_runs, 0);
  insert into public.player_period_scores as s (period_type, period_key, user_id, score, runs, first_review, country_l, city_l, continent, platform)
  values ('month', mk, p_user, p_score, p_runs, p_at, cl, ctl, cont, pr.platform)
  on conflict (period_type, period_key, user_id) do update set score = s.score + excluded.score, runs = s.runs + excluded.runs,
    first_review = least(s.first_review, excluded.first_review)
  returning runs into now_runs;
  d_players := case when was_runs = 0 and now_runs > 0 then 1 when was_runs > 0 and now_runs <= 0 then -1 else 0 end;

  insert into public.city_period_scores as c (period_key, country_l, city_l, city, country, score, players)
  values (mk, cl, ctl, initcap(trim(pr.city)), trim(pr.country), p_score, d_players)
  on conflict (period_key, country_l, city_l) do update set score = c.score + excluded.score, players = c.players + excluded.players;

  insert into public.platform_period_scores as c (period_key, platform, score, players)
  values (mk, pr.platform, p_score, d_players)
  on conflict (period_key, platform) do update set score = c.score + excluded.score, players = c.players + excluded.players;

  update public.crews set score = score + p_score where id = (select crew_id from public.crew_members where user_id = p_user);
end;
$$;
revoke execute on function public.apply_score(uuid, bigint, int, int, timestamptz) from public, anon, authenticated;

create or replace function public.submissions_scores()
returns trigger language plpgsql security definer set search_path = '' as $$
declare old_s int := 0; old_r int := 0; new_s int := 0; new_r int := 0;
begin
  if tg_op in ('UPDATE', 'DELETE') and old.status = 'verified' then old_s := old.score; old_r := 1; end if;
  if tg_op in ('INSERT', 'UPDATE') and new.status = 'verified' then new_s := new.score; new_r := 1; end if;
  if new_s <> old_s or new_r <> old_r then
    perform public.apply_score(coalesce(new.user_id, old.user_id), coalesce(new.mission_id, old.mission_id),
                               new_s - old_s, new_r - old_r, coalesce(new.reviewed_at, now()));
  end if;
  return null;
end;
$$;
drop trigger if exists submissions_scores on public.submissions;
create trigger submissions_scores after insert or update or delete on public.submissions
  for each row execute function public.submissions_scores();
revoke execute on function public.submissions_scores() from public, anon, authenticated;

-- Crew score and member count follow membership.
create or replace function public.crew_member_totals()
returns trigger language plpgsql security definer set search_path = '' as $$
declare pts bigint;
begin
  if tg_op = 'INSERT' then
    select coalesce(total_score, 0) into pts from public.player_stats where user_id = new.user_id;
    update public.crews set members = members + 1, score = score + coalesce(pts, 0) where id = new.crew_id;
  else
    select coalesce(total_score, 0) into pts from public.player_stats where user_id = old.user_id;
    update public.crews set members = greatest(members - 1, 0), score = score - coalesce(pts, 0) where id = old.crew_id;
  end if;
  return null;
end;
$$;
drop trigger if exists crew_member_totals on public.crew_members;
create trigger crew_member_totals after insert or delete on public.crew_members
  for each row execute function public.crew_member_totals();
revoke execute on function public.crew_member_totals() from public, anon, authenticated;

-- Badge counts on player_stats.
create or replace function public.badge_totals()
returns trigger language plpgsql security definer set search_path = '' as $$
declare u uuid := coalesce(new.user_id, old.user_id); k text := coalesce(new.kind, old.kind); d int := case when tg_op = 'INSERT' then 1 else -1 end;
begin
  insert into public.player_stats (user_id) values (u) on conflict (user_id) do nothing;
  update public.player_stats set
    world = world + case when k = 'world' then d else 0 end,
    cont_b = cont_b + case when k = 'continent' then d else 0 end,
    city_b = city_b + case when k = 'city' then d else 0 end
  where user_id = u;
  return null;
end;
$$;
drop trigger if exists badge_totals on public.badges;
create trigger badge_totals after insert or delete on public.badges for each row execute function public.badge_totals();
revoke execute on function public.badge_totals() from public, anon, authenticated;

-- Keep location in sync when a player edits their card.
create or replace function public.profiles_sync()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.continent := public.continent_of(new.residence);
  if tg_op = 'UPDATE' and (new.country is distinct from old.country or new.city is distinct from old.city
                           or new.residence is distinct from old.residence or new.platform is distinct from old.platform) then
    update public.player_stats set country_l = lower(trim(new.country)), city_l = lower(trim(new.city)), continent = new.continent, platform = new.platform where user_id = new.id;
    update public.player_period_scores set country_l = lower(trim(new.country)), city_l = lower(trim(new.city)), continent = new.continent, platform = new.platform where user_id = new.id;
  end if;
  return new;
end;
$$;
drop trigger if exists profiles_sync on public.profiles;
create trigger profiles_sync before insert or update on public.profiles for each row execute function public.profiles_sync();
revoke execute on function public.profiles_sync() from public, anon, authenticated;

-- Backfill from existing data.
insert into public.player_stats (user_id, total_score, runs, first_review, country_l, city_l, continent, platform)
select p.id, coalesce(sum(s.score), 0), count(s.id), min(s.reviewed_at), lower(trim(p.country)), lower(trim(p.city)), p.continent, p.platform
from public.profiles p
join public.submissions s on s.user_id = p.id and s.status = 'verified'
join public.missions m on m.id = s.mission_id and m.kind = 'weekend'
group by p.id
on conflict (user_id) do update set total_score = excluded.total_score, runs = excluded.runs, first_review = excluded.first_review;
update public.player_stats st set world = b.w, cont_b = b.c, city_b = b.ci
from (select user_id, count(*) filter (where kind = 'world') w, count(*) filter (where kind = 'continent') c, count(*) filter (where kind = 'city') ci
      from public.badges group by user_id) b where b.user_id = st.user_id;
insert into public.player_period_scores (period_type, period_key, user_id, score, runs, first_review, country_l, city_l, continent, platform)
select 'week', m.week_label, p.id, sum(s.score), count(*), min(s.reviewed_at), lower(trim(p.country)), lower(trim(p.city)), p.continent, p.platform
from public.submissions s join public.missions m on m.id = s.mission_id and m.kind = 'weekend' join public.profiles p on p.id = s.user_id
where s.status = 'verified' group by m.week_label, p.id
on conflict do nothing;
insert into public.player_period_scores (period_type, period_key, user_id, score, runs, first_review, country_l, city_l, continent, platform)
select 'month', to_char(m.opens_at at time zone 'America/Toronto', 'YYYY-MM'), p.id, sum(s.score), count(*), min(s.reviewed_at), lower(trim(p.country)), lower(trim(p.city)), p.continent, p.platform
from public.submissions s join public.missions m on m.id = s.mission_id and m.kind = 'weekend' join public.profiles p on p.id = s.user_id
where s.status = 'verified' group by 2, p.id
on conflict do nothing;
insert into public.city_period_scores (period_key, country_l, city_l, city, country, score, players)
select pps.period_key, pps.country_l, pps.city_l, initcap(min(p.city)), min(p.country), sum(pps.score), count(*)
from public.player_period_scores pps join public.profiles p on p.id = pps.user_id
where pps.period_type = 'month' group by 1, 2, 3 on conflict do nothing;
insert into public.platform_period_scores (period_key, platform, score, players)
select period_key, platform, sum(score), count(*) from public.player_period_scores where period_type = 'month' group by 1, 2 on conflict do nothing;
update public.crews c set members = x.n, score = x.pts
from (select cm.crew_id, count(*) n, coalesce(sum(st.total_score), 0) pts from public.crew_members cm
      left join public.player_stats st on st.user_id = cm.user_id group by cm.crew_id) x where x.crew_id = c.id;

-- ============ Fast read functions ============
create or replace function public.leaderboard_v3(p_scope text default 'global', p_country text default null, p_city text default null,
                                                 p_week text default null, p_limit int default 50)
returns table (rank bigint, gamertag text, platform text, country text, city text, missions bigint, score bigint,
               member boolean, world int, continent int, city_badges int)
language plpgsql stable security definer set search_path = '' as $$
declare
  lim int := least(greatest(coalesce(p_limit, 50), 1), 200);
  src text; filt text := '';
begin
  if p_scope = 'country' then filt := ' and s.country_l = $1';
  elsif p_scope = 'city' then filt := ' and s.country_l = $1 and s.city_l = $2';
  end if;
  if p_week is null then
    src := 'select s.user_id, s.total_score as sc, s.runs, s.first_review from public.player_stats s where s.runs > 0' || filt ||
           ' order by s.total_score desc, s.first_review limit $4';
  else
    src := 'select s.user_id, s.score as sc, s.runs, s.first_review from public.player_period_scores s where s.period_type = ''week'' and s.period_key = $3 and s.runs > 0' || filt ||
           ' order by s.score desc, s.first_review limit $4';
  end if;
  return query execute
    'with top as (' || src || ')
     select rank() over (order by t.sc desc), p.gamertag, p.platform, p.country, p.city, t.runs::bigint, t.sc::bigint,
            public.is_member(p.id), coalesce(st.world, 0), coalesce(st.cont_b, 0), coalesce(st.city_b, 0)
     from top t join public.profiles p on p.id = t.user_id left join public.player_stats st on st.user_id = t.user_id
     order by t.sc desc, t.first_review'
  using lower(trim(p_country)), lower(trim(p_city)), p_week, lim;
end;
$$;

create or replace function public.monthly_board_v3(p_month date default null, p_continent text default null, p_limit int default 50)
returns table (rank bigint, gamertag text, platform text, country text, city text, continent text, missions bigint, score bigint,
               member boolean, world int, cont_b int, city_badges int)
language plpgsql stable security definer set search_path = '' as $$
declare
  lim int := least(greatest(coalesce(p_limit, 50), 1), 200);
  mk text := to_char(coalesce(p_month, (now() at time zone 'America/Toronto')::date), 'YYYY-MM');
begin
  return query execute
    'with top as (select s.user_id, s.score as sc, s.runs, s.first_review, s.continent from public.player_period_scores s
                  where s.period_type = ''month'' and s.period_key = $1 and s.runs > 0' ||
                  case when p_continent is not null then ' and s.continent = $2' else '' end ||
                  ' order by s.score desc, s.first_review limit $3)
     select rank() over (order by t.sc desc), p.gamertag, p.platform, p.country, p.city, t.continent, t.runs::bigint, t.sc::bigint,
            public.is_member(p.id), coalesce(st.world, 0), coalesce(st.cont_b, 0), coalesce(st.city_b, 0)
     from top t join public.profiles p on p.id = t.user_id left join public.player_stats st on st.user_id = t.user_id
     order by t.sc desc, t.first_review'
  using mk, p_continent, lim;
end;
$$;

create or replace function public.city_wars(p_month date default null, p_limit int default 50)
returns table (rank bigint, city text, country text, players bigint, score bigint, top_player text)
language sql stable security definer set search_path = '' as $$
  with top as (
    select c.* from public.city_period_scores c
    where c.period_key = to_char(coalesce(p_month, (now() at time zone 'America/Toronto')::date), 'YYYY-MM') and c.players > 0
    order by c.score desc limit least(greatest(coalesce(p_limit, 50), 1), 200)
  )
  select rank() over (order by t.score desc), t.city, t.country, t.players::bigint, t.score,
         (select p.gamertag from public.player_period_scores s join public.profiles p on p.id = s.user_id
          where s.period_type = 'month' and s.period_key = t.period_key and s.country_l = t.country_l and s.city_l = t.city_l
          order by s.score desc limit 1)
  from top t order by t.score desc;
$$;

create or replace function public.platform_wars(p_month date default null)
returns table (platform text, players bigint, score bigint)
language sql stable security definer set search_path = '' as $$
  select pl.platform, coalesce(x.players, 0)::bigint, coalesce(x.score, 0)::bigint
  from (values ('ps5'), ('xbox')) pl(platform)
  left join public.platform_period_scores x on x.platform = pl.platform
    and x.period_key = to_char(coalesce(p_month, (now() at time zone 'America/Toronto')::date), 'YYYY-MM')
  order by pl.platform;
$$;

create or replace function public.crew_board(p_limit int default 50)
returns table (rank bigint, id bigint, name text, tag text, city text, country text, description text,
               members bigint, score bigint, owner_gamertag text)
language sql stable security definer set search_path = '' as $$
  with top as (select * from public.crews order by score desc, created_at limit least(greatest(coalesce(p_limit, 50), 1), 200))
  select rank() over (order by t.score desc), t.id, t.name, t.tag, t.city, t.country, t.description,
         t.members::bigint, t.score, o.gamertag
  from top t join public.profiles o on o.id = t.owner
  order by t.score desc, t.created_at;
$$;

create or replace function public.crew_roster(p_crew bigint)
returns table (gamertag text, role text, score bigint, member boolean)
language sql stable security definer set search_path = '' as $$
  select p.gamertag, cm.role, coalesce(st.total_score, 0), public.is_member(p.id)
  from public.crew_members cm join public.profiles p on p.id = cm.user_id
  left join public.player_stats st on st.user_id = cm.user_id
  where cm.crew_id = p_crew order by 3 desc limit 500;
$$;

create or replace function public.player_profile(p_gamertag text)
returns table (id uuid, gamertag text, platform text, country text, city text, bio text, discord_handle text,
               member boolean, total_score bigint, verified_runs bigint, global_rank bigint,
               respects bigint, crew_id bigint, crew_name text, crew_tag text, joined date)
language sql stable security definer set search_path = '' as $$
  with me as (select * from public.profiles where lower(gamertag) = lower(p_gamertag) limit 1)
  select me.id, me.gamertag, me.platform, me.country, me.city, me.bio, me.discord_handle,
         public.is_member(me.id), coalesce(st.total_score, 0), coalesce(st.runs, 0)::bigint,
         case when coalesce(st.runs, 0) > 0 then 1 + (select count(*) from public.player_stats x where x.total_score > st.total_score) end,
         (select count(*) from public.respects x where x.receiver = me.id),
         c.id, c.name, c.tag, me.created_at::date
  from me
  left join public.player_stats st on st.user_id = me.id
  left join public.crew_members cm on cm.user_id = me.id
  left join public.crews c on c.id = cm.crew_id;
$$;

create or replace function public.friends_board(p_month date default null)
returns table (rank bigint, gamertag text, city text, country text, score bigint, missions bigint, is_me boolean)
language sql stable security definer set search_path = '' as $$
  with circle as (
    select auth.uid() as uid
    union
    select case when f.requester = auth.uid() then f.addressee else f.requester end
    from public.friendships f where f.status = 'accepted' and (f.requester = auth.uid() or f.addressee = auth.uid())
    limit 1000
  )
  select rank() over (order by coalesce(s.score, 0) desc), p.gamertag, p.city, p.country,
         coalesce(s.score, 0)::bigint, coalesce(s.runs, 0)::bigint, p.id = auth.uid()
  from circle c join public.profiles p on p.id = c.uid
  left join public.player_period_scores s on s.user_id = c.uid and s.period_type = 'month'
    and s.period_key = to_char(coalesce(p_month, (now() at time zone 'America/Toronto')::date), 'YYYY-MM')
  where auth.uid() is not null
  order by 5 desc, p.gamertag;
$$;

create or replace function public.room_messages(p_room text, p_before bigint default null, p_limit int default 50)
returns table (id bigint, room text, user_id uuid, gamertag text, member boolean, honor text, body text, created_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select * from (
    select m.id, m.room, m.user_id, p.gamertag, public.is_member(p.id),
           case when st.world > 0 then 'world' when st.cont_b > 0 then 'continent' when st.city_b > 0 then 'city' end,
           m.body, m.created_at
    from public.chat_messages m join public.profiles p on p.id = m.user_id
    left join public.player_stats st on st.user_id = m.user_id
    where m.room = p_room and public.can_read_room(p_room) and (p_before is null or m.id < p_before)
    order by m.id desc
    limit least(greatest(coalesce(p_limit, 50), 1), 100)
  ) x order by id;
$$;

create or replace function public.chat_message(p_id bigint)
returns table (id bigint, room text, user_id uuid, gamertag text, member boolean, honor text, body text, created_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select m.id, m.room, m.user_id, p.gamertag, public.is_member(p.id),
         case when st.world > 0 then 'world' when st.cont_b > 0 then 'continent' when st.city_b > 0 then 'city' end,
         m.body, m.created_at
  from public.chat_messages m join public.profiles p on p.id = m.user_id
  left join public.player_stats st on st.user_id = m.user_id
  where m.id = p_id and public.can_read_room(m.room);
$$;

-- "Chatting now": players who posted in the last 10 minutes (cheap, no presence fan-out).
create index if not exists chat_messages_room_time_idx on public.chat_messages (room, created_at desc);
create or replace function public.room_active(p_room text)
returns bigint language sql stable security definer set search_path = '' as $$
  select count(distinct user_id) from (
    select user_id from public.chat_messages
    where room = p_room and created_at > now() - interval '10 minutes' and public.can_read_room(p_room)
    order by created_at desc limit 2000) x;
$$;

-- Extra indexes for common lookups.
create index if not exists submissions_user_time_idx on public.submissions (user_id, created_at desc);
create index if not exists notifications_unread_idx on public.notifications (user_id) where read_at is null;
create index if not exists lfg_user_idx on public.lfg_posts (user_id, expires_at);
create index if not exists challenges_opponent_idx on public.challenges (opponent);
create index if not exists challenges_challenger_idx on public.challenges (challenger);
create index if not exists respects_receiver_idx on public.respects (receiver);
create index if not exists badges_user_idx on public.badges (user_id, month desc);
create index if not exists badges_month_idx on public.badges (month desc);

-- ============ Waitlist: sharded counter, safe codes, abuse limit ============
create table if not exists public.waitlist_counter (shard int primary key, n bigint not null default 0);
alter table public.waitlist_counter enable row level security;
insert into public.waitlist_counter (shard, n) select g, 0 from generate_series(0, 15) g on conflict do nothing;
update public.waitlist_counter set n = 0;
update public.waitlist_counter set n = (select count(*) from public.waitlist) where shard = 0;

create table if not exists public.waitlist_ip_hits (
  ip text not null, hour timestamptz not null, n int not null default 0, primary key (ip, hour)
);
alter table public.waitlist_ip_hits enable row level security;

create or replace function public.waitlist_count()
returns bigint language sql stable security definer set search_path = '' as $$
  select coalesce((select (value #>> '{}')::bigint from public.settings where key = 'waitlist_base'), 0)
       + (select coalesce(sum(n), 0) from public.waitlist_counter);
$$;

create or replace function public.join_waitlist(p_email text, p_gamertag text, p_platform text, p_ref text default null)
returns table (queue_position bigint, ref_code text, already_joined boolean)
language plpgsql security definer set search_path = '' as $$
declare
  r public.waitlist;
  base bigint := coalesce((select (value #>> '{}')::bigint from public.settings where key = 'waitlist_base'), 0);
  v_ip text := coalesce(nullif(split_part(coalesce((current_setting('request.headers', true)::json ->> 'x-forwarded-for'), ''), ',', 1), ''),
                      (current_setting('request.headers', true)::json ->> 'cf-connecting-ip'), 'unknown');
  hits int;
  tries int := 0;
begin
  select * into r from public.waitlist w where lower(w.email) = lower(trim(p_email));
  if found then
    return query select base + r.id, r.referral_code, true;
    return;
  end if;
  insert into public.waitlist_ip_hits as h (ip, hour, n) values (v_ip, date_trunc('hour', now()), 1)
  on conflict (ip, hour) do update set n = h.n + 1 returning n into hits;
  if v_ip <> 'unknown' and hits > 20 then
    raise exception 'Too many sign-ups from your network. Try again later.';
  end if;
  loop
    begin
      insert into public.waitlist (email, gamertag, platform, referred_by, referral_code)
      values (lower(trim(p_email)), trim(p_gamertag), p_platform, nullif(left(trim(coalesce(p_ref, '')), 16), ''),
              substr(replace(gen_random_uuid()::text, '-', ''), 1, 10))
      returning * into r;
      exit;
    exception when unique_violation then
      -- Same email signing up twice at once: return the existing row. Otherwise retry with a new code.
      select * into r from public.waitlist w where lower(w.email) = lower(trim(p_email));
      if found then return query select base + r.id, r.referral_code, true; return; end if;
      tries := tries + 1;
      if tries > 5 then raise; end if;
    end;
  end loop;
  update public.waitlist_counter set n = n + 1 where shard = floor(random() * 16)::int;
  return query select base + r.id, r.referral_code, false;
end;
$$;

-- Daily cleanup: old read notifications and old rate-limit rows.
select cron.schedule('ty-daily-cleanup', '17 9 * * *',
  $$delete from public.notifications where read_at is not null and created_at < now() - interval '60 days';
    delete from public.waitlist_ip_hits where hour < now() - interval '2 days';$$);

-- ============ Realtime via Broadcast ============
-- Messages and alerts are pushed once to a private channel; Realtime checks access once when someone joins.
create or replace function public.rt_chat_message()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    perform realtime.send(
      (select to_jsonb(x) from public.chat_message(new.id) x limit 1),
      'message', 'chat:' || new.room, true);
  else
    perform realtime.send(jsonb_build_object('id', old.id), 'deleted', 'chat:' || old.room, true);
  end if;
  return null;
end;
$$;
drop trigger if exists rt_chat_message on public.chat_messages;
create trigger rt_chat_message after insert or delete on public.chat_messages for each row execute function public.rt_chat_message();

create or replace function public.rt_dm()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform realtime.send(jsonb_build_object('id', new.id, 'sender', new.sender, 'recipient', new.recipient, 'body', new.body, 'created_at', new.created_at),
                        'dm', 'user:' || new.recipient, true);
  return null;
end;
$$;
drop trigger if exists rt_dm on public.dm_messages;
create trigger rt_dm after insert on public.dm_messages for each row execute function public.rt_dm();

create or replace function public.rt_notification()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform realtime.send(to_jsonb(new), 'notification', 'user:' || new.user_id, true);
  return null;
end;
$$;
drop trigger if exists rt_notification on public.notifications;
create trigger rt_notification after insert on public.notifications for each row execute function public.rt_notification();

revoke execute on function public.rt_chat_message() from public, anon, authenticated;
revoke execute on function public.rt_dm() from public, anon, authenticated;
revoke execute on function public.rt_notification() from public, anon, authenticated;

-- Who may listen: chat rooms they can read; their own user channel. Nobody can send broadcasts directly.
do $$ begin
  create policy "ty listen to readable rooms" on realtime.messages for select to anon, authenticated
    using (realtime.messages.extension = 'broadcast'
           and (select realtime.topic()) like 'chat:%'
           and (select public.can_read_room(substr((select realtime.topic()), 6))));
  create policy "ty listen to own user channel" on realtime.messages for select to authenticated
    using (realtime.messages.extension = 'broadcast'
           and (select realtime.topic()) = 'user:' || (select auth.uid())::text);
exception when duplicate_object then null; end $$;

-- Stop the old per-listener change feed now that Broadcast carries everything.
alter publication supabase_realtime drop table public.chat_messages;
alter publication supabase_realtime drop table public.dm_messages;
alter publication supabase_realtime drop table public.notifications;

-- (013) DMs get their own private channel: dm:<user id>
create or replace function public.rt_dm()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform realtime.send(jsonb_build_object('id', new.id, 'sender', new.sender, 'recipient', new.recipient, 'body', new.body, 'created_at', new.created_at),
                        'dm', 'dm:' || new.recipient, true);
  return null;
end;
$$;
do $$ begin
  create policy "ty listen to own dm channel" on realtime.messages for select to authenticated
    using (realtime.messages.extension = 'broadcast' and (select realtime.topic()) = 'dm:' || (select auth.uid())::text);
exception when duplicate_object then null; end $$;
