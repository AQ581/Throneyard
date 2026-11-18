-- Throneyard — fix: players can react to and watch other players' featured clips.
-- (Policy checks ran under the player's own access, which hides other players' submissions.)
create or replace function public.is_featured_clip(p_id bigint)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.submissions where id = p_id and featured and status = 'verified');
$$;

alter policy "react to featured clips" on public.clip_reactions
  with check (user_id = (select auth.uid()) and (select public.is_featured_clip(submission_id)));

create or replace function public.is_public_clip_path(p_name text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.submissions s
                 where s.featured and s.status = 'verified' and (s.video_path = p_name or p_name = any (s.image_paths)));
$$;

alter policy "featured clips are public" on storage.objects
  using (bucket_id = 'submissions' and (select public.is_public_clip_path(name)));
