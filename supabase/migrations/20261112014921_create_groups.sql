-- ============================================================
-- Migration: groups (classes)
-- ============================================================

create table public.groups (
  id               uuid primary key default gen_random_uuid(),
  school_id        uuid not null references public.schools (id),
  teacher_id       uuid not null references public.profiles (id),
  level            public.school_level not null,
  grade            smallint not null,
  section          text not null check (section ~ '^[A-Z]{1,2}$'),
  class_weekday    smallint not null check (class_weekday between 1 and 7),
  language         public.app_language not null default 'es',
  class_code       text not null unique check (class_code ~ '^[A-Z0-9]{6,10}$'),
  ai_chat_enabled  boolean not null default false,
  family_qr_token  text not null unique default encode(extensions.gen_random_bytes(16), 'hex'),
  school_year      smallint not null check (school_year between 2025 and 2100),
  active           boolean not null default true,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),

  -- Nicaragua: primaria 1.°–6.° grado, secundaria 1.°–5.° año
  constraint groups_grade_matches_level check (
    (level = 'primary'   and grade between 1 and 6) or
    (level = 'secondary' and grade between 1 and 5)
  ),
  -- IA-01: the AI chat can only be enabled for secondary groups
  constraint groups_ai_chat_only_secondary check (
    not ai_chat_enabled or level = 'secondary'
  ),
  -- Avoid creating the same class twice
  constraint groups_unique_class unique (school_id, school_year, level, grade, section)
);

create index groups_teacher_id_idx on public.groups (teacher_id);

create trigger groups_set_updated_at
  before update on public.groups
  for each row execute function private.set_updated_at();

-- ---------- Integrity: teacher_id must be an active teacher of that school ----------
create or replace function private.validate_group_teacher()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.profiles p
    where p.id = new.teacher_id and p.role = 'teacher' and p.active
  ) then
    raise exception 'Profile % is not an active teacher', new.teacher_id
      using errcode = '23514';
  end if;

  if not exists (
    select 1 from public.staff_schools ss
    where ss.profile_id = new.teacher_id and ss.school_id = new.school_id
  ) then
    raise exception 'Teacher % does not belong to school %', new.teacher_id, new.school_id
      using errcode = '23514';
  end if;

  return new;
end;
$$;

create trigger groups_validate_teacher
  before insert or update of teacher_id, school_id on public.groups
  for each row execute function private.validate_group_teacher();

alter table public.groups enable row level security;

