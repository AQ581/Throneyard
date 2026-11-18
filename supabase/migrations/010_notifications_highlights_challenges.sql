-- Throneyard — notifications, highlights (featured clips + reactions), 1v1 challenges.

-- ---------- Notifications ----------
create table if not exists public.notifications (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  kind text not null,
  title text not null,
  body text not null default '',
  link text not null default '',
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index if not exists notifications_user_idx on public.notifications (user_id, id desc);
alter table public.notifications enable row level security;
do $$ begin
  create policy "read own notifications" on public.notifications for select to authenticated using (user_id = (select auth.uid()));
  create policy "mark own read" on public.notifications for update to authenticated
    using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
  create policy "clear own" on public.notifications for delete to authenticated using (user_id = (select auth.uid()));
exception when duplicate_object then null; end $$;

create or replace function public.notify(p_user uuid, p_kind text, p_title text, p_body text, p_link text)
returns void language sql security definer set search_path = '' as $$
  insert into public.notifications (user_id, kind, title, body, link)
  select p_user, p_kind, p_title, coalesce(p_body, ''), coalesce(p_link, '')
  where p_user is not null and exists (select 1 from public.profiles where id = p_user);
$$;
revoke execute on function public.notify(uuid, text, text, text, text) from public, anon, authenticated;

create or replace function public.tag_of(p uuid)
returns text language sql stable security definer set search_path = '' as $$
  select gamertag from public.profiles where id = p;
$$;

-- Friend requests and accepts
create or replace function public.notify_friendships()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    perform public.notify(new.addressee, 'friend_request', public.tag_of(new.requester) || ' sent you a friend request', '', '/community.html#friends');
  elsif tg_op = 'UPDATE' and new.status = 'accepted' and old.status <> 'accepted' then
    perform public.notify(new.requester, 'friend_accept', public.tag_of(new.addressee) || ' accepted your friend request', 'You can message each other now.', '/chat.html#dm=' || public.tag_of(new.addressee));
  end if;
  return null;
end;
$$;
drop trigger if exists notify_friendships on public.friendships;
create trigger notify_friendships after insert or update on public.friendships
  for each row execute function public.notify_friendships();

-- Run reviewed
create or replace function public.notify_submissions()
returns trigger language plpgsql security definer set search_path = '' as $$
declare t text := (select title from public.missions where id = new.mission_id);
begin
  if new.status <> old.status and new.status = 'verified' then
    perform public.notify(new.user_id, 'run_verified', 'Your ' || t || ' run is verified', new.score || ' points added to the boards.', '/submit.html');
  elsif new.status <> old.status and new.status = 'rejected' then
    perform public.notify(new.user_id, 'run_rejected', 'Your ' || t || ' run was rejected', coalesce(new.reject_reason, ''), '/submit.html');
  end if;
  if new.featured and not old.featured then
    perform public.notify(new.user_id, 'featured', 'Your ' || t || ' run is in Highlights', 'Everyone can watch it now.', '/highlights.html');
  end if;
  return null;
end;
$$;

-- Badges
create or replace function public.notify_badges()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform public.notify(new.user_id, 'badge',
    case new.kind when 'world' then 'You''re the World Champion' when 'continent' then 'You''re Continental Champion of ' || new.label
         else 'You''re City Champion of ' || new.label end,
    to_char(new.month, 'FMMonth YYYY') || ' · it''s on your profile for good.', '/player.html?u=' || public.tag_of(new.user_id));
  return null;
end;
$$;
drop trigger if exists notify_badges on public.badges;
create trigger notify_badges after insert on public.badges for each row execute function public.notify_badges();

-- Crew joins
create or replace function public.notify_crew_join()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.role = 'member' then
    perform public.notify((select owner from public.crews where id = new.crew_id), 'crew_join',
      public.tag_of(new.user_id) || ' joined your crew', '', '/community.html#crews');
  end if;
  return null;
end;
$$;
drop trigger if exists notify_crew_join on public.crew_members;
create trigger notify_crew_join after insert on public.crew_members for each row execute function public.notify_crew_join();

-- Respect
create or replace function public.notify_respect()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform public.notify(new.receiver, 'respect', public.tag_of(new.giver) || ' gave you respect', '', '/player.html?u=' || public.tag_of(new.receiver));
  return null;
end;
$$;
drop trigger if exists notify_respect on public.respects;
create trigger notify_respect after insert on public.respects for each row execute function public.notify_respect();

-- ---------- Highlights ----------
alter table public.submissions add column if not exists featured boolean not null default false;
create index if not exists submissions_featured_idx on public.submissions (featured) where featured;

drop trigger if exists notify_submissions on public.submissions;
create trigger notify_submissions after update on public.submissions for each row execute function public.notify_submissions();

-- Anyone can stream a featured, verified run's video.
do $$ begin
  create policy "featured clips are public" on storage.objects for select to anon, authenticated
    using (bucket_id = 'submissions' and exists (
      select 1 from public.submissions s where s.featured and s.status = 'verified'
        and (s.video_path = name or name = any (s.image_paths))));
exception when duplicate_object then null; end $$;

create table if not exists public.clip_reactions (
  submission_id bigint not null references public.submissions (id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  kind text not null check (kind in ('gg', 'fire', 'crown')),
  created_at timestamptz not null default now(),
  primary key (submission_id, user_id, kind)
);
alter table public.clip_reactions enable row level security;
do $$ begin
  create policy "reactions are public" on public.clip_reactions for select using (true);
  create policy "react to featured clips" on public.clip_reactions for insert to authenticated
    with check (user_id = (select auth.uid()) and exists (
      select 1 from public.submissions s where s.id = submission_id and s.featured and s.status = 'verified'));
  create policy "remove own reaction" on public.clip_reactions for delete to authenticated using (user_id = (select auth.uid()));
exception when duplicate_object then null; end $$;

create or replace function public.highlights(p_limit int default 24)
returns table (id bigint, gamertag text, member boolean, city text, country text, mission text, week_label text,
               score int, video_path text, reviewed_at timestamptz, gg bigint, fire bigint, crown bigint, mine text[])
language sql stable security definer set search_path = '' as $$
  select s.id, p.gamertag, public.is_member(p.id), p.city, p.country, m.title, m.week_label, s.score, s.video_path, s.reviewed_at,
         (select count(*) from public.clip_reactions r where r.submission_id = s.id and r.kind = 'gg'),
         (select count(*) from public.clip_reactions r where r.submission_id = s.id and r.kind = 'fire'),
         (select count(*) from public.clip_reactions r where r.submission_id = s.id and r.kind = 'crown'),
         coalesce((select array_agg(r.kind) from public.clip_reactions r where r.submission_id = s.id and r.user_id = auth.uid()), '{}')
  from public.submissions s
  join public.profiles p on p.id = s.user_id
  join public.missions m on m.id = s.mission_id
  where s.featured and s.status = 'verified'
  order by s.reviewed_at desc
  limit least(greatest(coalesce(p_limit, 24), 1), 60);
$$;

-- ---------- 1v1 Challenges ----------
create table if not exists public.challenges (
  id bigint generated always as identity primary key,
  challenger uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  opponent uuid not null references public.profiles (id) on delete cascade,
  mission_id bigint not null references public.missions (id) on delete cascade,
  message text not null default '' check (char_length(message) <= 140),
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
  created_at timestamptz not null default now(),
  check (challenger <> opponent)
);
create unique index if not exists challenges_unique_open on public.challenges (least(challenger, opponent), greatest(challenger, opponent), mission_id);
alter table public.challenges enable row level security;
do $$ begin
  create policy "see own challenges" on public.challenges for select to authenticated
    using (challenger = (select auth.uid()) or opponent = (select auth.uid()));
  create policy "challenge a friend" on public.challenges for insert to authenticated
    with check (challenger = (select auth.uid()) and status = 'pending'
      and (select public.are_friends(challenger, opponent))
      and exists (select 1 from public.missions m where m.id = mission_id and m.kind = 'weekend' and m.closes_at > now()));
  create policy "respond to challenge" on public.challenges for update to authenticated
    using (opponent = (select auth.uid())) with check (opponent = (select auth.uid()) and status in ('accepted', 'declined'));
  create policy "cancel own challenge" on public.challenges for delete to authenticated using (challenger = (select auth.uid()));
exception when duplicate_object then null; end $$;

create or replace function public.challenges_before_update()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.challenger := old.challenger; new.opponent := old.opponent; new.mission_id := old.mission_id;
  new.message := old.message; new.created_at := old.created_at;
  return new;
end;
$$;
drop trigger if exists challenges_before_update on public.challenges;
create trigger challenges_before_update before update on public.challenges for each row execute function public.challenges_before_update();

create or replace function public.notify_challenges()
returns trigger language plpgsql security definer set search_path = '' as $$
declare t text := (select title from public.missions where id = new.mission_id);
begin
  if tg_op = 'INSERT' then
    perform public.notify(new.opponent, 'challenge', public.tag_of(new.challenger) || ' challenged you on ' || t,
      coalesce(nullif(new.message, ''), 'Beat their score before the mission closes.'), '/community.html#challenges');
  elsif new.status <> old.status then
    perform public.notify(new.challenger, 'challenge_' || new.status,
      public.tag_of(new.opponent) || case when new.status = 'accepted' then ' accepted your challenge on ' else ' declined your challenge on ' end || t,
      '', '/community.html#challenges');
  end if;
  return null;
end;
$$;
drop trigger if exists notify_challenges on public.challenges;
create trigger notify_challenges after insert or update on public.challenges for each row execute function public.notify_challenges();

-- My challenges with live scores and outcome.
create or replace function public.my_challenges()
returns table (id bigint, mission text, week_label text, closes_at timestamptz, status text, message text, i_challenged boolean,
               rival text, rival_member boolean, my_score int, rival_score int, outcome text, created_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select c.id, m.title, m.week_label, m.closes_at, c.status, c.message, c.challenger = auth.uid(),
         r.gamertag, public.is_member(r.id),
         coalesce((select max(s.score) from public.submissions s where s.mission_id = c.mission_id and s.user_id = auth.uid() and s.status = 'verified'), 0),
         coalesce((select max(s.score) from public.submissions s where s.mission_id = c.mission_id and s.user_id = r.id and s.status = 'verified'), 0),
         case
           when c.status = 'declined' then 'declined'
           when c.status = 'pending' and m.closes_at > now() then 'pending'
           when m.closes_at > now() then 'live'
           else 'final'
         end,
         c.created_at
  from public.challenges c
  join public.missions m on m.id = c.mission_id
  join public.profiles r on r.id = case when c.challenger = auth.uid() then c.opponent else c.challenger end
  where auth.uid() is not null and (c.challenger = auth.uid() or c.opponent = auth.uid())
  order by (m.closes_at > now()) desc, c.created_at desc;
$$;
revoke execute on function public.my_challenges() from public, anon;
grant execute on function public.my_challenges() to authenticated;

-- Trigger functions are internal.
revoke execute on function public.notify_friendships() from public, anon, authenticated;
revoke execute on function public.notify_submissions() from public, anon, authenticated;
revoke execute on function public.notify_badges() from public, anon, authenticated;
revoke execute on function public.notify_crew_join() from public, anon, authenticated;
revoke execute on function public.notify_respect() from public, anon, authenticated;
revoke execute on function public.notify_challenges() from public, anon, authenticated;
revoke execute on function public.challenges_before_update() from public, anon, authenticated;

do $$ begin
  alter publication supabase_realtime add table public.notifications;
exception when duplicate_object then null; end $$;
