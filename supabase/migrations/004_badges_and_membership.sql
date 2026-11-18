-- (Non-destructive: safe to run once; old functions are left in place.)
-- Throneyard — cash prizes removed (honor badges instead) + Throne Pass perks ($5.99/mo).
-- City Champion, Continental Champion, World Champion (World Final winner). Open to every player worldwide.

-- Every country maps to a continent now (no eligibility limits).
insert into public.settings (key, value) values ('continent_map', '{"AD":"EU","AE":"AS","AF":"AS","AG":"NA","AI":"NA","AL":"EU","AM":"AS","AO":"AF","AR":"SA","AS":"OC","AT":"EU","AU":"OC","AW":"NA","AX":"EU","AZ":"AS","BA":"EU","BB":"NA","BD":"AS","BE":"EU","BF":"AF","BG":"EU","BH":"AS","BI":"AF","BJ":"AF","BL":"NA","BM":"NA","BN":"AS","BO":"SA","BQ":"NA","BR":"SA","BS":"NA","BT":"AS","BW":"AF","BY":"EU","BZ":"NA","CA":"NA","CC":"AS","CD":"AF","CF":"AF","CG":"AF","CH":"EU","CI":"AF","CK":"OC","CL":"SA","CM":"AF","CN":"AS","CO":"SA","CR":"NA","CU":"NA","CV":"AF","CW":"NA","CX":"AS","CY":"AS","CZ":"EU","DE":"EU","DJ":"AF","DK":"EU","DM":"NA","DO":"NA","DZ":"AF","EC":"SA","EE":"EU","EG":"AF","EH":"AF","ER":"AF","ES":"EU","ET":"AF","FI":"EU","FJ":"OC","FK":"SA","FM":"OC","FO":"EU","FR":"EU","GA":"AF","GB":"EU","GD":"NA","GE":"AS","GF":"SA","GG":"EU","GH":"AF","GI":"EU","GL":"NA","GM":"AF","GN":"AF","GP":"NA","GQ":"AF","GR":"EU","GS":"SA","GT":"NA","GU":"OC","GW":"AF","GY":"SA","HK":"AS","HN":"NA","HR":"EU","HT":"NA","HU":"EU","ID":"AS","IE":"EU","IL":"AS","IM":"EU","IN":"AS","IO":"AS","IQ":"AS","IR":"AS","IS":"EU","IT":"EU","JE":"EU","JM":"NA","JO":"AS","JP":"AS","KE":"AF","KG":"AS","KH":"AS","KI":"OC","KM":"AF","KN":"NA","KP":"AS","KR":"AS","KW":"AS","KY":"NA","KZ":"AS","LA":"AS","LB":"AS","LC":"NA","LI":"EU","LK":"AS","LR":"AF","LS":"AF","LT":"EU","LU":"EU","LV":"EU","LY":"AF","MA":"AF","MC":"EU","MD":"EU","ME":"EU","MF":"NA","MG":"AF","MH":"OC","MK":"EU","ML":"AF","MM":"AS","MN":"AS","MO":"AS","MP":"OC","MQ":"NA","MR":"AF","MS":"NA","MT":"EU","MU":"AF","MV":"AS","MW":"AF","MX":"NA","MY":"AS","MZ":"AF","NA":"AF","NC":"OC","NE":"AF","NF":"OC","NG":"AF","NI":"NA","NL":"EU","NO":"EU","NP":"AS","NR":"OC","NU":"OC","NZ":"OC","OM":"AS","PA":"NA","PE":"SA","PF":"OC","PG":"OC","PH":"AS","PK":"AS","PL":"EU","PM":"NA","PN":"OC","PR":"NA","PS":"AS","PT":"EU","PW":"OC","PY":"SA","QA":"AS","RE":"AF","RO":"EU","RS":"EU","RU":"EU","RW":"AF","SA":"AS","SB":"OC","SC":"AF","SD":"AF","SE":"EU","SG":"AS","SH":"AF","SI":"EU","SJ":"EU","SK":"EU","SL":"AF","SM":"EU","SN":"AF","SO":"AF","SR":"SA","SS":"AF","ST":"AF","SV":"NA","SX":"NA","SY":"AS","SZ":"AF","TC":"NA","TD":"AF","TG":"AF","TH":"AS","TJ":"AS","TK":"OC","TL":"AS","TM":"AS","TN":"AF","TO":"OC","TR":"AS","TT":"NA","TV":"OC","TW":"AS","TZ":"AF","UA":"EU","UG":"AF","US":"NA","UY":"SA","UZ":"AS","VA":"EU","VC":"NA","VE":"SA","VG":"NA","VI":"NA","VN":"AS","VU":"OC","WF":"OC","WS":"OC","YE":"AS","YT":"AF","ZA":"AF","ZM":"AF","ZW":"AF"}'::jsonb)
on conflict (key) do update set value = excluded.value;
insert into public.settings (key, value) values
  ('pass_price', '"5.99"'), ('member_early_hours', '24'), ('member_max_screenshots', '12'), ('free_max_screenshots', '6')
on conflict (key) do update set value = excluded.value;

-- ---------- Membership ----------
create or replace function public.is_member(p_user uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.memberships m
    where m.user_id = p_user and m.status in ('active', 'trialing')
      and (m.current_period_end is null or m.current_period_end > now())
  );
$$;
revoke execute on function public.is_member(uuid) from public, anon, authenticated;

alter table public.missions add column if not exists members_only boolean not null default false;
alter table public.submissions add column if not exists by_member boolean not null default false;
create index if not exists submissions_queue_idx on public.submissions (status, by_member desc, created_at);

-- Residence is now just a country code (old 'CA-ON' style values still work).
-- Submissions no longer depend on a pass.
create or replace function public.submissions_before_insert()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  m public.missions;
  folder text := auth.uid()::text || '/';
  p text;
  member boolean := public.is_member(new.user_id);
  early interval := make_interval(hours => coalesce((select (value #>> '{}')::int from public.settings where key = 'member_early_hours'), 24));
  max_shots int;
begin
  new.status := 'pending';
  new.score := 0;
  new.reject_reason := null;
  new.reviewed_by := null;
  new.reviewed_at := null;
  new.created_at := now();
  new.prize_eligible := false;
  new.by_member := member;
  select * into m from public.missions where id = new.mission_id;
  if not found then raise exception 'Mission not found'; end if;
  if m.members_only and not member then
    raise exception 'This is a members-only mission';
  end if;
  if now() > m.closes_at
     or now() < m.opens_at - (case when member and m.kind = 'weekend' then early else interval '0' end) then
    raise exception 'This mission is not open for submissions right now';
  end if;
  if m.kind = 'world_final' and not exists (
    select 1 from public.world_finalists f where f.month = m.final_month and f.user_id = new.user_id
  ) then
    raise exception 'Only World Finalists can enter this mission';
  end if;
  if left(new.video_path, length(folder)) <> folder then raise exception 'Invalid video path'; end if;
  max_shots := coalesce((select (value #>> '{}')::int from public.settings
                         where key = case when member then 'member_max_screenshots' else 'free_max_screenshots' end), 6);
  if coalesce(array_length(new.image_paths, 1), 0) > max_shots then
    raise exception 'Too many screenshots (max %)', max_shots;
  end if;
  foreach p in array new.image_paths loop
    if left(p, length(folder)) <> folder then raise exception 'Invalid image path'; end if;
  end loop;
  return new;
end;
$$;
revoke execute on function public.submissions_before_insert() from public, anon, authenticated;

create or replace function public.submissions_before_update()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  maxp int;
begin
  new.user_id := old.user_id;
  new.mission_id := old.mission_id;
  new.video_path := old.video_path;
  new.image_paths := old.image_paths;
  new.notes := old.notes;
  new.file_checks := old.file_checks;
  new.created_at := old.created_at;
  new.prize_eligible := old.prize_eligible;
  new.by_member := old.by_member;
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
revoke execute on function public.submissions_before_update() from public, anon, authenticated;

-- ---------- Leaderboard with member flag ----------
create or replace function public.leaderboard_v2(
  p_scope text default 'global', p_country text default null, p_city text default null,
  p_week text default null, p_limit int default 50
)
returns table (rank bigint, gamertag text, platform text, country text, city text, missions bigint, score bigint, member boolean)
language sql stable security definer set search_path = '' as $$
  select rank() over (order by sum(s.score) desc), p.gamertag, p.platform, p.country, p.city,
         count(*), sum(s.score)::bigint, public.is_member(p.id)
  from public.submissions s
  join public.profiles p on p.id = s.user_id
  join public.missions m on m.id = s.mission_id
  where s.status = 'verified' and m.kind = 'weekend'
    and (p_week is null or m.week_label = p_week)
    and (p_scope = 'global'
      or (p_scope = 'country' and lower(p.country) = lower(p_country))
      or (p_scope = 'city' and lower(p.country) = lower(p_country) and lower(p.city) = lower(p_city)))
  group by p.id, p.gamertag, p.platform, p.country, p.city
  order by sum(s.score) desc, min(s.reviewed_at) asc
  limit least(greatest(coalesce(p_limit, 50), 1), 200);
$$;


-- ---------- Monthly board (everyone counts) ----------
create or replace function public.monthly_board_v2(p_month date default null, p_continent text default null, p_limit int default 50)
returns table (rank bigint, gamertag text, platform text, country text, city text, continent text, missions bigint, score bigint, member boolean)
language sql stable security definer set search_path = '' as $$
  with bounds as (
    select (date_trunc('month', coalesce(p_month, (now() at time zone 'America/Toronto')::date))::timestamp
              at time zone 'America/Toronto') as s
  ), agg as (
    select p.id, p.gamertag, p.platform, p.country, p.city,
           public.continent_of(p.residence) as continent,
           count(*) as missions, sum(sub.score)::bigint as score, min(sub.reviewed_at) as first_review
    from public.submissions sub
    join public.profiles p on p.id = sub.user_id
    join public.missions m on m.id = sub.mission_id, bounds b
    where sub.status = 'verified' and m.kind = 'weekend'
      and m.opens_at >= b.s and m.opens_at < b.s + interval '1 month'
      and (p_continent is null or public.continent_of(p.residence) = p_continent)
    group by p.id, p.gamertag, p.platform, p.country, p.city, p.residence
  )
  select rank() over (order by score desc), gamertag, platform, country, city, continent, missions, score, public.is_member(id)
  from agg
  order by score desc, first_review asc
  limit least(greatest(coalesce(p_limit, 50), 1), 200);
$$;

-- ---------- World Finalists: every country's #1 (all players) ----------
create or replace function public.lock_world_finalists(p_month date)
returns int language plpgsql security definer set search_path = '' as $$
declare
  m date := date_trunc('month', p_month)::date;
  start_ts timestamptz := (m::timestamp at time zone 'America/Toronto');
  min_field int := coalesce((select (value #>> '{}')::int from public.settings where key = 'world_final_min'), 4);
  n int;
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  delete from public.world_finalists where month = m;
  with pts as (
    select sub.user_id,
           coalesce(nullif(split_part(p.residence, '-', 1), ''), lower(p.country)) as cc,
           sum(sub.score)::bigint as total
    from public.submissions sub
    join public.profiles p on p.id = sub.user_id
    join public.missions mi on mi.id = sub.mission_id
    where sub.status = 'verified' and mi.kind = 'weekend'
      and mi.opens_at >= start_ts and mi.opens_at < start_ts + interval '1 month'
    group by sub.user_id, p.residence, p.country
  ), ranked as (
    select *, rank() over (partition by cc order by total desc) as country_rank,
              row_number() over (order by total desc) as overall
    from pts
  ), champs as (
    select user_id, overall, 'Country #1 (' || cc || ')' as reason from ranked where country_rank = 1
  ), fill as (
    select user_id, overall, 'Top overall' as reason from ranked
    where user_id not in (select user_id from champs)
    order by overall
    limit greatest(min_field - (select count(*) from champs), 0)
  )
  insert into public.world_finalists (month, user_id, seed, reason)
  select m, user_id, row_number() over (order by overall), reason
  from (select * from champs union all select * from fill) x;
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke execute on function public.lock_world_finalists(date) from anon;

-- ---------- Badges ----------
create table if not exists public.badges (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  kind text not null check (kind in ('city', 'continent', 'world')),
  label text not null,
  month date not null,
  created_at timestamptz not null default now(),
  unique (user_id, kind, label, month)
);
alter table public.badges enable row level security;
do $$ begin
  create policy "badges are public" on public.badges for select using (true);
exception when duplicate_object then null; end $$;

-- Award City + Continental Champion badges for a month (admin). Re-running replaces them.
-- World Champion is awarded too if that month's World Final has a verified result.
create or replace function public.award_monthly_badges(p_month date)
returns table (kind text, awarded int) language plpgsql security definer set search_path = '' as $$
declare
  m date := date_trunc('month', p_month)::date;
  start_ts timestamptz := (m::timestamp at time zone 'America/Toronto');
  c_city int; c_cont int; c_world int;
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  delete from public.badges b where b.month = m;

  with pts as (
    select sub.user_id, p.city, p.country, public.continent_of(p.residence) as cont, sum(sub.score)::bigint as total
    from public.submissions sub
    join public.profiles p on p.id = sub.user_id
    join public.missions mi on mi.id = sub.mission_id
    where sub.status = 'verified' and mi.kind = 'weekend'
      and mi.opens_at >= start_ts and mi.opens_at < start_ts + interval '1 month'
    group by sub.user_id, p.city, p.country, p.residence
    having sum(sub.score) > 0
  ), r as (
    select *, rank() over (partition by lower(country), lower(city) order by total desc) as city_rank
    from pts
  )
  insert into public.badges (user_id, kind, label, month)
  select user_id, 'city', initcap(city) || ', ' || country, m from r where city_rank = 1;
  get diagnostics c_city = row_count;

  with pts as (
    select sub.user_id, public.continent_of(p.residence) as cont, sum(sub.score)::bigint as total
    from public.submissions sub
    join public.profiles p on p.id = sub.user_id
    join public.missions mi on mi.id = sub.mission_id
    where sub.status = 'verified' and mi.kind = 'weekend'
      and mi.opens_at >= start_ts and mi.opens_at < start_ts + interval '1 month'
    group by sub.user_id, p.residence
    having sum(sub.score) > 0 and public.continent_of(p.residence) is not null
  ), r as (
    select *, rank() over (partition by cont order by total desc) as cont_rank from pts
  )
  insert into public.badges (user_id, kind, label, month)
  select r.user_id, 'continent',
         coalesce((select s.value ->> r.cont from public.settings s where s.key = 'continent_names'), r.cont), m
  from r where cont_rank = 1;
  get diagnostics c_cont = row_count;

  with fin as (
    select sub.user_id, sum(sub.score)::bigint as total
    from public.submissions sub
    join public.missions mi on mi.id = sub.mission_id
    where mi.kind = 'world_final' and mi.final_month = m and sub.status = 'verified'
    group by sub.user_id
    having sum(sub.score) > 0
  ), r as (select *, rank() over (order by total desc) as rk from fin)
  insert into public.badges (user_id, kind, label, month)
  select user_id, 'world', 'World', m from r where rk = 1;
  get diagnostics c_world = row_count;

  return query values ('city'::text, c_city), ('continent'::text, c_cont), ('world'::text, c_world);
end;
$$;
revoke execute on function public.award_monthly_badges(date) from anon;

-- Badge counts per player, for showing honors next to names.
create or replace function public.badge_summary()
returns table (gamertag text, world bigint, continent bigint, city bigint, latest_label text)
language sql stable security definer set search_path = '' as $$
  select p.gamertag,
         count(*) filter (where b.kind = 'world'),
         count(*) filter (where b.kind = 'continent'),
         count(*) filter (where b.kind = 'city'),
         (array_agg(b.label order by b.month desc, case b.kind when 'world' then 0 when 'continent' then 1 else 2 end))[1]
  from public.badges b join public.profiles p on p.id = b.user_id
  group by p.gamertag;
$$;

-- Hall of Fame: most recent honors.
create or replace function public.hall_of_fame(p_limit int default 24)
returns table (gamertag text, kind text, label text, month date, city text, country text)
language sql stable security definer set search_path = '' as $$
  select p.gamertag, b.kind, b.label, b.month, p.city, p.country
  from public.badges b join public.profiles p on p.id = b.user_id
  order by b.month desc, case b.kind when 'world' then 0 when 'continent' then 1 else 2 end, p.gamertag
  limit least(greatest(coalesce(p_limit, 24), 1), 100);
$$;
