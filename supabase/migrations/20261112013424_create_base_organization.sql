-- ============================================================
-- Migration: base organization (enums, schools, staff profiles)
-- ============================================================

-- Schema for internal functions/tables that must NOT be exposed by the REST API
create schema if not exists private;

-- ---------- Enums ----------
create type public.app_role as enum ('student', 'teacher', 'counselor', 'director', 'admin');
create type public.school_level as enum ('primary', 'secondary');
create type public.app_language as enum ('es', 'en', 'miq');

-- ---------- Helper: keep updated_at current ----------
create or replace function private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- ---------- Schools ----------
create table public.schools (
  id           uuid primary key default gen_random_uuid(),
  name         text not null check (char_length(trim(name)) between 2 and 150),
  department   text not null,          -- departamento o región autónoma de Nicaragua
  municipality text not null,
  region       text check (region in ('pacific', 'central', 'caribbean')),
  active       boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (name, municipality)
);

create trigger schools_set_updated_at
  before update on public.schools
  for each row execute function private.set_updated_at();

-- ---------- Staff profiles (1:1 with auth.users) ----------
create table public.profiles (
  id                 uuid primary key references auth.users (id) on delete cascade,
  role               public.app_role not null check (role <> 'student'),
  full_name          text not null check (char_length(trim(full_name)) between 2 and 120),
  preferred_language public.app_language not null default 'es',
  active             boolean not null default true,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function private.set_updated_at();

-- ---------- Staff <-> schools (a teacher may work in several schools) ----------
create table public.staff_schools (
  profile_id uuid not null references public.profiles (id) on delete cascade,
  school_id  uuid not null references public.schools (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (profile_id, school_id)
);

create index staff_schools_school_id_idx on public.staff_schools (school_id);

-- ---------- Row Level Security: ON for every table (TEC-03) ----------
alter table public.schools       enable row level security;
alter table public.profiles      enable row level security;
alter table public.staff_schools enable row level security;

