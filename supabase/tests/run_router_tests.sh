#!/usr/bin/env bash
# Router migration tests on a THROWAWAY local database. NEVER point this at the real Supabase project.
# Usage: PGHOST=/tmp PGPORT=5491 PGUSER=postgres supabase/tests/run_router_tests.sh
set -euo pipefail
cd "$(dirname "$0")/.."
DB="${ROUTER_TEST_DB:-router_test}"
PSQL="${PSQL:-psql} -X -q -v ON_ERROR_STOP=1"
$PSQL -d postgres -c "drop database if exists $DB" -c "create database $DB"
$PSQL -d "$DB" -f tests/router_stubs.sql
$PSQL -d "$DB" -f migrations/20261018_cloud_proxy.sql 2>&1 | { grep -v NOTICE || true; }
$PSQL -d "$DB" <<'SQL'
alter table ai_user_daily add column if not exists bg_tokens bigint not null default 0;
-- Live-only column (hand-applied in production, not in any migration; see docs/audit/backend.md issue 4).
alter table ai_routes add column if not exists extra_body jsonb;
create or replace function public.ai_user_cap(p_uid uuid) returns jsonb language sql as $$ select jsonb_build_object('cap', 200000, 'base', 200000) $$;
-- Fixture: providers, models, aliases like production (smart + somali + vision + fast).
insert into ai_providers(name, base_url) values ('Open', 'http://open'), ('Google Gemini', 'http://gemini');
insert into ai_models(provider_id, model_id, vision) select id, 'smart-a', false from ai_providers where name='Open';
insert into ai_models(provider_id, model_id, vision) select id, 'smart-b', false from ai_providers where name='Open';
insert into ai_models(provider_id, model_id, vision) select id, 'open-x', true from ai_providers where name='Open';
insert into ai_models(provider_id, model_id, vision) select id, 'gemini-smart', true from ai_providers where name='Google Gemini';
insert into ai_models(provider_id, model_id, vision) select id, 'gemini-so', true from ai_providers where name='Google Gemini';
insert into ai_models(provider_id, model_id, vision) select id, 'gemini-vis', true from ai_providers where name='Google Gemini';
insert into ai_aliases(alias, max_output_tokens) values ('telesia-smart', 8192), ('telesia-somali', 8192), ('telesia-vision', 4096), ('telesia-fast', 2048);
insert into ai_routes(alias, model_ref, priority) select 'telesia-smart', id, case model_id when 'gemini-smart' then 5 when 'smart-a' then 10 else 20 end from ai_models where model_id in ('smart-a','smart-b','gemini-smart');
insert into ai_routes(alias, model_ref, priority) select 'telesia-somali', id, 10 from ai_models where model_id in ('gemini-so','gemini-smart');
insert into ai_routes(alias, model_ref, priority) select 'telesia-vision', id, 10 from ai_models where model_id in ('gemini-vis','open-x');
insert into ai_routes(alias, model_ref, priority) select 'telesia-fast', id, 10 from ai_models where model_id in ('open-x');
insert into ai_keys(provider_id, label, secret_id) select p.id, 'k', vault.create_secret('sk-'||p.name, 'n', 'd') from ai_providers p;
SQL
$PSQL -d "$DB" -f migrations/20261021_ai_gate.sql
$PSQL -d "$DB" -f migrations/20261023_router_single_model.sql
$PSQL -d "$DB" -f migrations/20261023_router_single_model.sql   # idempotent
$PSQL -d "$DB" -f tests/router_test.sql
