-- ============================================================
-- Migration: automatic class code generation (e.g. 4B·ANA·27 → '4BANA27')
-- ============================================================

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
  -- 1. Teacher's first name
  select split_part(trim(p.full_name), ' ', 1)
    into v_first_name
  from public.profiles p
  where p.id = p_teacher_id;

  if v_first_name is null then
    raise exception 'Teacher % not found', p_teacher_id using errcode = '23503';
  end if;

  -- 2. Remove accents, keep only A-Z, take 3 letters, pad with X
  v_letters := translate(v_first_name, 'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunAEIOUUN');
  v_letters := regexp_replace(upper(v_letters), '[^A-Z]', '', 'g');
  v_letters := rpad(left(v_letters, 3), 3, 'X');

  -- 3. Try random digit pairs until the code is unique
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

-- If no class_code is provided on insert, generate it
create or replace function private.set_group_class_code()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.class_code is null then
    new.class_code := private.generate_class_code(new.grade, new.section, new.teacher_id);
  end if;
  return new;
end;
$$;

create trigger groups_set_class_code
  before insert on public.groups
  for each row execute function private.set_group_class_code();

