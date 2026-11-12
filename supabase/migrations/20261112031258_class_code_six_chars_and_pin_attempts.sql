-- ============================================================
-- Migration: 6-char class codes (design has 6 boxes) + 3 PIN attempts
-- ============================================================

-- Section: exactly one letter (keeps the code at 6 chars)
alter table public.groups drop constraint groups_section_check;
alter table public.groups add constraint groups_section_check check (section ~ '^[A-Z]$');

-- Generator: grade + section + 2 letters + 2 digits (2–9) → e.g. '4BAN27'
create or replace function private.generate_class_code(
  p_grade      smallint,
  p_section    text,
  p_teacher_id uuid
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_first_name text;
  v_letters    text;
  v_code       text;
  v_digits     constant text := '23456789';   -- no 0/1: easy to confuse with O/I
begin
  select split_part(trim(p.full_name), ' ', 1)
    into v_first_name
  from public.profiles p
  where p.id = p_teacher_id;

  if v_first_name is null then
    raise exception 'Teacher % not found', p_teacher_id using errcode = '23503';
  end if;

  v_letters := translate(v_first_name, 'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunAEIOUUN');
  v_letters := regexp_replace(upper(v_letters), '[^A-Z]', '', 'g');
  v_letters := rpad(left(v_letters, 2), 2, 'X');

  for attempt in 1..30 loop
    v_code := p_grade::text
           || upper(p_section)
           || v_letters
           || substr(v_digits, 1 + floor(random() * 8)::int, 1)
           || substr(v_digits, 1 + floor(random() * 8)::int, 1);

    if not exists (select 1 from public.groups g where g.class_code = v_code) then
      return v_code;
    end if;
  end loop;

  raise exception 'Could not generate a unique class code' using errcode = 'P0001';
end;
$$;

-- Existing groups have 7-char codes: regenerate them one by one
alter table public.groups drop constraint groups_class_code_check;

do $$
declare
  r record;
begin
  for r in select id, grade, section, teacher_id from public.groups loop
    update public.groups
    set class_code = private.generate_class_code(r.grade, r.section, r.teacher_id)
    where id = r.id;
  end loop;
end;
$$;

-- New rule: exactly digit + letter + 2 letters + 2 digits (2–9)
alter table public.groups add constraint groups_class_code_check
  check (class_code ~ '^[0-9][A-Z]{3}[2-9]{2}$');

-- PIN: 3 attempts, then 5 minutes wait (teacher can also reset the PIN)
create or replace function public.verify_student_pin(p_group_id uuid, p_student_id uuid, p_pin text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  c_max_attempts constant integer  := 3;
  c_lock         constant interval := interval '5 minutes';
  v_student record;
  v_cred    private.student_credentials%rowtype;
begin
  select s.id, s.auth_user_id, g.level
    into v_student
  from public.students s
  join public.groups g on g.id = s.group_id
  where s.id = p_student_id and s.group_id = p_group_id
    and s.active and g.active;

  if not found then
    return jsonb_build_object('ok', false, 'code', 'STUDENT_NOT_FOUND');
  end if;

  if p_pin is null or p_pin !~ '^[0-9]{4}$' then
    return jsonb_build_object('ok', false, 'code', 'INVALID_PIN_FORMAT');
  end if;

  select * into v_cred
  from private.student_credentials
  where student_id = p_student_id
  for update;

  if not found then
    return jsonb_build_object('ok', false, 'code', 'PIN_NOT_SET');
  end if;

  if v_cred.locked_until is not null and v_cred.locked_until > now() then
    return jsonb_build_object(
      'ok', false, 'code', 'PIN_LOCKED',
      'retry_after_seconds', ceil(extract(epoch from v_cred.locked_until - now()))::integer
    );
  end if;

  if v_cred.pin_hash = extensions.crypt(p_pin, v_cred.pin_hash) then
    update private.student_credentials
    set failed_pin_attempts = 0, locked_until = null
    where student_id = p_student_id;

    return jsonb_build_object(
      'ok', true,
      'student_id',   v_student.id,
      'auth_user_id', v_student.auth_user_id,
      'level',        v_student.level
    );
  end if;

  if v_cred.failed_pin_attempts + 1 >= c_max_attempts then
    update private.student_credentials
    set failed_pin_attempts = 0, locked_until = now() + c_lock
    where student_id = p_student_id;

    return jsonb_build_object(
      'ok', false, 'code', 'PIN_LOCKED',
      'retry_after_seconds', extract(epoch from c_lock)::integer
    );
  end if;

  update private.student_credentials
  set failed_pin_attempts = failed_pin_attempts + 1
  where student_id = p_student_id;

  return jsonb_build_object(
    'ok', false, 'code', 'INVALID_PIN',
    'attempts_left', c_max_attempts - (v_cred.failed_pin_attempts + 1)
  );
end;
$$;

