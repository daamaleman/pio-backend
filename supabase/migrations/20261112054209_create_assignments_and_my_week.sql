-- ============================================================
-- Migration: assignments (DOC-03) + my_week() for the student home (EST-04)
-- ============================================================

create type public.assignment_mode as enum ('home', 'classroom');

create table public.assignments (
  id                uuid primary key default gen_random_uuid(),
  group_id          uuid not null references public.groups (id),
  lesson_id         uuid not null references public.lessons (id),
  assigned_by       uuid not null default auth.uid() references public.profiles (id),
  class_date        date not null,                 -- the class after which it is assigned
  due_date          date not null,                 -- usually the next class
  message           text check (char_length(message) <= 280),
  mode              public.assignment_mode not null default 'home',
  targets_all       boolean not null default true, -- false → see assignment_students
  notify_families   boolean not null default false,
  remind_day_before boolean not null default true,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint assignments_dates check (due_date >= class_date),
  constraint assignments_unique_lesson unique (group_id, lesson_id)
);

create index assignments_lesson_id_idx on public.assignments (lesson_id);

create trigger assignments_set_updated_at
  before update on public.assignments
  for each row execute function private.set_updated_at();

create table public.assignment_students (
  assignment_id uuid not null references public.assignments (id) on delete cascade,
  student_id    uuid not null references public.students (id) on delete cascade,
  created_at    timestamptz not null default now(),
  primary key (assignment_id, student_id)
);

create index assignment_students_student_id_idx on public.assignment_students (student_id);

-- The lesson must match the group's level and grade, be published, and the group must be active
create or replace function private.validate_assignment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_group  record;
  v_lesson record;
begin
  select g.level, g.grade, g.active into v_group  from public.groups  g where g.id = new.group_id;
  select l.level, l.grade, l.status into v_lesson from public.lessons l where l.id = new.lesson_id;

  if v_lesson.level <> v_group.level or v_lesson.grade <> v_group.grade then
    raise exception 'Lesson does not match the group level and grade' using errcode = '23514';
  end if;

  if v_lesson.status <> 'published' then
    raise exception 'Only published lessons can be assigned' using errcode = '23514';
  end if;

  if not v_group.active then
    raise exception 'Group is not active' using errcode = '23514';
  end if;

  return new;
end;
$$;

create trigger assignments_validate
  before insert or update of group_id, lesson_id on public.assignments
  for each row execute function private.validate_assignment();

-- A specific student must belong to the assignment's group
create or replace function private.validate_assignment_student()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1
    from public.assignments a
    join public.students s on s.group_id = a.group_id
    where a.id = new.assignment_id and s.id = new.student_id
  ) then
    raise exception 'Student does not belong to the assignment group' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger assignment_students_validate
  before insert on public.assignment_students
  for each row execute function private.validate_assignment_student();

alter table public.assignments         enable row level security;
alter table public.assignment_students enable row level security;

revoke all on public.assignments, public.assignment_students from anon;

-- Column privileges: assigned_by can never be sent (default auth.uid()); group/lesson immutable after insert
revoke insert, update on public.assignments from authenticated;
grant insert (group_id, lesson_id, class_date, due_date, message, mode,
              targets_all, notify_families, remind_day_before)
  on public.assignments to authenticated;
grant update (class_date, due_date, message, mode, targets_all, notify_families, remind_day_before)
  on public.assignments to authenticated;

revoke update on public.assignment_students from authenticated;   -- only insert/delete

-- Helpers that read the other table WITHOUT RLS → break the policy cycle
-- (assignments ↔ assignment_students)
create or replace function private.is_assignment_target(p_assignment_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.assignment_students ast
    where ast.assignment_id = p_assignment_id
      and ast.student_id = private.auth_student_id()
  );
$$;

create or replace function private.can_manage_assignment(p_assignment_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.assignments a
    where a.id = p_assignment_id
      and private.is_teacher_of_group(a.group_id)
  );
$$;

grant execute on function
  private.is_assignment_target(uuid),
  private.can_manage_assignment(uuid)
to authenticated;

-- ===== assignments =====
-- Teacher: full control over their groups' assignments
create policy assignments_select_teacher on public.assignments
  for select to authenticated
  using (private.is_teacher_of_group(group_id));

create policy assignments_insert_teacher on public.assignments
  for insert to authenticated
  with check (private.is_teacher_of_group(group_id) and assigned_by = (select auth.uid()));

create policy assignments_update_teacher on public.assignments
  for update to authenticated
  using (private.is_teacher_of_group(group_id))
  with check (private.is_teacher_of_group(group_id));

create policy assignments_delete_teacher on public.assignments
  for delete to authenticated
  using (private.is_teacher_of_group(group_id));

-- Student: assignments of their group, for everyone or for them specifically
create policy assignments_select_student on public.assignments
  for select to authenticated
  using (
    group_id = (select private.auth_group_id())
    and (targets_all or private.is_assignment_target(id))
  );

-- Counselor/director: their school (read only)
create policy assignments_select_school_leaders on public.assignments
  for select to authenticated
  using (
    exists (
      select 1 from public.groups g
      where g.id = assignments.group_id
        and private.is_staff_of_school(g.school_id, array['counselor','director']::public.app_role[])
    )
  );

create policy assignments_select_admin on public.assignments
  for select to authenticated
  using ((select private.is_admin()));

-- ===== assignment_students =====
create policy assignment_students_teacher on public.assignment_students
  for all to authenticated
  using (private.can_manage_assignment(assignment_id))
  with check (private.can_manage_assignment(assignment_id));

create policy assignment_students_select_student on public.assignment_students
  for select to authenticated
  using (student_id = (select private.auth_student_id()));

create policy assignment_students_select_admin on public.assignment_students
  for select to authenticated
  using ((select private.is_admin()));

-- ---------- my_week(): everything the student home screen needs, in one call ----------
create or replace function public.my_week()
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  c_tz       constant text := 'America/Managua';
  v_today    date := (now() at time zone c_tz)::date;
  v_student  record;
  v_current  record;
  v_next_class date;
begin
  if private.auth_role() is distinct from 'student' then
    raise exception 'my_week() is only available to students' using errcode = '42501';
  end if;

  -- 1. Who am I (RLS: a student only sees themselves, their group and their teacher)
  select s.id, s.display_name,
         coalesce(s.language, g.language) as language,
         g.id as group_id, g.level, g.grade, g.section, g.class_weekday,
         p.full_name as teacher_name
    into v_student
  from public.students s
  join public.groups g on g.id = s.group_id
  left join public.profiles p on p.id = g.teacher_id
  where s.id = private.auth_student_id();

  if not found then
    raise exception 'Student not found' using errcode = 'P0002';
  end if;

  -- 2. Next class day (today counts if today is class day)
  v_next_class := v_today + ((v_student.class_weekday - extract(isodow from v_today)::int + 7) % 7);

  -- 3. Current assignment = the most recent one I can see (RLS filters the rest)
  select a.id, a.class_date, a.due_date, a.message, a.mode,
         l.slug, l.title, l.week, l.emotion, l.parts_count, l.duration_min
    into v_current
  from public.assignments a
  join public.lessons l on l.id = a.lesson_id
  order by a.class_date desc, a.created_at desc
  limit 1;

  -- 4. Build the answer
  return jsonb_build_object(
    'today', v_today,
    'student', jsonb_build_object(
      'id', v_student.id,
      'display_name', v_student.display_name,
      'language', v_student.language
    ),
    'group', jsonb_build_object(
      'id', v_student.group_id,
      'level', v_student.level,
      'grade', v_student.grade,
      'section', v_student.section,
      'class_weekday', v_student.class_weekday,
      'next_class_date', v_next_class
    ),
    'teacher_name', v_student.teacher_name,
    'current', case when v_current.id is null then null else jsonb_build_object(
      'assignment_id', v_current.id,
      'lesson_slug',   v_current.slug,
      'title',         v_current.title,
      'week',          v_current.week,
      'emotion',       v_current.emotion,
      'duration_min',  v_current.duration_min,
      'class_date',    v_current.class_date,
      'due_date',      v_current.due_date,
      'message',       v_current.message,
      'mode',          v_current.mode,
      -- TODO (step 12): real status per part from progress tables
      'parts', (select jsonb_agg(jsonb_build_object('part', n, 'status', 'not_started') order by n)
                from generate_series(1, v_current.parts_count) as n)
    ) end,
    -- All lessons of my grade: unlocked only if assigned to me
    'lessons', coalesce((
      select jsonb_agg(jsonb_build_object(
               'slug', l.slug,
               'week', l.week,
               'title', l.title,
               'emotion', l.emotion,
               'unlocked', a.id is not null,
               'assignment_id', a.id,
               'due_date', a.due_date
             ) order by l.week)
      from public.lessons l
      left join public.assignments a on a.lesson_id = l.id
      where l.level = v_student.level and l.grade = v_student.grade
    ), '[]'::jsonb)
  );
end;
$$;

revoke execute on function public.my_week() from public, anon;
grant execute on function public.my_week() to authenticated;
