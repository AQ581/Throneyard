-- Throneyard — admin moderation for crews; tighten function access.
do $$ begin
  create policy "admins delete crews" on public.crews for delete to authenticated using ((select public.is_admin()));
  create policy "admins remove crew members" on public.crew_members for delete to authenticated using ((select public.is_admin()));
exception when duplicate_object then null; end $$;

revoke execute on function public.award_monthly_badges(date) from public, anon;
revoke execute on function public.lock_world_finalists(date) from public, anon;
revoke execute on function public.my_friends() from public, anon;
revoke execute on function public.friends_board(date) from public, anon;
grant execute on function public.award_monthly_badges(date) to authenticated;
grant execute on function public.lock_world_finalists(date) to authenticated;
grant execute on function public.my_friends() to authenticated;
grant execute on function public.friends_board(date) to authenticated;
