-- ============================================================
-- Migration: staff invitations — profile + school + audit in one transaction
-- Called only by the invite-staff Edge Function (service_role).
-- ============================================================
create or replace function public.create_staff_member(
  p_user_id   uuid,
  p_full_name text,
  p_role      public.app_role,
  p_school_id uuid default null,
  p_actor_id  uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_actor_role text;
begin
  if p_role = 'student' then
    raise exception 'INVALID_ROLE';
  end if;
  if p_role <> 'admin' and p_school_id is null then
    raise exception 'SCHOOL_REQUIRED';
  end if;

  -- Idempotent: a retry after a half-finished invitation completes it
  insert into public.profiles (id, full_name, role)
  values (p_user_id, p_full_name, p_role)
  on conflict (id) do nothing;

  -- Same person, different role → never change a role silently
  if exists (select 1 from public.profiles where id = p_user_id and role <> p_role) then
    raise exception 'ROLE_MISMATCH';
  end if;

  if p_school_id is not null then
    if exists (select 1 from public.staff_schools
               where profile_id = p_user_id and school_id = p_school_id) then
      raise exception 'ALREADY_IN_SCHOOL';
    end if;
    insert into public.staff_schools (profile_id, school_id) values (p_user_id, p_school_id);
  end if;

  select pr.role::text into v_actor_role from public.profiles pr where pr.id = p_actor_id;

  insert into private.audit_log (actor_id, actor_role, action, target_table, target_id)
  values (p_actor_id, v_actor_role, 'invite_staff', 'profiles', p_user_id);

  return jsonb_build_object('user_id', p_user_id, 'role', p_role, 'school_id', p_school_id);
end;
$$;

revoke execute on function public.create_staff_member(uuid, text, public.app_role, uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.create_staff_member(uuid, text, public.app_role, uuid, uuid)
  to service_role;