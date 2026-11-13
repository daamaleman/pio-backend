-- ============================================================
-- Migration: trusted adults (student only), help resources (admin), "I want to talk" help requests
-- ============================================================

-- A. New alert origin. Added here, used only from text comparisons and function bodies:
--    Postgres does not allow using a new enum value in the same transaction that creates it.
alter type public.alert_origin add value if not exists 'help_request';

-- B. Trusted adults: kind + optional short name, NO contact data
create type public.trusted_adult_kind as enum
  ('mother', 'father', 'grandparent', 'uncle_aunt', 'sibling', 'teacher', 'guide_teacher', 'counselor', 'other');

create table public.student_trusted_adults (
  id         uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students (id) on delete cascade,
  kind       public.trusted_adult_kind not null,
  label      text check (label is null or (char_length(label) between 1 and 30 and label !~ '[0-9@]')),
  position   smallint not null check (position between 1 and 6),
  unique (student_id, position)
);

alter table public.student_trusted_adults enable row level security;

create policy "own trusted adults" on public.student_trusted_adults
  for select to authenticated using (student_id = private.auth_student_id());

-- Student replaces the whole list (2 to 6 adults), in the order they arranged them
create or replace function public.set_trusted_adults(p_adults jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_student uuid := private.auth_student_id();
  v_count   integer;
begin
  if v_student is null then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  if jsonb_typeof(p_adults) is distinct from 'array' then
    raise exception 'INVALID_INPUT';
  end if;

  v_count := jsonb_array_length(p_adults);
  if v_count < 2 then raise exception 'TOO_FEW_ADULTS'; end if;
  if v_count > 6 then raise exception 'TOO_MANY_ADULTS'; end if;

  if exists (select 1 from jsonb_array_elements(p_adults) e
             where not ((e ->> 'kind') = any (enum_range(null::public.trusted_adult_kind)::text[]))) then
    raise exception 'INVALID_KIND';
  end if;

  -- short names only: 1–30 characters, no digits or @ (no phone numbers or emails)
  if exists (select 1 from jsonb_array_elements(p_adults) e
             where nullif(trim(e ->> 'label'), '') is not null
               and (char_length(trim(e ->> 'label')) > 30 or trim(e ->> 'label') ~ '[0-9@]')) then
    raise exception 'INVALID_LABEL';
  end if;

  delete from public.student_trusted_adults where student_id = v_student;

  insert into public.student_trusted_adults (student_id, kind, label, position)
  select v_student, (e ->> 'kind')::public.trusted_adult_kind, nullif(trim(e ->> 'label'), ''), ord
  from jsonb_array_elements(p_adults) with ordinality as t(e, ord);

  return jsonb_build_object('saved', v_count);
end;
$$;

-- C. Help lines and places, loaded by admin once UNICEF confirms them
create type public.help_resource_kind as enum ('phone_line', 'in_school', 'website');

create table public.help_resources (
  id          uuid primary key default gen_random_uuid(),
  school_id   uuid references public.schools (id) on delete cascade,  -- null = national
  level       public.school_level,                                    -- null = both levels
  kind        public.help_resource_kind not null,
  name        jsonb not null,                                         -- {"es": "...", "en": "...", "miq": "..."}
  description jsonb,
  phone       text,
  url         text,
  hours       jsonb,
  position    smallint not null default 1,
  active      boolean not null default true,
  verified_on date,                                                   -- when UNICEF confirmed it
  created_at  timestamptz not null default now()
);

alter table public.help_resources enable row level security;

-- The school of the signed-in student (from the group in their JWT)
create or replace function private.auth_school_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select g.school_id from public.groups g where g.id = private.auth_group_id();
$$;
grant execute on function private.auth_school_id() to authenticated;

-- Students: national resources + their school's, for their level. Staff: all active ones.
create policy "help resources readable" on public.help_resources
  for select to authenticated
  using (
    active and (
      private.auth_role()::text <> 'student'
      or ((school_id is null or school_id = private.auth_school_id())
          and (level is null or level = private.auth_level()))
    )
  );

create policy "help resources admin" on public.help_resources
  for all to authenticated using (private.is_admin()) with check (private.is_admin());

-- D. "I want to talk with my teacher / counselor"
create or replace function public.request_help(p_wants text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_student  uuid := private.auth_student_id();
  v_group    uuid := private.auth_group_id();
  v_existing record;
begin
  if v_student is null then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  if p_wants is null or p_wants not in ('teacher', 'counselor') then
    raise exception 'INVALID_TARGET';
  end if;

  -- Only one open request at a time: tapping again does not create another
  select a.status, a.details ->> 'wants' as wants, a.opened_at
    into v_existing
  from public.alerts a
  where a.student_id = v_student and a.reason_code = 'help_request' and a.status::text <> 'closed'
  order by a.opened_at desc
  limit 1;

  if found then
    return jsonb_build_object('result', 'already_requested',
      'request', jsonb_build_object('status', v_existing.status, 'wants', v_existing.wants,
                                    'opened_at', v_existing.opened_at));
  end if;

  begin
    insert into public.alerts (student_id, group_id, origin, level, reason_code, details)
    values (v_student, v_group, 'help_request', 'support', 'help_request',
            jsonb_build_object('wants', p_wants));
  exception when unique_violation then
    -- two taps at the same instant: the other one already created it
    return jsonb_build_object('result', 'already_requested');
  end;

  return jsonb_build_object('result', 'created',
    'request', jsonb_build_object('status', 'open', 'wants', p_wants, 'opened_at', now()));
end;
$$;

-- The student sees ONLY the status of their latest help request (last 30 days)
create or replace function public.my_help_request()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('status', a.status, 'wants', a.details ->> 'wants', 'opened_at', a.opened_at)
  from public.alerts a
  where a.student_id = private.auth_student_id()
    and a.reason_code = 'help_request'
    and a.opened_at > now() - interval '30 days'
  order by a.opened_at desc
  limit 1;
$$;

-- E. A request addressed to the counselor is NEVER visible to teachers.
--    RESTRICTIVE: it is ANDed with every existing policy, so the existing ones stay as they are.
create policy "counselor help requests hidden from teachers" on public.alerts
  as restrictive
  for all to authenticated
  using (not (origin::text = 'help_request'
              and details ->> 'wants' = 'counselor'
              and private.auth_role()::text = 'teacher'))
  with check (not (origin::text = 'help_request'
                   and details ->> 'wants' = 'counselor'
                   and private.auth_role()::text = 'teacher'));

revoke execute on function
  public.set_trusted_adults(jsonb), public.request_help(text), public.my_help_request()
from public, anon;
grant execute on function
  public.set_trusted_adults(jsonb), public.request_help(text), public.my_help_request()
to authenticated;