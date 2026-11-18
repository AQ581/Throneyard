-- Throneyard — community chat: rooms, city & crew rooms, friends-only DMs, blocks, reports, mutes, spam limits.

insert into public.settings (key, value) values
  ('chat_rooms', '[{"id":"lounge","name":"General","desc":"Hang out, meet players"},{"id":"missions","name":"Weekend Missions","desc":"Strategy, rules and runs"},{"id":"lfg","name":"Squad Up","desc":"Find people to play with now"},{"id":"city-wars","name":"City Wars","desc":"Rep your city"},{"id":"ps5","name":"PS5","desc":"PlayStation players"},{"id":"xbox","name":"Xbox","desc":"Xbox players"},{"id":"members","name":"Throne Room","desc":"Throne Pass members only","members":true}]'),
  ('chat_blocked_words', '[]'),
  ('chat_rate_limit', '{"messages":5,"seconds":10}')
on conflict (key) do nothing;

-- ---------- Helpers ----------
create or replace function public.city_room(p_country text, p_city text)
returns text language sql immutable set search_path = '' as $$
  select 'city:' || lower(trim(coalesce(p_country, ''))) || '|' || lower(trim(coalesce(p_city, '')));
$$;

create or replace function public.can_read_room(p_room text)
returns boolean language sql stable security definer set search_path = '' as $$
  select case
    when p_room = 'members' then public.is_member(auth.uid()) or public.is_admin()
    when p_room like 'crew:%' then public.is_admin() or exists (
      select 1 from public.crew_members cm
      where cm.user_id = auth.uid() and cm.crew_id::text = substr(p_room, 6))
    when p_room like 'city:%' then true
    else exists (select 1 from public.settings s, jsonb_array_elements(s.value) r
                 where s.key = 'chat_rooms' and r ->> 'id' = p_room)
  end;
$$;

create or replace function public.can_post_room(p_room text)
returns boolean language sql stable security definer set search_path = '' as $$
  select auth.uid() is not null
    and exists (select 1 from public.profiles where id = auth.uid())
    and case
      when p_room like 'city:%' then exists (
        select 1 from public.profiles p where p.id = auth.uid() and public.city_room(p.country, p.city) = p_room)
      else public.can_read_room(p_room)
    end;
$$;

create or replace function public.are_friends(a uuid, b uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.friendships f where f.status = 'accepted'
                 and ((f.requester = a and f.addressee = b) or (f.requester = b and f.addressee = a)));
$$;

-- ---------- Mutes & blocks ----------
create table if not exists public.chat_mutes (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  until timestamptz not null,
  reason text not null default '',
  created_at timestamptz not null default now()
);
alter table public.chat_mutes enable row level security;

create table if not exists public.blocks (
  blocker uuid not null references public.profiles (id) on delete cascade,
  blocked uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker, blocked),
  check (blocker <> blocked)
);
alter table public.blocks enable row level security;

do $$ begin
  create policy "see own mute or admin" on public.chat_mutes for select to authenticated
    using (user_id = (select auth.uid()) or (select public.is_admin()));
  create policy "admins mute" on public.chat_mutes for all to authenticated
    using ((select public.is_admin())) with check ((select public.is_admin()));
  create policy "see own blocks" on public.blocks for select to authenticated using (blocker = (select auth.uid()));
  create policy "block" on public.blocks for insert to authenticated with check (blocker = (select auth.uid()));
  create policy "unblock" on public.blocks for delete to authenticated using (blocker = (select auth.uid()));
exception when duplicate_object then null; end $$;

-- Shared checks for any message: mute, rate limit, word filter, links from new accounts.
create or replace function public.chat_guard(p_user uuid, p_body text, p_recent int)
returns void language plpgsql stable security definer set search_path = '' as $$
declare
  lim jsonb := coalesce((select value from public.settings where key = 'chat_rate_limit'), '{"messages":5,"seconds":10}');
  w text;
  m public.chat_mutes;
begin
  select * into m from public.chat_mutes where user_id = p_user and until > now();
  if found then raise exception 'You are muted until %', to_char(m.until at time zone 'America/Toronto', 'Mon DD HH12:MI AM'); end if;
  if p_recent >= (lim ->> 'messages')::int then raise exception 'Slow down. Too many messages too fast.'; end if;
  for w in select jsonb_array_elements_text(value) from public.settings where key = 'chat_blocked_words' loop
    if w <> '' and p_body ilike '%' || w || '%' then raise exception 'Message blocked by the chat filter'; end if;
  end loop;
  if p_body ~* '(https?://|www\.)'
     and (select created_at from public.profiles where id = p_user) > now() - interval '24 hours'
     and not public.is_member(p_user) then
    raise exception 'New accounts can post links after 24 hours';
  end if;
end;
$$;
revoke execute on function public.chat_guard(uuid, text, int) from public, anon, authenticated;

-- ---------- Room messages ----------
create table if not exists public.chat_messages (
  id bigint generated always as identity primary key,
  room text not null check (char_length(room) between 2 and 140),
  user_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  body text not null check (char_length(trim(body)) between 1 and 500),
  created_at timestamptz not null default now()
);
create index if not exists chat_messages_room_idx on public.chat_messages (room, id desc);
create index if not exists chat_messages_user_idx on public.chat_messages (user_id, created_at desc);
alter table public.chat_messages enable row level security;
do $$ begin
  create policy "read rooms you can see" on public.chat_messages for select using ((select public.can_read_room(room)));
  create policy "post where allowed" on public.chat_messages for insert to authenticated
    with check (user_id = (select auth.uid()) and (select public.can_post_room(room)));
  create policy "delete own or admin" on public.chat_messages for delete to authenticated
    using (user_id = (select auth.uid()) or (select public.is_admin()));
exception when duplicate_object then null; end $$;

create or replace function public.chat_messages_before_insert()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  secs int := coalesce((select (value ->> 'seconds')::int from public.settings where key = 'chat_rate_limit'), 10);
begin
  new.body := trim(new.body);
  new.created_at := now();
  perform public.chat_guard(new.user_id, new.body,
    (select count(*)::int from public.chat_messages where user_id = new.user_id and created_at > now() - make_interval(secs => secs))
    + (select count(*)::int from public.dm_messages where sender = new.user_id and created_at > now() - make_interval(secs => secs)));
  return new;
end;
$$;

-- ---------- Direct messages (friends only) ----------
create table if not exists public.dm_messages (
  id bigint generated always as identity primary key,
  sender uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  recipient uuid not null references public.profiles (id) on delete cascade,
  body text not null check (char_length(trim(body)) between 1 and 1000),
  created_at timestamptz not null default now(),
  read_at timestamptz,
  check (sender <> recipient)
);
create index if not exists dm_pair_idx on public.dm_messages (least(sender, recipient), greatest(sender, recipient), id desc);
create index if not exists dm_unread_idx on public.dm_messages (recipient) where read_at is null;
alter table public.dm_messages enable row level security;
do $$ begin
  create policy "read own dms" on public.dm_messages for select to authenticated
    using (sender = (select auth.uid()) or recipient = (select auth.uid()));
  create policy "send dm to friends" on public.dm_messages for insert to authenticated
    with check (sender = (select auth.uid()) and (select public.are_friends(sender, recipient))
      and not exists (select 1 from public.blocks b where (b.blocker = recipient and b.blocked = sender)
                                                   or (b.blocker = sender and b.blocked = recipient)));
  create policy "mark read" on public.dm_messages for update to authenticated
    using (recipient = (select auth.uid())) with check (recipient = (select auth.uid()));
exception when duplicate_object then null; end $$;

create or replace function public.dm_before_write()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  secs int := coalesce((select (value ->> 'seconds')::int from public.settings where key = 'chat_rate_limit'), 10);
begin
  if tg_op = 'UPDATE' then
    -- only read_at may change
    new.sender := old.sender; new.recipient := old.recipient; new.body := old.body; new.created_at := old.created_at;
    return new;
  end if;
  new.body := trim(new.body);
  new.created_at := now();
  new.read_at := null;
  perform public.chat_guard(new.sender, new.body,
    (select count(*)::int from public.chat_messages where user_id = new.sender and created_at > now() - make_interval(secs => secs))
    + (select count(*)::int from public.dm_messages where sender = new.sender and created_at > now() - make_interval(secs => secs)));
  return new;
end;
$$;

drop trigger if exists chat_messages_before_insert on public.chat_messages;
create trigger chat_messages_before_insert before insert on public.chat_messages
  for each row execute function public.chat_messages_before_insert();
drop trigger if exists dm_before_write on public.dm_messages;
create trigger dm_before_write before insert or update on public.dm_messages
  for each row execute function public.dm_before_write();
revoke execute on function public.chat_messages_before_insert() from public, anon, authenticated;
revoke execute on function public.dm_before_write() from public, anon, authenticated;

-- ---------- Reports ----------
create table if not exists public.chat_reports (
  id bigint generated always as identity primary key,
  reporter uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  message_id bigint references public.chat_messages (id) on delete cascade,
  dm_id bigint references public.dm_messages (id) on delete cascade,
  reason text not null default '' check (char_length(reason) <= 200),
  created_at timestamptz not null default now(),
  check (message_id is not null or dm_id is not null)
);
alter table public.chat_reports enable row level security;
do $$ begin
  create policy "file report" on public.chat_reports for insert to authenticated with check (reporter = (select auth.uid()));
  create policy "admins read reports" on public.chat_reports for select to authenticated using ((select public.is_admin()));
  create policy "admins clear reports" on public.chat_reports for delete to authenticated using ((select public.is_admin()));
exception when duplicate_object then null; end $$;

-- ---------- Read functions ----------
-- Messages with gamertag, member flag and top badge; respects room access.
create or replace function public.room_messages(p_room text, p_before bigint default null, p_limit int default 50)
returns table (id bigint, room text, user_id uuid, gamertag text, member boolean, honor text, body text, created_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select * from (
    select m.id, m.room, m.user_id, p.gamertag, public.is_member(p.id),
           (select b.kind from public.badges b where b.user_id = p.id
            order by case b.kind when 'world' then 0 when 'continent' then 1 else 2 end limit 1),
           m.body, m.created_at
    from public.chat_messages m join public.profiles p on p.id = m.user_id
    where m.room = p_room and public.can_read_room(p_room) and (p_before is null or m.id < p_before)
    order by m.id desc
    limit least(greatest(coalesce(p_limit, 50), 1), 100)
  ) x order by id;
$$;

create or replace function public.chat_message(p_id bigint)
returns table (id bigint, room text, user_id uuid, gamertag text, member boolean, honor text, body text, created_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select m.id, m.room, m.user_id, p.gamertag, public.is_member(p.id),
         (select b.kind from public.badges b where b.user_id = p.id
          order by case b.kind when 'world' then 0 when 'continent' then 1 else 2 end limit 1),
         m.body, m.created_at
  from public.chat_messages m join public.profiles p on p.id = m.user_id
  where m.id = p_id and public.can_read_room(m.room);
$$;

-- Friends list with last message and unread count.
create or replace function public.dm_threads()
returns table (friend_id uuid, gamertag text, member boolean, last_body text, last_at timestamptz, last_from_me boolean, unread bigint)
language sql stable security definer set search_path = '' as $$
  with friends as (
    select case when f.requester = auth.uid() then f.addressee else f.requester end as fid
    from public.friendships f
    where f.status = 'accepted' and (f.requester = auth.uid() or f.addressee = auth.uid())
  )
  select fr.fid, p.gamertag, public.is_member(p.id),
         lm.body, lm.created_at, lm.sender = auth.uid(),
         (select count(*) from public.dm_messages d where d.sender = fr.fid and d.recipient = auth.uid() and d.read_at is null)
  from friends fr
  join public.profiles p on p.id = fr.fid
  left join lateral (
    select d.body, d.created_at, d.sender from public.dm_messages d
    where (d.sender = fr.fid and d.recipient = auth.uid()) or (d.sender = auth.uid() and d.recipient = fr.fid)
    order by d.id desc limit 1
  ) lm on true
  where auth.uid() is not null
  order by lm.created_at desc nulls last, p.gamertag;
$$;

create or replace function public.dm_unread_count()
returns bigint language sql stable security definer set search_path = '' as $$
  select count(*) from public.dm_messages where recipient = auth.uid() and read_at is null;
$$;

-- Admin: open reports with context.
create or replace function public.admin_chat_reports()
returns table (report_id bigint, reported_at timestamptz, reason text, reporter text, offender_id uuid, offender text,
               kind text, item_id bigint, room text, body text, mute_until timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  return query
  select r.id, r.created_at, r.reason, rp.gamertag,
         coalesce(m.user_id, d.sender), op.gamertag,
         case when r.message_id is not null then 'room' else 'dm' end,
         coalesce(r.message_id, r.dm_id), m.room, coalesce(m.body, d.body),
         (select mu.until from public.chat_mutes mu where mu.user_id = coalesce(m.user_id, d.sender) and mu.until > now())
  from public.chat_reports r
  join public.profiles rp on rp.id = r.reporter
  left join public.chat_messages m on m.id = r.message_id
  left join public.dm_messages d on d.id = r.dm_id
  left join public.profiles op on op.id = coalesce(m.user_id, d.sender)
  order by r.created_at desc;
end;
$$;

revoke execute on function public.dm_threads() from public, anon;
revoke execute on function public.dm_unread_count() from public, anon;
revoke execute on function public.admin_chat_reports() from public, anon;
grant execute on function public.dm_threads() to authenticated;
grant execute on function public.dm_unread_count() to authenticated;
grant execute on function public.admin_chat_reports() to authenticated;

-- ---------- Realtime ----------
do $$ begin
  alter publication supabase_realtime add table public.chat_messages;
exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.dm_messages;
exception when duplicate_object then null; end $$;
