-- ============================================================
-- Migration: content catalog (lessons, minigames, 13-step structure, badges, cards)
-- ============================================================

create type public.content_status as enum ('draft', 'published', 'archived');

-- The 6 emotions of the brand (each drop has a color); used for flowers and check-ins
create type public.emotion as enum ('joy', 'sadness', 'anger', 'fear', 'calm', 'love');

-- Reusable minigame engine templates (spec JUE)
create type public.game_template as enum (
  'catch', 'drag_to_zones', 'classify', 'sequence', 'guided_breathing',
  'branching_story', 'cooperative', 'builder', 'true_myth_trivia',
  'compare_images', 'journal'
);

-- Kinds of steps seen in the 13-step lessons (Figma sections 12 and 13)
create type public.step_kind as enum (
  'story',          -- cuento
  'concept',        -- aprendo / concepto / técnica
  'worked_example', -- ejemplo resuelto
  'minigame',       -- mini-juego del catálogo
  'quiz',           -- ¿qué harías? / mini-quiz
  'poll',           -- encuesta anónima del grupo (secundaria)
  'practice',       -- práctica abierta (escribí tu respuesta)
  'reflection',     -- reflexión personal (no se califica)
  'application',    -- lo uso en mi vida
  'card',           -- mi tarjeta (primaria)
  'plan',           -- tu plan → caja de herramientas (secundaria)
  'home',           -- reto / conversación en casa
  'calm',           -- respiración + flor
  'summary'         -- resumen del capítulo / lección
);

-- ---------- Badges (sellos) ----------
create table public.badges (
  code        text primary key check (code ~ '^[a-z0-9_]+$'),
  level       public.school_level not null,
  name        jsonb not null check (name ? 'es'),
  description jsonb,
  icon_key    text,
  created_at  timestamptz not null default now()
);

-- ---------- Lessons (one per grade and week) ----------
create table public.lessons (
  id               uuid primary key default gen_random_uuid(),
  slug             text not null unique check (slug ~ '^[a-z0-9-]+$'),   -- 'p3-s2'
  level            public.school_level not null,
  grade            smallint not null,
  week             smallint not null check (week between 1 and 4),
  title            jsonb not null check (title ? 'es'),
  emotion          public.emotion,                 -- flower color planted at step 13
  duration_min     smallint check (duration_min between 1 and 60),
  parts_count      smallint not null check (parts_count between 1 and 4),  -- 3 primary, 4 secondary
  is_month_closure boolean not null default false,
  learnings        jsonb,   -- "Hoy aprendiste" bullets, per language
  teacher_guide    jsonb,   -- DOC-12: objective, indicator, reflection tip
  family_note      jsonb,   -- FAM-01: note for parents, per language
  home_challenge   jsonb,   -- reto en casa, per language
  version          integer not null default 1 check (version >= 1),
  status           public.content_status not null default 'draft',
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),

  constraint lessons_grade_matches_level check (
    (level = 'primary'   and grade between 1 and 6) or
    (level = 'secondary' and grade between 1 and 5)
  ),
  constraint lessons_unique_week unique (level, grade, week)
);

create trigger lessons_set_updated_at
  before update on public.lessons
  for each row execute function private.set_updated_at();

-- ---------- Minigames (the 20 of the catalog: 10 per grade) ----------
create table public.minigames (
  id                uuid primary key default gen_random_uuid(),
  slug              text not null unique check (slug ~ '^[a-z0-9-]+$'),  -- 'p3-03-semaforo'
  lesson_id         uuid not null references public.lessons (id) on delete cascade,
  number_in_unit    smallint not null check (number_in_unit between 1 and 10),
  name              jsonb not null check (name ? 'es'),
  template          public.game_template not null,
  plan_content      text not null,     -- contenido del plan (e.g. '2.1 El semáforo de la calma')
  indicator         text not null,     -- indicador de logro
  achievement_rules jsonb not null check (jsonb_typeof(achievement_rules) = 'object'),
  teacher_evidence  text,              -- what the teacher sees as evidence
  duration_min      smallint check (duration_min between 1 and 15),
  badge_code        text references public.badges (code),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint minigames_unique_number unique (lesson_id, number_in_unit),
  constraint minigames_id_lesson_key unique (id, lesson_id)   -- target of the composite FK below
);

create trigger minigames_set_updated_at
  before update on public.minigames
  for each row execute function private.set_updated_at();

-- ---------- Lesson steps (structure of the 13 steps) ----------
create table public.lesson_steps (
  lesson_id    uuid not null references public.lessons (id) on delete cascade,
  position     smallint not null check (position between 1 and 20),
  part         smallint not null check (part between 1 and 4),
  kind         public.step_kind not null,
  minigame_id  uuid,
  is_private   boolean not null default false,  -- teacher sees completion, never the content
  is_skippable boolean not null default false,  -- e.g. reflection can be skipped
  primary key (lesson_id, position),

  -- A minigame step must point to a minigame OF THE SAME LESSON
  constraint lesson_steps_minigame_fk
    foreign key (minigame_id, lesson_id) references public.minigames (id, lesson_id),
  -- minigame_id is required for 'minigame' steps and forbidden otherwise
  constraint lesson_steps_minigame_kind check ((kind = 'minigame') = (minigame_id is not null))
);

-- ---------- Lesson contents (engine JSON per language and version) ----------
create table public.lesson_contents (
  lesson_id          uuid not null references public.lessons (id) on delete cascade,
  language           public.app_language not null,
  version            integer not null check (version >= 1),
  schema_version     text not null,      -- version of the JSON schema used by the engine
  payload            jsonb not null check (jsonb_typeof(payload) = 'object'),
  package_path       text,               -- Storage path of the offline package (json + audio + images)
  package_size_bytes integer check (package_size_bytes between 0 and 5242880),  -- < 5 MB
  created_at         timestamptz not null default now(),
  primary key (lesson_id, language, version)
);

-- ---------- Collectible cards (primary: one per lesson, "Mi tarjeta" step) ----------
create table public.cards (
  code        text primary key check (code ~ '^[a-z0-9_]+$'),
  lesson_id   uuid not null unique references public.lessons (id) on delete cascade,
  name        jsonb not null check (name ? 'es'),
  description jsonb,
  image_key   text,
  created_at  timestamptz not null default now()
);

-- ---------- Helper: current student's level from the JWT ----------
create or replace function private.auth_level()
returns public.school_level
language sql
stable
set search_path = ''
as $$
  select nullif(auth.jwt() ->> 'level', '')::public.school_level;
$$;

grant execute on function private.auth_level() to authenticated;

-- ---------- RLS ----------
alter table public.badges          enable row level security;
alter table public.lessons         enable row level security;
alter table public.minigames       enable row level security;
alter table public.lesson_steps    enable row level security;
alter table public.lesson_contents enable row level security;
alter table public.cards           enable row level security;

revoke all on public.badges, public.lessons, public.minigames,
              public.lesson_steps, public.lesson_contents, public.cards
  from anon;

-- Lessons: staff see published lessons; students only published lessons of THEIR level; admin sees all
create policy lessons_select on public.lessons
  for select to authenticated
  using (
    (select private.is_admin())
    or (
      status = 'published'
      and (
        (select private.auth_role()) in ('teacher', 'counselor', 'director')
        or ((select private.auth_role()) = 'student' and level = (select private.auth_level()))
      )
    )
  );

-- Children inherit visibility from their lesson (the subquery itself goes through lessons RLS)
create policy minigames_select on public.minigames
  for select to authenticated
  using (exists (select 1 from public.lessons l where l.id = minigames.lesson_id));

create policy lesson_steps_select on public.lesson_steps
  for select to authenticated
  using (exists (select 1 from public.lessons l where l.id = lesson_steps.lesson_id));

create policy lesson_contents_select on public.lesson_contents
  for select to authenticated
  using (exists (select 1 from public.lessons l where l.id = lesson_contents.lesson_id));

create policy cards_select on public.cards
  for select to authenticated
  using (exists (select 1 from public.lessons l where l.id = cards.lesson_id));

-- Badges are not sensitive: any logged-in user may read them
create policy badges_select on public.badges
  for select to authenticated
  using (true);

-- Writes: admin only (content editing via portal / content-publish Edge Function)
create policy lessons_admin_write on public.lessons
  for all to authenticated
  using ((select private.is_admin())) with check ((select private.is_admin()));
create policy minigames_admin_write on public.minigames
  for all to authenticated
  using ((select private.is_admin())) with check ((select private.is_admin()));
create policy lesson_steps_admin_write on public.lesson_steps
  for all to authenticated
  using ((select private.is_admin())) with check ((select private.is_admin()));
create policy lesson_contents_admin_write on public.lesson_contents
  for all to authenticated
  using ((select private.is_admin())) with check ((select private.is_admin()));
create policy cards_admin_write on public.cards
  for all to authenticated
  using ((select private.is_admin())) with check ((select private.is_admin()));
create policy badges_admin_write on public.badges
  for all to authenticated
  using ((select private.is_admin())) with check ((select private.is_admin()));

