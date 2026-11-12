-- ============================================================
-- Migration: let service_role use private helpers (triggers call them)
--            + lookup to recover half-created shadow users
-- ============================================================

-- Triggers on students/groups call private.auth_role(). Edge Functions update
-- those tables as service_role, so it needs access too.
grant usage on schema private to service_role;
grant execute on all functions in schema private to service_role;
alter default privileges in schema private grant execute on functions to service_role;

-- Find an auth user id by email (used to recover a shadow user that was
-- created but not linked because a previous attempt failed halfway)
create or replace function public.get_auth_user_id_by_email(p_email text)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select u.id from auth.users u where u.email = lower(p_email);
$$;

revoke execute on function public.get_auth_user_id_by_email(text) from public, anon, authenticated;
grant execute on function public.get_auth_user_id_by_email(text) to service_role;

