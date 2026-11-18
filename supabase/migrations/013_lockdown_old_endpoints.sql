-- Applied as 016_lockdown_old_endpoints. join_waitlist variable fix (014) is already folded into 012_scale.sql.
revoke execute on function public.leaderboard(text, text, text, text, int) from public, anon, authenticated;
revoke execute on function public.leaderboard_v2(text, text, text, text, int) from public, anon, authenticated;
revoke execute on function public.monthly_board(date, text, int) from public, anon, authenticated;
revoke execute on function public.monthly_board_v2(date, text, int) from public, anon, authenticated;
revoke execute on function public.prize_eligible_for(uuid) from public, anon, authenticated;
revoke execute on function public.residence_allowed(text) from public, anon, authenticated;
create index if not exists submissions_mission_idx on public.submissions (mission_id, status);
create index if not exists blocks_blocked_idx on public.blocks (blocked);
create index if not exists dm_sender_idx on public.dm_messages (sender);
create index if not exists crews_owner_idx on public.crews (owner);
create index if not exists clip_reactions_user_idx on public.clip_reactions (user_id);
create index if not exists chat_reports_reporter_idx on public.chat_reports (reporter);
create index if not exists chat_reports_message_idx on public.chat_reports (message_id);
create index if not exists chat_reports_dm_idx on public.chat_reports (dm_id);
create index if not exists challenges_mission_idx on public.challenges (mission_id);
create index if not exists submissions_reviewed_by_idx on public.submissions (reviewed_by);
create index if not exists world_finalists_user_idx on public.world_finalists (user_id);
