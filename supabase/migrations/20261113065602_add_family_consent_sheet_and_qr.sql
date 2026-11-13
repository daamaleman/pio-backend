-- ============================================================
-- Migration: families — consent (in app), weekly family sheet (primary, in the child's app),
--            public read-only weekly page by QR (no names)
-- ============================================================
create type public.family_challenge_done as enum ('yes', 'partly', 'no');
create type public.family_how_responded  as enum ('interest', 'difficulty', 'declined');

-- A. Consent: which version was accepted and when. No data about the adult.
create table public.family_consents (
  id              uuid primary key default gen_random_uuid(),
  student_id      uuid not null references public.students (id) on delete cascade,
  consent_version text not null check (consent_version ~ '^[0-9]{4}-[0-9]{2}$'),   -- e.g. 2026-11
  accepted        boolean not null,
  method          text not null default 'in_app_parent_gate',
  recorded_at     timestamptz not null default now(),
  unique (student_id, consent_version)
);

-- B. Weekly family sheet (primary)
create table public.family_sheets (
  id                uuid primary key default gen_random_uuid(),
  student_id        uuid not null references public.students (id) on delete cascade,
  lesson_id         uuid not null references public.lessons (id),
  challenge_done    public.family_challenge_done not null,
  emotion_mentioned public.emotion,
  how_responded     public.family_how_responded not null,
  comment           text check (comment is null or char_length(comment) <= 280),
  submitted_at      timestamptz not null default now(),
  unique (student_id, lesson_id)
);

alter table public.family_consents enable row level security;
alter table public.family_sheets   enable row level security;

-- The student (same phone, family mode) and their teacher read. Writes only through the functions.
create policy "consents: own or teacher" on public.family_consents
  for select to authenticated
  using (student_id = private.auth_student_id() or private.is_teacher_of_student(student_id));

create policy "family sheets: own or teacher" on public.family_sheets
  for select to authenticated
  using (student_id = private.auth_student_id() or private.is_teacher_of_student(student_id));

-- Record the family's answer to the permission screen
create or replace function public.record_family_consent(p_version text, p_accepted boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_student uuid := private.auth_student_id();
begin
  if v_student is null then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  if p_version is null or p_version !~ '^[0-9]{4}-[0-9]{2}$' or p_accepted is null then
    raise exception 'INVALID_INPUT';
  end if;

  insert into public.family_consents (student_id, consent_version, accepted)
  values (v_student, p_version, p_accepted)
  on conflict (student_id, consent_version)
  do update set accepted = excluded.accepted, recorded_at = now();

  return jsonb_build_object('version', p_version, 'accepted', p_accepted);
end;
$$;

-- Submit (or correct) the family sheet of an assigned lesson
create or replace function public.submit_family_sheet(
  p_lesson_slug       text,
  p_challenge_done    public.family_challenge_done,
  p_how_responded     public.family_how_responded,
  p_emotion_mentioned public.emotion default null,
  p_comment           text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_student uuid := private.auth_student_id();
  v_group   uuid := private.auth_group_id();
  v_lesson  uuid;
  v_comment text := nullif(trim(coalesce(p_comment, '')), '');
begin
  if v_student is null then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  if private.auth_level()::text <> 'primary' then
    raise exception 'NOT_FOR_LEVEL';
  end if;
  if v_comment is not null and char_length(v_comment) > 280 then
    raise exception 'COMMENT_TOO_LONG';
  end if;

  select l.id into v_lesson from public.lessons l where l.slug = p_lesson_slug;
  if not found then
    raise exception 'LESSON_NOT_FOUND';
  end if;

  if not exists (
    select 1 from public.assignments a
    where a.group_id = v_group and a.lesson_id = v_lesson
      and (a.targets_all or exists (select 1 from public.assignment_students ast
                                    where ast.assignment_id = a.id and ast.student_id = v_student))
  ) then
    raise exception 'LESSON_LOCKED';
  end if;

  insert into public.family_sheets
    (student_id, lesson_id, challenge_done, emotion_mentioned, how_responded, comment)
  values (v_student, v_lesson, p_challenge_done, p_emotion_mentioned, p_how_responded, v_comment)
  on conflict (student_id, lesson_id) do update set
    challenge_done    = excluded.challenge_done,
    emotion_mentioned = excluded.emotion_mentioned,
    how_responded     = excluded.how_responded,
    comment           = excluded.comment,
    submitted_at      = now();

  return jsonb_build_object('lesson_slug', p_lesson_slug, 'saved', true);
end;
$$;

-- C. Public weekly page by QR: what the group works on this week. NO names, NO personal data.
create or replace function public.family_week(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  c_tz    constant text := 'America/Managua';
  v_today date := (now() at time zone c_tz)::date;
  v_group record;
begin
  select g.id, g.level, g.grade, g.section, g.language, sc.name as school_name
    into v_group
  from public.groups g
  join public.schools sc on sc.id = g.school_id
  where g.family_qr_token::text = p_token and g.active;

  if not found then
    raise exception 'NOT_FOUND';
  end if;

  return jsonb_build_object(
    'group', jsonb_build_object('level', v_group.level, 'grade', v_group.grade,
                                'section', v_group.section, 'language', v_group.language,
                                'school_name', v_group.school_name),
    'this_week', (
      select jsonb_build_object(
               'lesson_slug',    l.slug,
               'title',          l.title,
               'week',           l.week,
               'emotion',        l.emotion,
               'due_date',       a.due_date,
               'home_challenge', l.home_challenge,
               'family_note',    l.family_note)
      from public.assignments a
      join public.lessons l on l.id = a.lesson_id
      where a.group_id = v_group.id and a.targets_all and a.due_date >= v_today
      order by a.class_date desc
      limit 1));
end;
$$;

revoke execute on function
  public.record_family_consent(text, boolean),
  public.submit_family_sheet(text, public.family_challenge_done, public.family_how_responded, public.emotion, text),
  public.family_week(text)
from public, anon;

grant execute on function
  public.record_family_consent(text, boolean),
  public.submit_family_sheet(text, public.family_challenge_done, public.family_how_responded, public.emotion, text)
to authenticated;

-- The QR page has no session: anon may call ONLY this function
grant execute on function public.family_week(text) to anon, authenticated;