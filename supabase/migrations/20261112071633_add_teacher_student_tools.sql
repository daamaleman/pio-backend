-- ============================================================
-- Migration: teacher tools — reset a student's PIN, create students with PIN (for import), audit log
-- ============================================================

-- PRI-04: who did what to sensitive data, and when. Private schema: never exposed by the API.
create table private.audit_log (
  id           bigint generated always as identity primary key,
  actor_id     uuid,                -- auth user who did it (null = system job)
  actor_role   text,
  action       text not null,       -- 'reset_pin', 'create_student', ...
  target_table text,
  target_id    uuid,
  at           timestamptz not null default now()
);

alter table private.audit_log enable row level security;

-- Random PIN for a level: primary = 4 digits 1–9 (9-drawing grid), secondary = 4 digits 0–9
create or replace function private.generate_pin(p_level public.school_level)
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_digits text := case when p_level = 'primary' then '123456789' else '0123456789' end;
  v_pin    text := '';
begin
  for i in 1..4 loop
    -- cryptographically secure random byte, mapped to one of the allowed digits
    v_pin := v_pin || substr(v_digits, 1 + get_byte(extensions.gen_random_bytes(1), 0) % length(v_digits), 1);
  end loop;
  return v_pin;
end;
$$;

create or replace function private.is_valid_pin(p_pin text, p_level public.school_level)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select case when p_level = 'primary' then coalesce(p_pin ~ '^[1-9]{4}$', false)
              else coalesce(p_pin ~ '^[0-9]{4}$', false) end;
$$;

-- Teacher gives a student a new PIN (given or generated) and unlocks them. Returns the PIN ONCE.
create or replace function public.reset_student_pin(p_student_id uuid, p_new_pin text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_student record;
  v_pin     text;
begin
  if not (private.is_teacher_of_student(p_student_id) or private.is_admin()) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;

  select s.id, s.display_name, g.level
    into v_student
  from public.students s
  join public.groups g on g.id = s.group_id
  where s.id = p_student_id and s.active;

  if not found then
    raise exception 'STUDENT_NOT_FOUND';
  end if;

  v_pin := coalesce(nullif(p_new_pin, ''), private.generate_pin(v_student.level));
  if not private.is_valid_pin(v_pin, v_student.level) then
    raise exception 'INVALID_PIN_FORMAT';
  end if;

  insert into private.student_credentials (student_id, pin_hash)
  values (p_student_id, extensions.crypt(v_pin, extensions.gen_salt('bf', 10)))
  on conflict (student_id) do update
    set pin_hash            = excluded.pin_hash,
        failed_pin_attempts = 0,
        locked_until        = null,
        pin_updated_at      = now();

  insert into private.audit_log (actor_id, actor_role, action, target_table, target_id)
  values ((select auth.uid()), private.auth_role()::text, 'reset_pin', 'students', p_student_id);

  return jsonb_build_object(
    'student_id',   v_student.id,
    'display_name', v_student.display_name,
    'pin',          v_pin);
end;
$$;

revoke execute on function public.reset_student_pin(uuid, text) from public, anon;
grant  execute on function public.reset_student_pin(uuid, text) to authenticated;

-- Creates ONE student + their hashed PIN atomically. Only service_role (import-students Edge Function).
create or replace function public.create_student_with_pin(
  p_group_id     uuid,
  p_display_name text,
  p_pin          text default null,
  p_actor_id     uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_level public.school_level;
  v_name  text := regexp_replace(trim(coalesce(p_display_name, '')), '\s+', ' ', 'g');
  v_pin   text;
  v_id    uuid;
begin
  select g.level into v_level
  from public.groups g
  where g.id = p_group_id and g.active;

  if not found then
    raise exception 'GROUP_NOT_FOUND';
  end if;

  v_pin := coalesce(nullif(p_pin, ''), private.generate_pin(v_level));
  if not private.is_valid_pin(v_pin, v_level) then
    raise exception 'INVALID_PIN_FORMAT';
  end if;

  insert into public.students (group_id, display_name)
  values (p_group_id, v_name)
  returning id into v_id;                       -- duplicate name in the group → 23505

  insert into private.student_credentials (student_id, pin_hash)
  values (v_id, extensions.crypt(v_pin, extensions.gen_salt('bf', 10)));

  insert into private.audit_log (actor_id, actor_role, action, target_table, target_id)
  values (p_actor_id, 'teacher', 'create_student', 'students', v_id);

  return jsonb_build_object('id', v_id, 'display_name', v_name, 'pin', v_pin);
end;
$$;

revoke execute on function public.create_student_with_pin(uuid, text, text, uuid) from public, anon, authenticated;
grant  execute on function public.create_student_with_pin(uuid, text, text, uuid) to service_role;