-- ============================================================
-- Migration: progress (lessons, steps), emotion check-ins, garden, badges, cards
-- Reads: student (own) + teacher (own groups). Writes: ONLY via sync_progress() (next migration).
-- ============================================================

create type public.progress_status   as enum ('in_progress', 'completed');
create type public.step_status       as enum ('in_progress', 'completed', 'skipped');
create type public.indicator_result  as enum ('achieved', 'in_progress', 'needs_support');  -- logrado / en proceso / necesita apoyo
create type public.emotion_intensity as enum ('a_little', 'quite', 'a_lot');                -- un poquito / bastante / muchísimo
create type public.checkin_context   as enum ('daily', 'lesson_start');

-- ---------- Lesson progress (one row per student and lesson) ----------
create table public.lesson_progress (
  student_id        uuid not null references public.students (id) on delete cascade,
  lesson_id         uuid not null references public.lessons (id),
  assignment_id     uuid references public.assignments (id) on delete set null,
  status            public.progress_status not null default 'in_progress',
  current_position  smallint not null default 1 check (current_position between 1 and 20),
  content_version   integer not null default 1 check (content_version >= 1),
  started_at        timestamptz not null default now(),
  completed_at      timestamptz,
  device_updated_at timestamptz,          -- clock of the phone when it last changed (offline)
  updated_at        timestamptz not null default now(),
  primary key (student_id, lesson_id),
  constraint lesson_progress_completed_at check ((status = 'completed') = (completed_at is not null))
);

create index lesson_progress_lesson_id_idx on public.lesson_progress (lesson_id);

create trigger lesson_progress_set_updated_at
  before update on public.lesson_progress
  for each row execute function private.set_updated_at();

-- ---------- Step progress (one row per student, lesson and step) ----------
create table public.step_progress (
  student_id        uuid not null,
  lesson_id         uuid not null,
  position          smallint not null,
  status            public.step_status not null,
  metrics           jsonb not null default '{}'::jsonb check (jsonb_typeof(metrics) = 'object'),  -- numbers only
  indicator_result  public.indicator_result,     -- only for minigame steps, computed by the server
  difficulty        smallint check (difficulty between 1 and 3),   -- LEC-07
  completed_at      timestamptz,
  device_updated_at timestamptz,
  updated_at        timestamptz not null default now(),
  primary key (student_id, lesson_id, position),

  -- the step must exist in the catalog
  constraint step_progress_step_fk
    foreign key (lesson_id, position) references public.lesson_steps (lesson_id, position),
  -- and belongs to the student's lesson progress
  constraint step_progress_lesson_progress_fk
    foreign key (student_id, lesson_id) references public.lesson_progress (student_id, lesson_id)
    on delete cascade,
  constraint step_progress_completed_at check ((status = 'in_progress') = (completed_at is null))
);

create trigger step_progress_set_updated_at
  before update on public.step_progress
  for each row execute function private.set_updated_at();

-- ---------- Emotion check-ins (SENSITIVE: only the student and their teacher) ----------
create table public.emotion_checkins (
  id                 uuid primary key default gen_random_uuid(),
  student_id         uuid not null references public.students (id) on delete cascade,
  checkin_date       date not null,
  context            public.checkin_context not null default 'daily',
  prefers_not_to_say boolean not null default false,
  emotion            public.emotion,
  intensity          public.emotion_intensity,        -- primary: un poquito / bastante / muchísimo
  scale_1_5          smallint check (scale_1_5 between 1 and 5),  -- secondary: "¿cómo llegás hoy?"
  lesson_id          uuid references public.lessons (id),
  created_at         timestamptz not null default now(),

  constraint emotion_checkins_one_per_day unique (student_id, checkin_date, context),
  -- "Prefiero no decirlo hoy" → nothing else is stored. Otherwise an emotion is required.
  constraint emotion_checkins_answer check (
    (prefers_not_to_say and emotion is null and intensity is null and scale_1_5 is null)
    or (not prefers_not_to_say and emotion is not null)
  )
);

-- ---------- Garden: one flower per completed lesson (never wilts, never removed) ----------
create table public.garden_items (
  student_id uuid not null references public.students (id) on delete cascade,
  lesson_id  uuid not null references public.lessons (id),
  emotion    public.emotion not null,          -- color of the flower
  planted_at timestamptz not null default now(),
  primary key (student_id, lesson_id)
);

-- ---------- Badges earned ----------
create table public.student_badges (
  student_id uuid not null references public.students (id) on delete cascade,
  badge_code text not null references public.badges (code),
  earned_at  timestamptz not null default now(),
  primary key (student_id, badge_code)
);

-- ---------- Cards collected (primary) ----------
create table public.student_cards (
  student_id uuid not null references public.students (id) on delete cascade,
  card_code  text not null references public.cards (code),
  earned_at  timestamptz not null default now(),
  primary key (student_id, card_code)
);

-- ---------- Helper: is the current user the teacher of this student? ----------
create or replace function private.is_teacher_of_student(p_student_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(private.auth_role() = 'teacher', false)
     and exists (
       select 1
       from public.students s
       join public.groups g on g.id = s.group_id
       where s.id = p_student_id
         and g.teacher_id = (select auth.uid())
     );
$$;

grant execute on function private.is_teacher_of_student(uuid) to authenticated;

-- ---------- RLS: read-only for the student (own) and their teacher ----------
alter table public.lesson_progress  enable row level security;
alter table public.step_progress    enable row level security;
alter table public.emotion_checkins enable row level security;
alter table public.garden_items     enable row level security;
alter table public.student_badges   enable row level security;
alter table public.student_cards    enable row level security;

-- Nobody writes directly through the API: only sync_progress() (security definer)
revoke all on public.lesson_progress, public.step_progress, public.emotion_checkins,
              public.garden_items, public.student_badges, public.student_cards
  from anon;
revoke insert, update, delete on public.lesson_progress, public.step_progress, public.emotion_checkins,
                                 public.garden_items, public.student_badges, public.student_cards
  from authenticated;

create policy lesson_progress_select on public.lesson_progress
  for select to authenticated
  using (student_id = (select private.auth_student_id()) or private.is_teacher_of_student(student_id));

create policy step_progress_select on public.step_progress
  for select to authenticated
  using (student_id = (select private.auth_student_id()) or private.is_teacher_of_student(student_id));

create policy emotion_checkins_select on public.emotion_checkins
  for select to authenticated
  using (student_id = (select private.auth_student_id()) or private.is_teacher_of_student(student_id));

create policy garden_items_select on public.garden_items
  for select to authenticated
  using (student_id = (select private.auth_student_id()) or private.is_teacher_of_student(student_id));

create policy student_badges_select on public.student_badges
  for select to authenticated
  using (student_id = (select private.auth_student_id()) or private.is_teacher_of_student(student_id));

create policy student_cards_select on public.student_cards
  for select to authenticated
  using (student_id = (select private.auth_student_id()) or private.is_teacher_of_student(student_id));

