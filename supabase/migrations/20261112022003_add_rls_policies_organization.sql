-- ============================================================
-- Migration: RLS policies for schools, profiles, staff_schools, groups, students
-- ============================================================

-- Supabase grants ALL on public tables to anon by default.
-- Nobody without a session reads these tables directly (login lists go through Edge Functions).
revoke all on public.schools, public.profiles, public.staff_schools, public.groups, public.students
  from anon;

-- ========== schools ==========
create policy schools_select_staff on public.schools
  for select to authenticated
  using (
    (select private.is_admin())
    or private.is_staff_of_school(id, array['teacher','counselor','director']::public.app_role[])
  );

create policy schools_insert_admin on public.schools
  for insert to authenticated
  with check ((select private.is_admin()));

create policy schools_update_admin on public.schools
  for update to authenticated
  using ((select private.is_admin()))
  with check ((select private.is_admin()));

-- ========== profiles ==========
-- Writes: staff can only edit their own name and language.
-- Role, active, etc. change only through Edge Functions (service_role).
revoke insert, update, delete on public.profiles from authenticated;
grant update (full_name, preferred_language) on public.profiles to authenticated;

create policy profiles_select_self on public.profiles
  for select to authenticated
  using (id = (select auth.uid()));

create policy profiles_update_self on public.profiles
  for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

create policy profiles_select_admin on public.profiles
  for select to authenticated
  using ((select private.is_admin()));

-- Counselor/director see the staff of their schools
create policy profiles_select_school_leaders on public.profiles
  for select to authenticated
  using (
    exists (
      select 1 from public.staff_schools ss
      where ss.profile_id = profiles.id
        and private.is_staff_of_school(ss.school_id, array['counselor','director']::public.app_role[])
    )
  );

-- A student sees ONLY their group's teacher ("De Prof. Ana", "Prof. Ana verá que terminaste")
create policy profiles_select_own_teacher on public.profiles
  for select to authenticated
  using (
    id = (select g.teacher_id from public.groups g where g.id = (select private.auth_group_id()))
  );

-- ========== staff_schools ==========
-- Writes only through Edge Functions (staff invitation)
revoke insert, update, delete on public.staff_schools from authenticated;

create policy staff_schools_select_self on public.staff_schools
  for select to authenticated
  using (profile_id = (select auth.uid()));

create policy staff_schools_select_school_leaders on public.staff_schools
  for select to authenticated
  using (private.is_staff_of_school(school_id, array['counselor','director']::public.app_role[]));

create policy staff_schools_select_admin on public.staff_schools
  for select to authenticated
  using ((select private.is_admin()));

-- ========== groups ==========
-- Column privileges:
--  * insert: class_code, family_qr_token and ai_chat_enabled can NOT be sent → generated/defaults
--  * update: only these 5 columns; grade, level, teacher, school, codes are immutable via API
--  * delete: never (deactivate with active = false)
revoke insert, update, delete on public.groups from authenticated;
grant insert (school_id, teacher_id, level, grade, section, class_weekday, language, school_year)
  on public.groups to authenticated;
grant update (section, class_weekday, language, ai_chat_enabled, active)
  on public.groups to authenticated;

-- Teacher: own groups
create policy groups_select_teacher on public.groups
  for select to authenticated
  using (teacher_id = (select auth.uid()));

create policy groups_insert_teacher on public.groups
  for insert to authenticated
  with check (
    teacher_id = (select auth.uid())
    and (select private.auth_role()) = 'teacher'
    and private.is_staff_of_school(school_id, array['teacher']::public.app_role[])
  );

create policy groups_update_teacher on public.groups
  for update to authenticated
  using (teacher_id = (select auth.uid()))
  with check (teacher_id = (select auth.uid()));

-- Student: own group only
create policy groups_select_student on public.groups
  for select to authenticated
  using (id = (select private.auth_group_id()));

-- Counselor/director: groups of their school; director may update (AI chat)
create policy groups_select_school_leaders on public.groups
  for select to authenticated
  using (private.is_staff_of_school(school_id, array['counselor','director']::public.app_role[]));

create policy groups_update_director on public.groups
  for update to authenticated
  using (private.is_staff_of_school(school_id, array['director']::public.app_role[]))
  with check (private.is_staff_of_school(school_id, array['director']::public.app_role[]));

-- Admin
create policy groups_select_admin on public.groups
  for select to authenticated using ((select private.is_admin()));
create policy groups_insert_admin on public.groups
  for insert to authenticated with check ((select private.is_admin()));
create policy groups_update_admin on public.groups
  for update to authenticated
  using ((select private.is_admin())) with check ((select private.is_admin()));

-- Only direction/admin may toggle the AI chat (IA-03)
create or replace function private.guard_group_ai_chat()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.ai_chat_enabled is distinct from old.ai_chat_enabled
     and private.auth_role() is not null                       -- null = service_role / SQL editor
     and private.auth_role() not in ('director', 'admin') then
    raise exception 'Only school direction can enable or disable the AI chat'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger groups_guard_ai_chat
  before update of ai_chat_enabled on public.groups
  for each row execute function private.guard_group_ai_chat();

-- ========== students ==========
-- Inserts only via Edge Function (needs shadow auth user + PIN). Never delete via API.
revoke insert, update, delete on public.students from authenticated;
grant update (display_name, language, avatar_key, accessibility, active)
  on public.students to authenticated;

-- Student: themselves
create policy students_select_self on public.students
  for select to authenticated
  using (id = (select private.auth_student_id()));

create policy students_update_self on public.students
  for update to authenticated
  using (id = (select private.auth_student_id()))
  with check (id = (select private.auth_student_id()));

-- Teacher: students of their groups
create policy students_select_teacher on public.students
  for select to authenticated
  using (private.is_teacher_of_group(group_id));

create policy students_update_teacher on public.students
  for update to authenticated
  using (private.is_teacher_of_group(group_id))
  with check (private.is_teacher_of_group(group_id));

-- Counselor/director: students of their school
create policy students_select_school_leaders on public.students
  for select to authenticated
  using (
    exists (
      select 1 from public.groups g
      where g.id = students.group_id
        and private.is_staff_of_school(g.school_id, array['counselor','director']::public.app_role[])
    )
  );

-- Admin
create policy students_select_admin on public.students
  for select to authenticated
  using ((select private.is_admin()));

-- A student may change only their preferences (language, avatar, accessibility)
create or replace function private.guard_student_self_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if private.auth_role() = 'student'
     and (new.display_name is distinct from old.display_name
          or new.active is distinct from old.active) then
    raise exception 'Students can only update their own preferences'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger students_guard_self_update
  before update on public.students
  for each row execute function private.guard_student_self_update();

