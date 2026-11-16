-- These are internal RLS/trigger lookups, not client RPCs. Their deliberately
-- unrestricted reads must never be directly reachable through the Data API.
-- Moving the existing functions preserves OIDs and parsed dependencies in
-- policies, views, defaults and triggers. String-bodied functions are updated
-- explicitly below. Do not add app_private to API schemas or extra_search_path.
create schema if not exists app_private;
revoke all on schema app_private from public, anon;
grant usage on schema app_private to authenticated, service_role;

do $migration$
declare
  helpers constant text[] := array[
    'can_own_list',
    'chat_eligible',
    'conversation_kind',
    'conversation_workspace',
    'cost_owner',
    'cost_workspace',
    'customer_move_is_latest',
    'dm_other_person',
    'downline_ids',
    'event_workspace',
    'has_paid',
    'is_team_chat',
    'message_author_id',
    'message_conversation_id',
    'person_workspace',
    'pipeline_move_is_latest',
    'workspace_today',
    'step_card_owner',
    'dm_open',
    'board_columns',
    'board_column_ord',
    'booking_kept'
  ];
  f record;
  helper text;
  definition text;
begin
  for f in
    select p.oid::regprocedure as signature
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = any(helpers)
  loop
    execute format('alter function %s set schema app_private', f.signature);
  end loop;

  -- SQL and PL/pgSQL string bodies do not track references by OID. This is
  -- deliberately limited to application-owned schemas, never extensions.
  for f in
    select p.oid, pg_get_functiondef(p.oid) as definition
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public', 'agent_private', 'app_private')
      and p.prokind = 'f'
  loop
    definition := f.definition;
    foreach helper in array helpers loop
      definition := regexp_replace(definition,
        '\mpublic\.' || helper || '\M', 'app_private.' || helper, 'g');
    end loop;
    if definition <> f.definition then
      execute definition;
    end if;
  end loop;

  -- Deny anonymous invocation of all other definer helpers/RPCs. The one
  -- deliberately public endpoint is token-based invite preview. PUBLIC must
  -- be revoked as well: revoking only anon leaves inherited access intact.
  for f in
    select p.oid::regprocedure as signature
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prosecdef and p.proname <> 'get_invite'
  loop
    execute format('revoke execute on function %s from public, anon', f.signature);
  end loop;
end
$migration$;

revoke execute on all functions in schema app_private from public, anon;
grant execute on all functions in schema app_private to authenticated, service_role;
comment on schema app_private is
  'Internal policy and trigger helpers. Never expose through the Data API or its search path.';
-- A scoped public date RPC preserves existing recurrence clients. Unlike the
-- internal lookup, it returns no timezone-derived value for another team.
create function public.workspace_today(p_workspace_id text)
returns date language sql stable security invoker set search_path = '' as $function$
  select case when auth.uid() is not null
                   and p_workspace_id = public.current_workspace_id()
              then app_private.workspace_today(p_workspace_id)
              else null end
$function$;
revoke execute on function public.workspace_today(text) from public, anon;
grant execute on function public.workspace_today(text) to authenticated, service_role;
notify pgrst, 'reload schema';
