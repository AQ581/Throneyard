-- Throneyard — tiered prizes
-- City #1: badge only. Continental #1 (pass holders): $15,000/month.
-- World Final: each eligible country's #1 (min 4 finalists) battle; winner $50,000/month. Prizes stack.

insert into public.settings (key, value) values
  ('continent_prize', '15000'),
  ('world_prize', '50000'),
  ('world_final_min', '4'),
  ('continent_map', '{"CA":"NA","US":"NA"}'),
  ('continent_names', '{"NA":"North America","EU":"Europe","AS":"Asia","OC":"Oceania","SA":"South America","AF":"Africa"}')
on conflict (key) do nothing;
update public.settings set value = '15000' where key = 'prize_amount';

create or replace function public.continent_of(p_residence text)
returns text language sql stable security definer set search_path = '' as $$
  select s.value ->> split_part(coalesce(p_residence, ''), '-', 1)
  from public.settings s where s.key = 'continent_map';
$$;

-- ---------- World Final missions ----------
alter table public.missions
  add column kind text not null default 'weekend' check (kind in ('weekend', 'world_final')),
  add column final_month date;
alter table public.missions
  add constraint missions_final_month_required check (kind = 'weekend' or final_month is not null);

create table public.world_finalists (
  month date not null,
  user_id uuid not null references public.profiles (id) on delete cascade,
  seed int not null,
  reason text not null,
  primary key (month, user_id)
);
alter table public.world_finalists enable row level security;
-- No client policies: read through world_final_board(); written by lock_world_finalists().

-- ---------- Submissions: only finalists can enter a World Final ----------
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
  new.prize_eligible := public.prize_eligible_for(new.user_id);
  select * into m from public.missions where id = new.mission_id;
  if not found then raise exception 'Mission not found'; end if;
  if now() < m.opens_at or now() > m.closes_at then
    raise exception 'This mission is not open for submissions right now';
  end if;
  if m.kind = 'world_final' and not exists (
    select 1 from public.world_finalists f where f.month = m.final_month and f.user_id = new.user_id
  ) then
    raise exception 'Only World Finalists can enter this mission';
  end if;
  if left(new.video_path, length(folder)) <> folder then raise exception 'Invalid video path'; end if;
  if coalesce(array_length(new.image_paths, 1), 0) > 6 then raise exception 'Up to 6 screenshots'; end if;
  foreach p in array new.image_paths loop
    if left(p, length(folder)) <> folder then raise exception 'Invalid image path'; end if;
  end loop;
  return new;
end;
$$;
revoke execute on function public.submissions_before_insert() from public, anon, authenticated;

-- ---------- Weekend leaderboard: exclude World Final missions ----------
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
    and m.kind = 'weekend'
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

-- ---------- Monthly board with continent filter ----------
drop function if exists public.monthly_board(date, int);
create or replace function public.monthly_board(p_month date default null, p_continent text default null, p_limit int default 50)
returns table (rank bigint, gamertag text, platform text, country text, city text, continent text,
               missions bigint, score bigint, prize_score bigint, prize_rank bigint)
language sql stable security definer set search_path = '' as $$
  with bounds as (
    select (date_trunc('month', coalesce(p_month, (now() at time zone 'America/Toronto')::date))::timestamp
              at time zone 'America/Toronto') as s
  ), agg as (
    select p.id, p.gamertag, p.platform, p.country, p.city,
           public.continent_of(p.residence) as continent,
           count(*) as missions,
           sum(sub.score)::bigint as score,
           coalesce(sum(sub.score) filter (where sub.prize_eligible), 0)::bigint as prize_score,
           min(sub.reviewed_at) as first_review
    from public.submissions sub
    join public.profiles p on p.id = sub.user_id
    join public.missions m on m.id = sub.mission_id, bounds b
    where sub.status = 'verified' and m.kind = 'weekend'
      and m.opens_at >= b.s and m.opens_at < b.s + interval '1 month'
      and (p_continent is null or public.continent_of(p.residence) = p_continent)
    group by p.id, p.gamertag, p.platform, p.country, p.city, p.residence
  )
  select rank() over (order by score desc),
         gamertag, platform, country, city, continent, missions, score, prize_score,
         case when prize_score > 0 then rank() over (order by prize_score desc) end
  from agg
  order by score desc, first_review asc
  limit least(greatest(coalesce(p_limit, 50), 1), 200);
$$;

-- ---------- Lock World Finalists for a month (admin) ----------
-- Each eligible country's #1 by prize-eligible points (ties all qualify),
-- then the next-best prize-eligible players until the minimum field size.
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
    select sub.user_id, split_part(p.residence, '-', 1) as cc, sum(sub.score)::bigint as total
    from public.submissions sub
    join public.profiles p on p.id = sub.user_id
    join public.missions mi on mi.id = sub.mission_id
    where sub.status = 'verified' and sub.prize_eligible and mi.kind = 'weekend'
      and mi.opens_at >= start_ts and mi.opens_at < start_ts + interval '1 month'
    group by sub.user_id, p.residence
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

-- ---------- World Final board (public) ----------
create or replace function public.world_final_board(p_month date default null)
returns table (seed int, gamertag text, country text, city text, reason text, final_score bigint, final_rank bigint)
language sql stable security definer set search_path = '' as $$
  with mo as (
    select coalesce(date_trunc('month', p_month)::date,
           (date_trunc('month', (now() at time zone 'America/Toronto')) - interval '1 month')::date) as m
  ), scores as (
    select sub.user_id, sum(sub.score)::bigint as pts
    from public.submissions sub
    join public.missions mi on mi.id = sub.mission_id, mo
    where mi.kind = 'world_final' and mi.final_month = mo.m and sub.status = 'verified'
    group by sub.user_id
  )
  select f.seed, p.gamertag, p.country, p.city, f.reason,
         coalesce(s.pts, 0),
         case when s.pts is not null then rank() over (order by coalesce(s.pts, -1) desc) end
  from public.world_finalists f
  join public.profiles p on p.id = f.user_id
  left join scores s on s.user_id = f.user_id, mo
  where f.month = mo.m
  order by coalesce(s.pts, -1) desc, f.seed;
$$;

-- Lets a signed-in player see which World Finals they're in.
create or replace function public.my_world_finals()
returns setof date language sql stable security definer set search_path = '' as $$
  select month from public.world_finalists where user_id = auth.uid();
$$;

-- ---------- Admin contenders: add continent ----------
drop function if exists public.admin_prize_contenders(date, int);
create or replace function public.admin_prize_contenders(p_month date default null, p_limit int default 20)
returns table (prize_rank bigint, continent_rank bigint, gamertag text, email text, residence text,
               continent text, prize_score bigint, pass_status text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  return query
  with bounds as (
    select (date_trunc('month', coalesce(p_month, (now() at time zone 'America/Toronto')::date))::timestamp
              at time zone 'America/Toronto') as s
  ), agg as (
    select sub.user_id, sum(sub.score)::bigint as pts
    from public.submissions sub
    join public.missions m on m.id = sub.mission_id, bounds b
    where sub.status = 'verified' and sub.prize_eligible and m.kind = 'weekend'
      and m.opens_at >= b.s and m.opens_at < b.s + interval '1 month'
    group by sub.user_id
  )
  select rank() over (order by a.pts desc),
         rank() over (partition by public.continent_of(p.residence) order by a.pts desc),
         p.gamertag, u.email::text, p.residence, public.continent_of(p.residence), a.pts,
         coalesce(ms.status, 'none')
  from agg a
  join public.profiles p on p.id = a.user_id
  join auth.users u on u.id = a.user_id
  left join public.memberships ms on ms.user_id = a.user_id
  order by a.pts desc
  limit least(greatest(coalesce(p_limit, 20), 1), 100);
end;
$$;
revoke execute on function public.admin_prize_contenders(date, int) from anon;
