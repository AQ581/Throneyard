-- Throneyard — Callouts (competitive posts), rivals, and AI evidence checks.

-- ================= RIVALS =================
alter table public.profiles add column if not exists rival_id uuid references public.profiles (id) on delete set null;
create index if not exists profiles_rival_idx on public.profiles (rival_id);

create or replace function public.set_rival(p_tag text)
returns text language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); r uuid; rtag text;
begin
  if me is null then raise exception 'Sign in first.'; end if;
  if p_tag is null or trim(p_tag) = '' then
    update public.profiles set rival_id = null where id = me;
    return null;
  end if;
  select id, gamertag into r, rtag from public.profiles where lower(gamertag) = lower(trim(p_tag));
  if r is null then raise exception 'No player called %.', trim(p_tag); end if;
  if r = me then raise exception 'You can''t be your own rival.'; end if;
  if public.blocked_between(me, r) then raise exception 'You can''t pick this player.'; end if;
  update public.profiles set rival_id = r where id = me and rival_id is distinct from r;
  if found then
    perform public.notify(r, 'rival', public.tag_of(me) || ' picked you as their rival', 'Show them who runs the board.', '/player.html?u=' || public.tag_of(me));
  end if;
  return rtag;
end;
$$;

-- Head-to-head: a player vs their rival (all-time and this month).
create or replace function public.rival_card(p_tag text)
returns table (player text, rival text, player_total bigint, rival_total bigint, player_month bigint, rival_month bigint,
               player_member boolean, rival_member boolean)
language sql stable security definer set search_path = '' as $$
  with p as (select * from public.profiles where lower(gamertag) = lower(p_tag) limit 1),
       r as (select pr.* from public.profiles pr join p on pr.id = p.rival_id),
       mk as (select to_char(now() at time zone 'America/Toronto', 'YYYY-MM') k)
  select p.gamertag, r.gamertag,
         coalesce((select total_score from public.player_stats where user_id = p.id), 0),
         coalesce((select total_score from public.player_stats where user_id = r.id), 0),
         coalesce((select score from public.player_period_scores, mk where period_type = 'month' and period_key = mk.k and user_id = p.id), 0),
         coalesce((select score from public.player_period_scores, mk where period_type = 'month' and period_key = mk.k and user_id = r.id), 0),
         public.is_member(p.id), public.is_member(r.id)
  from p join r on true;
$$;

-- ================= CALLOUTS (posts) =================
create table if not exists public.posts (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  body text not null check (char_length(trim(body)) between 1 and 280),
  rival_id uuid references public.profiles (id) on delete set null,
  clip_id bigint references public.submissions (id) on delete set null,
  reply_to bigint references public.posts (id) on delete cascade,
  reply_count int not null default 0,
  fire int not null default 0, gg int not null default 0, crown int not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists posts_top_idx on public.posts (id desc) where reply_to is null;
create index if not exists posts_reply_idx on public.posts (reply_to, id);
create index if not exists posts_user_idx on public.posts (user_id, id desc);
create index if not exists posts_rival_idx on public.posts (rival_id, id desc);
create index if not exists posts_user_time_idx on public.posts (user_id, created_at desc);
create index if not exists posts_clip_idx on public.posts (clip_id);
alter table public.posts enable row level security;

create table if not exists public.post_reactions (
  post_id bigint not null references public.posts (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  kind text not null check (kind in ('fire', 'gg', 'crown')),
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);
create index if not exists post_reactions_user_idx on public.post_reactions (user_id);
alter table public.post_reactions enable row level security;

create table if not exists public.post_reports (
  id bigint generated always as identity primary key,
  post_id bigint not null references public.posts (id) on delete cascade,
  reporter uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  reason text not null default '' check (char_length(reason) <= 200),
  resolved boolean not null default false,
  created_at timestamptz not null default now(),
  unique (post_id, reporter)
);
create index if not exists post_reports_open_idx on public.post_reports (created_at desc) where not resolved;
create index if not exists post_reports_reporter_idx on public.post_reports (reporter);
alter table public.post_reports enable row level security;

do $$ begin
  create policy "posts are public" on public.posts for select using (true);
  create policy "delete own post or admin" on public.posts for delete to authenticated
    using (user_id = (select auth.uid()) or (select public.is_admin()));
  create policy "see own reactions" on public.post_reactions for select to authenticated using (user_id = (select auth.uid()));
  create policy "report posts" on public.post_reports for insert to authenticated with check (reporter = (select auth.uid()));
  create policy "admins read post reports" on public.post_reports for select to authenticated using ((select public.is_admin()));
  create policy "admins resolve post reports" on public.post_reports for update to authenticated
    using ((select public.is_admin())) with check ((select public.is_admin()));
exception when duplicate_object then null; end $$;

-- Keep reply counts right when a reply is deleted.
create or replace function public.posts_after_delete()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.reply_to is not null then
    update public.posts set reply_count = greatest(reply_count - 1, 0) where id = old.reply_to;
  end if;
  return null;
end;
$$;
drop trigger if exists posts_after_delete on public.posts;
create trigger posts_after_delete after delete on public.posts for each row execute function public.posts_after_delete();
revoke execute on function public.posts_after_delete() from public, anon, authenticated;

create or replace function public.create_post(p_body text, p_rival text default null, p_clip bigint default null, p_reply_to bigint default null)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  body text := trim(coalesce(p_body, ''));
  r uuid; parent public.posts; new_id bigint; recent int;
begin
  if me is null then raise exception 'Sign in to post.'; end if;
  if not exists (select 1 from public.profiles where id = me) then raise exception 'Set up your player card first.'; end if;
  if char_length(body) < 1 or char_length(body) > 280 then raise exception 'Posts are 1 to 280 characters.'; end if;
  select count(*) into recent from public.posts where user_id = me and created_at > now() - interval '2 minutes';
  if recent >= 5 then raise exception 'Slow down. Too many posts too fast.'; end if;
  perform public.chat_guard(me, body, 0);  -- mute, word filter, no links from brand-new free accounts

  if p_rival is not null and trim(p_rival) <> '' then
    select id into r from public.profiles where lower(gamertag) = lower(trim(both '@' from trim(p_rival)));
    if r is null then raise exception 'No player called %.', trim(p_rival); end if;
    if r = me then raise exception 'You can''t call yourself out.'; end if;
    if public.blocked_between(me, r) then raise exception 'You can''t call out this player.'; end if;
  end if;

  if p_clip is not null and not exists (select 1 from public.submissions where id = p_clip and user_id = me and status = 'verified') then
    raise exception 'You can only attach your own verified runs.';
  end if;

  if p_reply_to is not null then
    select * into parent from public.posts where id = p_reply_to;
    if not found then raise exception 'That post was deleted.'; end if;
    if parent.reply_to is not null then p_reply_to := parent.reply_to; select * into parent from public.posts where id = p_reply_to; end if;
    if public.blocked_between(me, parent.user_id) then raise exception 'You can''t reply to this player.'; end if;
  end if;

  insert into public.posts (user_id, body, rival_id, clip_id, reply_to) values (me, body, r, p_clip, p_reply_to)
  returning id into new_id;

  if p_reply_to is not null then
    update public.posts set reply_count = reply_count + 1 where id = p_reply_to;
    if parent.user_id <> me then
      perform public.notify(parent.user_id, 'reply', public.tag_of(me) || ' replied to your callout', left(body, 120), '/callouts.html#post-' || p_reply_to);
    end if;
  end if;
  if r is not null then
    perform public.notify(r, 'callout', public.tag_of(me) || ' called you out', left(body, 120), '/callouts.html#post-' || coalesce(p_reply_to, new_id));
  end if;
  return new_id;
end;
$$;

create or replace function public.react_post(p_id bigint, p_kind text)
returns text language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); old_kind text; owner uuid;
begin
  if me is null then raise exception 'Sign in to react.'; end if;
  if p_kind is not null and p_kind not in ('fire', 'gg', 'crown') then raise exception 'Unknown reaction.'; end if;
  select user_id into owner from public.posts where id = p_id;
  if owner is null then raise exception 'That post was deleted.'; end if;
  select kind into old_kind from public.post_reactions where post_id = p_id and user_id = me;
  if old_kind is not null then
    delete from public.post_reactions where post_id = p_id and user_id = me;
    update public.posts set fire = fire - (old_kind = 'fire')::int, gg = gg - (old_kind = 'gg')::int, crown = crown - (old_kind = 'crown')::int where id = p_id;
  end if;
  if p_kind is null or p_kind = old_kind then return null; end if;  -- tapping the same reaction removes it
  insert into public.post_reactions (post_id, user_id, kind) values (p_id, me, p_kind);
  update public.posts set fire = fire + (p_kind = 'fire')::int, gg = gg + (p_kind = 'gg')::int, crown = crown + (p_kind = 'crown')::int where id = p_id;
  return p_kind;
end;
$$;

-- One shape for every list of posts.
create or replace function public.post_rows(p_ids bigint[])
returns table (id bigint, body text, created_at timestamptz, author text, member boolean, honor text, city text, country text,
               rival text, clip_id bigint, clip_title text, clip_score int, reply_to bigint, reply_count int,
               fire int, gg int, crown int, my_reaction text, mine boolean)
language sql stable security definer set search_path = '' as $$
  select p.id, p.body, p.created_at, a.gamertag, coalesce(st.member, false),
         case when st.world > 0 then 'world' when st.cont_b > 0 then 'continent' when st.city_b > 0 then 'city' end,
         a.city, a.country, rv.gamertag, p.clip_id, m.title, s.score, p.reply_to, p.reply_count,
         p.fire, p.gg, p.crown,
         (select kind from public.post_reactions pr where pr.post_id = p.id and pr.user_id = auth.uid()),
         p.user_id = auth.uid()
  from unnest(p_ids) with ordinality u(pid, ord)
  join public.posts p on p.id = u.pid
  join public.profiles a on a.id = p.user_id
  left join public.player_stats st on st.user_id = p.user_id
  left join public.profiles rv on rv.id = p.rival_id
  left join public.submissions s on s.id = p.clip_id and s.status = 'verified'
  left join public.missions m on m.id = s.mission_id
  order by u.ord;
$$;
revoke execute on function public.post_rows(bigint[]) from public, anon, authenticated;

-- Feed scopes: all | friends | mentions (callouts aimed at me) | player (by gamertag)
create or replace function public.feed(p_scope text default 'all', p_before bigint default null, p_limit int default 30, p_tag text default null)
returns table (id bigint, body text, created_at timestamptz, author text, member boolean, honor text, city text, country text,
               rival text, clip_id bigint, clip_title text, clip_score int, reply_to bigint, reply_count int,
               fire int, gg int, crown int, my_reaction text, mine boolean)
language plpgsql stable security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  lim int := least(greatest(coalesce(p_limit, 30), 1), 50);
  who uuid; ids bigint[];
begin
  if p_scope = 'player' then select pr.id into who from public.profiles pr where lower(pr.gamertag) = lower(p_tag); end if;
  select array_agg(x.id order by x.id desc) into ids from (
    select p.id from public.posts p
    where p.reply_to is null
      and (p_before is null or p.id < p_before)
      and (me is null or not public.blocked_between(me, p.user_id))
      and case p_scope
            when 'friends' then me is not null and (p.user_id = me or public.are_friends(me, p.user_id))
            when 'mentions' then me is not null and p.rival_id = me
            when 'player' then p.user_id = who
            else true end
    order by p.id desc
    limit lim
  ) x;
  return query select * from public.post_rows(coalesce(ids, '{}'));
end;
$$;

create or replace function public.post_thread(p_id bigint)
returns table (id bigint, body text, created_at timestamptz, author text, member boolean, honor text, city text, country text,
               rival text, clip_id bigint, clip_title text, clip_score int, reply_to bigint, reply_count int,
               fire int, gg int, crown int, my_reaction text, mine boolean)
language plpgsql stable security definer set search_path = '' as $$
declare me uuid := auth.uid(); ids bigint[];
begin
  select array_agg(x.id order by x.reply_to nulls first, x.id) into ids from (
    select p.id, p.reply_to from public.posts p
    where (p.id = p_id or p.reply_to = p_id)
      and (me is null or not public.blocked_between(me, p.user_id))
    order by p.reply_to nulls first, p.id
    limit 300
  ) x;
  return query select * from public.post_rows(coalesce(ids, '{}'));
end;
$$;

create or replace function public.admin_post_reports()
returns table (report_id bigint, post_id bigint, body text, author text, reporter text, reason text, created_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  return query
    select r.id, p.id, p.body, a.gamertag, rp.gamertag, r.reason, r.created_at
    from public.post_reports r join public.posts p on p.id = r.post_id
    join public.profiles a on a.id = p.user_id join public.profiles rp on rp.id = r.reporter
    where not r.resolved order by r.created_at desc limit 100;
end;
$$;

-- ================= AI EVIDENCE CHECK =================
alter table public.submissions add column if not exists ai_status text not null default 'pending';
alter table public.submissions add column if not exists ai_verdict jsonb;
alter table public.submissions add column if not exists ai_checked_at timestamptz;
alter table public.submissions add column if not exists file_hashes text[] not null default '{}';
do $$ begin
  alter table public.submissions add constraint submissions_ai_status_check
    check (ai_status in ('pending', 'clear', 'review', 'flagged', 'error', 'skipped'));
exception when duplicate_object then null; end $$;
create index if not exists submissions_hashes_idx on public.submissions using gin (file_hashes);
create index if not exists submissions_ai_idx on public.submissions (status, ai_status);

-- Same file already submitted (by anyone) → flag it straight away.
create or replace function public.submissions_dup_check()
returns trigger language plpgsql security definer set search_path = '' as $$
declare dup record;
begin
  new.file_hashes := coalesce((select array_agg(distinct h) from unnest(new.file_hashes) h where h ~ '^[0-9a-f]{64}$'), '{}');
  if cardinality(new.file_hashes) > 0 then
    select s.id, s.user_id into dup from public.submissions s
    where s.file_hashes && new.file_hashes and s.id is distinct from new.id
    limit 1;
    if found then
      new.ai_status := 'flagged';
      new.ai_verdict := coalesce(new.ai_verdict, '{}'::jsonb) || jsonb_build_object(
        'duplicate_of', dup.id, 'duplicate_same_player', dup.user_id = new.user_id,
        'summary', 'This exact file was already submitted' || case when dup.user_id = new.user_id then ' by the same player.' else ' by another player.' end);
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists submissions_dup_check on public.submissions;
create trigger submissions_dup_check before insert on public.submissions for each row execute function public.submissions_dup_check();
revoke execute on function public.submissions_dup_check() from public, anon, authenticated;

-- Players can't write AI fields themselves.
create or replace function public.submissions_protect_ai()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if coalesce(current_setting('request.jwt.claims', true)::json ->> 'role', '') in ('anon', 'authenticated') and not public.is_admin() then
    if tg_op = 'INSERT' then
      new.ai_status := 'pending'; new.ai_verdict := null; new.ai_checked_at := null;
    else
      new.ai_status := old.ai_status; new.ai_verdict := old.ai_verdict; new.ai_checked_at := old.ai_checked_at; new.file_hashes := old.file_hashes;
    end if;
  end if;
  return new;
end;
$$;
-- Name starts with "a_" so it runs before the duplicate check (triggers fire in name order).
drop trigger if exists submissions_protect_ai on public.submissions;
drop trigger if exists submissions_a_protect_ai on public.submissions;
create trigger submissions_a_protect_ai before insert or update on public.submissions for each row execute function public.submissions_protect_ai();
revoke execute on function public.submissions_protect_ai() from public, anon, authenticated;
