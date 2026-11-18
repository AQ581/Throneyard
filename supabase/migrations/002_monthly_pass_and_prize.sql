-- Throneyard — Monthly Pass ($5.99) and Monthly Championship ($15,000)

-- ---------- Settings ----------
insert into public.settings (key, value) values
  ('prize_amount', '15000'),
  ('prize_currency', '"USD"'),
  ('pass_price', '"5.99"'),
  ('prize_countries', '["CA","US"]'),
  ('prize_blocked_regions', '["US-AZ","US-AR","US-CT","US-DE","US-IN","US-LA","US-ME","US-MT","US-SC","US-SD","US-TN","US-VT","CA-QC"]')
on conflict (key) do nothing;

-- ---------- Residence on profiles ----------
-- ISO country + region, e.g. 'CA-ON', 'US-TX'. Needed for prize eligibility.
alter table public.profiles add column residence text
  check (residence is null or residence ~ '^[A-Z]{2}(-[A-Z0-9]{1,3})?$');

create or replace function public.residence_allowed(p_residence text)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_residence is not null
    and exists (
      select 1 from public.settings s, jsonb_array_elements_text(s.value) c
      where s.key = 'prize_countries' and c = split_part(p_residence, '-', 1)
    )
    and not exists (
      select 1 from public.settings s, jsonb_array_elements_text(s.value) r
      where s.key = 'prize_blocked_regions' and r = p_residence
    );
$$;

-- ---------- Memberships (written only by the Stripe webhook) ----------
create table public.memberships (
  user_id uuid primary key references auth.users on delete cascade,
  stripe_customer_id text unique,
  stripe_subscription_id text,
  status text not null default 'none',
  current_period_end timestamptz,
  updated_at timestamptz not null default now()
);
alter table public.memberships enable row level security;
create policy "read own membership" on public.memberships for select to authenticated
  using (user_id = (select auth.uid()));

create or replace function public.prize_eligible_for(p_user uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
      select 1 from public.memberships m
      where m.user_id = p_user and m.status in ('active', 'trialing')
        and (m.current_period_end is null or m.current_period_end > now())
    )
    and public.residence_allowed((select residence from public.profiles where id = p_user));
$$;

-- ---------- Submissions: record eligibility at time of entry ----------
alter table public.submissions add column prize_eligible boolean not null default false;

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
  if left(new.video_path, length(folder)) <> folder then raise exception 'Invalid video path'; end if;
  if coalesce(array_length(new.image_paths, 1), 0) > 6 then raise exception 'Up to 6 screenshots'; end if;
  foreach p in array new.image_paths loop
    if left(p, length(folder)) <> folder then raise exception 'Invalid image path'; end if;
  end loop;
  return new;
end;
$$;

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

revoke execute on function public.submissions_before_insert() from public, anon, authenticated;
revoke execute on function public.submissions_before_update() from public, anon, authenticated;

-- ---------- Monthly Championship board ----------
-- Month = missions that open in that calendar month (Toronto time).
-- score = all verified points (everyone ranks). prize_score = verified points
-- from runs submitted with an active pass from an eligible location.
create or replace function public.monthly_board(p_month date default null, p_limit int default 50)
returns table (rank bigint, gamertag text, platform text, country text, city text,
               missions bigint, score bigint, prize_score bigint, prize_rank bigint)
language sql stable security definer set search_path = '' as $$
  with bounds as (
    select (date_trunc('month', coalesce(p_month, (now() at time zone 'America/Toronto')::date))::timestamp
              at time zone 'America/Toronto') as s
  ), agg as (
    select p.id, p.gamertag, p.platform, p.country, p.city,
           count(*) as missions,
           sum(sub.score)::bigint as score,
           coalesce(sum(sub.score) filter (where sub.prize_eligible), 0)::bigint as prize_score,
           min(sub.reviewed_at) as first_review
    from public.submissions sub
    join public.profiles p on p.id = sub.user_id
    join public.missions m on m.id = sub.mission_id, bounds b
    where sub.status = 'verified'
      and m.opens_at >= b.s and m.opens_at < b.s + interval '1 month'
    group by p.id, p.gamertag, p.platform, p.country, p.city
  )
  select rank() over (order by score desc),
         gamertag, platform, country, city, missions, score, prize_score,
         case when prize_score > 0 then rank() over (order by prize_score desc) end
  from agg
  order by score desc, first_review asc
  limit least(greatest(coalesce(p_limit, 50), 1), 200);
$$;

-- ---------- Admin: prize contenders with contact email ----------
create or replace function public.admin_prize_contenders(p_month date default null, p_limit int default 10)
returns table (prize_rank bigint, gamertag text, email text, residence text, prize_score bigint, pass_status text)
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
    where sub.status = 'verified' and sub.prize_eligible
      and m.opens_at >= b.s and m.opens_at < b.s + interval '1 month'
    group by sub.user_id
  )
  select rank() over (order by a.pts desc), p.gamertag, u.email::text, p.residence, a.pts, coalesce(ms.status, 'none')
  from agg a
  join public.profiles p on p.id = a.user_id
  join auth.users u on u.id = a.user_id
  left join public.memberships ms on ms.user_id = a.user_id
  order by a.pts desc
  limit least(greatest(coalesce(p_limit, 10), 1), 100);
end;
$$;
revoke execute on function public.admin_prize_contenders(date, int) from anon;
