-- Throneyard — security fixes found in testing.
-- 1) Admin check: admins only, plus scheduled jobs that set the private ty.cron flag
--    (API clients can't set server settings, so they can never get this).
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.admins where user_id = auth.uid())
      or coalesce(current_setting('ty.cron', true), '') = 'on';
$$;

create or replace function public.run_monthly_honors()
returns void language plpgsql security definer set search_path = '' as $$
declare
  cur date := date_trunc('month', now() at time zone 'America/Toronto')::date;
  prev date := (date_trunc('month', now() at time zone 'America/Toronto') - interval '1 month')::date;
  base date;
  sat date;
begin
  perform set_config('ty.cron', 'on', true);
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

create or replace function public.run_world_champion()
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform set_config('ty.cron', 'on', true);
  perform public.award_monthly_badges((date_trunc('month', now() at time zone 'America/Toronto') - interval '1 month')::date);
end;
$$;
revoke execute on function public.run_monthly_honors() from public, anon, authenticated;
revoke execute on function public.run_world_champion() from public, anon, authenticated;

-- 2) Blocks must stop DMs in both directions, even though players can't see who blocked them.
create or replace function public.blocked_between(a uuid, b uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.blocks
                 where (blocker = a and blocked = b) or (blocker = b and blocked = a));
$$;

alter policy "send dm to friends" on public.dm_messages
  with check (sender = (select auth.uid())
              and (select public.are_friends(sender, recipient))
              and not (select public.blocked_between(sender, recipient)));
