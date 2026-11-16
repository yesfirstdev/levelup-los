-- Internal lookups remain available to RLS, never as public Data API RPCs.
begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'app_private'), 22, 'all 22 raw lookup helpers moved out of public');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prosecdef and p.proname <> 'get_invite'
    and has_function_privilege('anon', p.oid, 'execute')), 0,
  'anonymous callers cannot execute any privileged public endpoint except invite preview');
select ok(has_function_privilege('anon', 'public.get_invite(text)', 'execute'),
  'invite preview remains anonymous');
select ok(not has_schema_privilege('anon', 'app_private', 'usage'),
  'anonymous callers cannot use the private schema');
select ok(has_schema_privilege('authenticated', 'app_private', 'usage'),
  'authenticated policy evaluation can resolve private helpers');
select ok(has_function_privilege('authenticated', 'app_private.person_workspace(text)', 'execute'),
  'RLS keeps access to its internal helper');
select ok(to_regprocedure('public.person_workspace(text)') is null,
  'raw workspace lookup is not a public RPC');
select ok(to_regprocedure('public.step_card_owner(text,text)') is null,
  'raw ownership lookup is not an authenticated public RPC');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('public','agent_private','app_private') and p.prokind = 'f'
  and p.prosrc ~ '\mpublic\.(can_own_list|chat_eligible|conversation_kind|conversation_workspace|cost_owner|cost_workspace|customer_move_is_latest|dm_other_person|downline_ids|event_workspace|has_paid|is_team_chat|message_author_id|message_conversation_id|person_workspace|pipeline_move_is_latest|workspace_today|step_card_owner|dm_open|board_columns|board_column_ord|booking_kept)\M'),
  0, 'no string-bodied function still refers to a moved public helper');

select * from finish();
rollback;
