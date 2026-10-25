-- Throwaway-database stubs for tests/router_test.sql (roles, vault, the bits of the proxy schema ai_gate reads).
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role; end if;
end $$;
create schema if not exists vault;
create table if not exists vault.secrets (id uuid primary key default gen_random_uuid(), secret text, name text, description text);
create or replace view vault.decrypted_secrets as select id, secret as decrypted_secret from vault.secrets;
create or replace function vault.create_secret(s text, n text, d text) returns uuid language sql as $$ insert into vault.secrets(secret, name, description) values (s, n, d) returning id $$;
create or replace function vault.update_secret(i uuid, s text) returns void language sql as $$ update vault.secrets set secret = s where id = i $$;
create schema if not exists auth;
create table if not exists auth.users (id uuid primary key, email text);
