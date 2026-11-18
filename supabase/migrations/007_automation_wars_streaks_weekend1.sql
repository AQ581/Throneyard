-- Throneyard — automatic monthly honors, City/Platform Wars, weekend streaks, Weekend 1 missions.

create extension if not exists pg_cron;

-- Scheduled jobs run as the database owner, so let them act as admin.
-- API users always connect through 'authenticator', so this never applies to them.
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select session_user = 'postgres'
      or exists (select 1 from public.admins where user_id = auth.uid());
$$;

-- 1st of each month: badges + finalists for last month, and a World Final mission.
create or replace function public.run_monthly_honors()
returns void language plpgsql security definer set search_path = '' as $$
declare
  cur date := date_trunc('month', now() at time zone 'America/Toronto')::date;
  prev date := (date_trunc('month', now() at time zone 'America/Toronto') - interval '1 month')::date;
  base date;
  sat date;
begin
  perform public.award_monthly_badges(prev);
  perform public.lock_world_finalists(prev);
  if not exists (select 1 from public.missions where kind = 'world_final' and final_month = prev) then
    base := cur + 2;
    sat := base + ((6 - extract(dow from base)::int + 7) % 7);
    insert into public.missions (title, description, week_label, max_points, opens_at, closes_at, kind, final_month)
    values ('World Final · ' || to_char(prev, 'FMMonth YYYY'),
            'Every country''s best player from ' || to_char(prev, 'FMMonth') || ' battles here. Same rules as Clean Getaway: fastest clean escape from the highest wanted level wins. Edit these rules in Supabase if you want a different final.',
            'World Final', 1000,
            (sat::timestamp + time '12:00') at time zone 'America/Toronto',
            ((sat + 1)::timestamp + time '23:59') at time zone 'America/Toronto',
            'world_final', prev);
  end if;
end;
$$;

-- 9th of each month: re-award last month so the World Champion is crowned.
create or replace function public.run_world_champion()
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.award_monthly_badges((date_trunc('month', now() at time zone 'America/Toronto') - interval '1 month')::date);
end;
$$;
revoke execute on function public.run_monthly_honors() from public, anon, authenticated;
revoke execute on function public.run_world_champion() from public, anon, authenticated;

select cron.schedule('nb-monthly-honors', '0 11 1 * *', 'select public.run_monthly_honors()');
select cron.schedule('nb-world-champion', '0 11 9 * *', 'select public.run_world_champion()');

-- ---------- City Wars: every city's combined score this month ----------
create or replace function public.city_wars(p_month date default null, p_limit int default 50)
returns table (rank bigint, city text, country text, players bigint, score bigint, top_player text)
language sql stable security definer set search_path = '' as $$
  with bounds as (
    select (date_trunc('month', coalesce(p_month, (now() at time zone 'America/Toronto')::date))::timestamp
              at time zone 'America/Toronto') as s
  ), per_player as (
    select p.id, p.gamertag, p.city, p.country, sum(sub.score)::bigint as pts
    from public.submissions sub
    join public.profiles p on p.id = sub.user_id
    join public.missions m on m.id = sub.mission_id, bounds b
    where sub.status = 'verified' and m.kind = 'weekend'
      and m.opens_at >= b.s and m.opens_at < b.s + interval '1 month'
    group by p.id, p.gamertag, p.city, p.country
  )
  select rank() over (order by sum(pts) desc), initcap(min(city)), min(country), count(*), sum(pts)::bigint,
         (array_agg(gamertag order by pts desc))[1]
  from per_player
  group by lower(city), lower(country)
  order by sum(pts) desc
  limit least(greatest(coalesce(p_limit, 50), 1), 200);
$$;

-- ---------- Platform Wars: PS5 vs Xbox this month ----------
create or replace function public.platform_wars(p_month date default null)
returns table (platform text, players bigint, score bigint)
language sql stable security definer set search_path = '' as $$
  with bounds as (
    select (date_trunc('month', coalesce(p_month, (now() at time zone 'America/Toronto')::date))::timestamp
              at time zone 'America/Toronto') as s
  ), runs as (
    select p.platform, sub.user_id, sub.score
    from public.submissions sub
    join public.profiles p on p.id = sub.user_id
    join public.missions m on m.id = sub.mission_id, bounds b
    where sub.status = 'verified' and m.kind = 'weekend'
      and m.opens_at >= b.s and m.opens_at < b.s + interval '1 month'
  )
  select pl.platform, count(distinct r.user_id), coalesce(sum(r.score), 0)::bigint
  from (values ('ps5'), ('xbox')) pl(platform)
  left join runs r on r.platform = pl.platform
  group by pl.platform
  order by pl.platform;
$$;

-- ---------- Weekend streaks ----------
create or replace function public.player_streak(p_gamertag text)
returns table (current_streak int, best_streak int)
language sql stable security definer set search_path = '' as $$
  with w as (
    select distinct date_trunc('week', m.opens_at at time zone 'America/Toronto')::date as wk
    from public.submissions s
    join public.missions m on m.id = s.mission_id
    join public.profiles p on p.id = s.user_id
    where lower(p.gamertag) = lower(p_gamertag) and s.status = 'verified' and m.kind = 'weekend'
  ), g as (
    select wk, wk - (row_number() over (order by wk))::int * 7 as grp from w
  ), isl as (
    select count(*)::int as n, max(wk) as last_wk from g group by grp
  )
  select coalesce((select n from isl
                   where last_wk >= date_trunc('week', now() at time zone 'America/Toronto')::date - 7
                   order by last_wk desc limit 1), 0),
         coalesce((select max(n) from isl), 0);
$$;

-- ---------- Weekend 1 missions (launch weekend) ----------
-- Fri Nov 20, 6:00 PM ET → Sun Nov 22, 11:59 PM ET. Members can start 24h early.
insert into public.missions (title, description, week_label, max_points, opens_at, closes_at, members_only)
select * from (values
  ('Clean Getaway',
   'Reach the highest wanted level you can, then lose the police completely. Record from the moment the top level hits until it fully clears. Score by escape time: under 2:00 = 1000 · 2:00–3:59 = 750 · 4:00–5:59 = 500 · any clean escape = 250.',
   'Weekend 1', 1000, timestamptz '2026-11-20 18:00 America/Toronto', timestamptz '2026-11-22 23:59 America/Toronto', false),
  ('Last One Standing',
   'Reach the highest wanted level you can and survive as long as possible. The clock runs from max wanted to death or arrest. 10:00+ = 1000 · 7:00+ = 750 · 4:00+ = 500 · 2:00+ = 250.',
   'Weekend 1', 1000, timestamptz '2026-11-20 18:00 America/Toronto', timestamptz '2026-11-22 23:59 America/Toronto', false),
  ('Heist Speedrun',
   'Complete the first heist or robbery mission available to you, start to finish, in one unbroken recording. Fastest times win: top 10% of the weekend = 1000 · top 25% = 750 · top 50% = 500 · completed = 250.',
   'Weekend 1', 1000, timestamptz '2026-11-20 18:00 America/Toronto', timestamptz '2026-11-22 23:59 America/Toronto', false),
  ('Stunt King',
   'Land your single best vehicle stunt. Judged on height, distance, rotation and a clean landing. Legendary = 1000 · great = 750 · solid = 500 · clean landing = 250.',
   'Weekend 1', 1000, timestamptz '2026-11-20 18:00 America/Toronto', timestamptz '2026-11-22 23:59 America/Toronto', false),
  ('Night Shift (Members)',
   'Clean Getaway on foot only, at night in-game. No vehicles at any point. Under 3:00 = 500 · 3:00–5:59 = 350 · any clean escape = 200.',
   'Weekend 1', 500, timestamptz '2026-11-20 18:00 America/Toronto', timestamptz '2026-11-22 23:59 America/Toronto', true),
  ('Double Down (Members)',
   'Two Clean Getaways back-to-back in one unbroken recording. Total time under 5:00 = 500 · under 8:00 = 350 · both completed = 200.',
   'Weekend 1', 500, timestamptz '2026-11-20 18:00 America/Toronto', timestamptz '2026-11-22 23:59 America/Toronto', true)
) v(title, description, week_label, max_points, opens_at, closes_at, members_only)
where not exists (select 1 from public.missions where week_label = 'Weekend 1');
