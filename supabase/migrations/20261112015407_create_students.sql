-- ============================================================
-- Migration: students + private credentials
-- ============================================================

create table public.students (
  id             uuid primary key default gen_random_uuid(),
  group_id       uuid not null references public.groups (id),
  auth_user_id   uuid unique references auth.users (id) on delete set null,
  display_name   text not null check (char_length(trim(display_name)) between 2 and 60),
  language       public.app_language,                 -- null = use the group's language
  avatar_key     text,                                -- illustrated avatar key, NEVER a photo
  accessibility  jsonb not null default '{}'::jsonb
                 check (jsonb_typeof(accessibility) = 'object'),
  active         boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),

  -- The child picks their name from a list: names must be distinguishable in a group
  constraint students_unique_name_in_group unique (group_id, display_name)
);

create trigger students_set_updated_at
  before update on public.students
  for each row execute function private.set_updated_at();

-- ---------- Private credentials: never reachable through the REST API ----------
create table private.student_credentials (
  student_id          uuid primary key references public.students (id) on delete cascade,
  pin_hash            text not null,
  failed_pin_attempts smallint not null default 0 check (failed_pin_attempts >= 0),
  locked_until        timestamptz,
  pin_updated_at      timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create trigger student_credentials_set_updated_at
  before update on private.student_credentials
  for each row execute function private.set_updated_at();

alter table public.students             enable row level security;
alter table private.student_credentials enable row level security;

