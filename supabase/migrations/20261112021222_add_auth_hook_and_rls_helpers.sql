-- ============================================================
-- Migration: custom access token hook + RLS helper functions
-- ============================================================

create or replace function public.custom_access_token_hook(event jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_user_id uuid  := (event ->> 'user_id')::uuid;
  v_claims  jsonb := coalesce(event -> 'claims', '{}'::jsonb);
  v_role    public.app_role;
  v_student record;
begin
  -- 1. Never trust previous values: remove our custom claims first
  v_claims := v_claims - 'app_role' - 'student_id' - 'group_id' - 'level';

  -- 2. Staff? (only active profiles)
  select p.role into v_role
  from public.profiles p
  where p.id = v_user_id and p.active;

  if v_role is not null then
    v_claims := v_claims || jsonb_build_object('app_role', v_role);

  else
    -- 3. Student? (active student in an active group)
    select s.id, s.group_id, g.level
      into v_student
    from public.students s
    join public.groups g on g.id = s.group_id
    where s.auth_user_id = v_user_id and s.active and g.active;

    if found then
      v_claims := v_claims || jsonb_build_object(
        'app_role',   'student',
        'student_id', v_student.id,
        'group_id',   v_student.group_id,
        'level',      v_student.level
      );
    end if;
  end if;

  -- 4. Return the event with the new claims
  return jsonb_set(event, '{claims}', v_claims);
end;
$$;

-- ---------- Grants for Supabase Auth (runs the hook as supabase_auth_admin) ----------
grant usage on schema public to supabase_auth_admin;

grant execute on function public.custom_access_token_hook(jsonb) to supabase_auth_admin;
revoke execute on function public.custom_access_token_hook(jsonb) from authenticated, anon, public;

-- The hook reads these 3 tables: allow ONLY supabase_auth_admin
grant select on public.profiles, public.students, public.groups to supabase_auth_admin;

create policy "auth_admin_reads_profiles" on public.profiles
  for select to supabase_auth_admin using (true);

create policy "auth_admin_reads_students" on public.students
  for select to supabase_auth_admin using (true);

create policy "auth_admin_reads_groups" on public.groups
  for select to supabase_auth_admin using (true);

-- ---------- RLS helpers (private schema: not exposed by the REST API) ----------

-- Current user's role from the JWT
create or replace function private.auth_role()
returns public.app_role
language sql
stable
set search_path = ''
as $$
  select nullif(auth.jwt() ->> 'app_role', '')::public.app_role;
$$;

-- Current student's id (null if not a student)
create or replace function private.auth_student_id()
returns uuid
language sql
stable
set search_path = ''
as $$
  select nullif(auth.jwt() ->> 'student_id', '')::uuid;
$$;

-- Current student's group (null if not a student)
create or replace function private.auth_group_id()
returns uuid
language sql
stable
set search_path = ''
as $$
  select nullif(auth.jwt() ->> 'group_id', '')::uuid;
$$;

-- Is the current user an admin?
create or replace function private.is_admin()
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce(private.auth_role() = 'admin', false);
$$;

-- Is the current user the teacher of this group?
create or replace function private.is_teacher_of_group(p_group_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(private.auth_role() = 'teacher', false)
     and exists (
       select 1 from public.groups g
       where g.id = p_group_id
         and g.teacher_id = (select auth.uid())
     );
$$;

-- Does the current user work at this school with one of these roles?
create or replace function private.is_staff_of_school(p_school_id uuid, p_roles public.app_role[])
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(private.auth_role() = any (p_roles), false)
     and exists (
       select 1 from public.staff_schools ss
       where ss.school_id = p_school_id
         and ss.profile_id = (select auth.uid())
     );
$$;

-- ---------- Lock down the private schema ----------
-- By default Postgres lets PUBLIC execute any function: undo that
revoke execute on all functions in schema private from public;
alter default privileges in schema private revoke execute on functions from public;

-- Logged-in users need ONLY these helpers (called from RLS policies)
grant usage on schema private to authenticated;
grant execute on function
  private.auth_role(),
  private.auth_student_id(),
  private.auth_group_id(),
  private.is_admin(),
  private.is_teacher_of_group(uuid),
  private.is_staff_of_school(uuid, public.app_role[])
to authenticated;

