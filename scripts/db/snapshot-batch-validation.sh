#!/usr/bin/env bash
set -euo pipefail
name="$1"
container=supabase_db_network-marketing-crm
mkdir -p batch-validation-snapshots
docker exec "$container" pg_dump -U postgres -d postgres --schema-only --schema=public --schema=agent_private --schema=storage | sed -E '/^\\(un)?restrict /d' > "batch-validation-snapshots/$name-schema.sql"
docker exec -i "$container" psql -U postgres -d postgres -X -A -t -v ON_ERROR_STOP=1 > "batch-validation-snapshots/$name-config.json" <<'SQL'
select jsonb_build_object(
 'buckets',(select jsonb_agg(jsonb_build_object('id',id,'name',name,'public',public,'file_size_limit',file_size_limit,'allowed_mime_types',allowed_mime_types) order by id) from storage.buckets),
 'publication',(select jsonb_agg(to_jsonb(t) order by schemaname,tablename) from pg_publication_tables t where pubname='supabase_realtime'),
 'connector_role',(select jsonb_build_object('rolcanlogin',rolcanlogin,'rolinherit',rolinherit,'rolsuper',rolsuper,'rolcreatedb',rolcreatedb,'rolcreaterole',rolcreaterole,'rolbypassrls',rolbypassrls) from pg_roles where rolname='agent_connector'),
 'connector_membership',(select jsonb_agg(parent.rolname order by parent.rolname) from pg_auth_members m join pg_roles child on child.oid=m.member join pg_roles parent on parent.oid=m.roleid where child.rolname='agent_connector'),
 'rls',(select jsonb_agg(jsonb_build_object('table',c.relname,'rls',c.relrowsecurity,'force',c.relforcerowsecurity) order by c.relname) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r')
);
do $$ begin if exists(select 1 from pg_extension where extname='pg_cron') then if exists(select 1 from cron.job) then raise exception 'Unexpected scheduled permanent purge'; end if; end if; end $$;
SQL
