-- ============================================================
-- Migration: month self-assessment (4 statements x 3 faces), at the start and at the end of the month
-- ============================================================
create type public.assessment_period as enum ('start', 'end');

create table public.self_assessment_items (
  id        uuid primary key default gen_random_uuid(),
  level     public.school_level not null,
  code      text not null check (code ~ '^[a-z0-9_]{1,40}$'),
  position  smallint not null check (position between 1 and 10),
  statement jsonb not null,                 -- {"es": "...", "en": "...", "miq": "..."}
  unique (level, code),
  unique (level, position)
);

create table public.self_assessments (
  id         uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students (id) on delete cascade,
  group_id   uuid not null references public.groups (id) on delete cascade,
  month      date not null check (extract(day from month) = 1),   -- first day of the month
  period     public.assessment_period not null,
  answers    jsonb not null,                                       -- {"item_code": 1..3}
  updated_at timestamptz not null default now(),
  unique (student_id, month, period)
);

alter table public.self_assessment_items enable row level security;
alter table public.self_assessments      enable row level security;

-- Everyone signed in reads the statements; only admin edits them
create policy "self assessment items readable" on public.self_assessment_items
  for select to authenticated using (true);
create policy "self assessment items admin" on public.self_assessment_items
  for all to authenticated using (private.is_admin()) with check (private.is_admin());

-- A student reads only their own answers. Writes go only through the function below.
create policy "own self assessments" on public.self_assessments
  for select to authenticated using (student_id = private.auth_student_id());

-- Statements: primary from the Figma; secondary is a DRAFT for Margie to validate
insert into public.self_assessment_items (level, code, position, statement) values
  ('primary',   'name_emotions',   1, '{"es": "Sé nombrar mis emociones"}'),
  ('primary',   'calm_down',       2, '{"es": "Me sé calmar con el semáforo"}'),
  ('primary',   'treat_well',      3, '{"es": "Trato bien a los demás"}'),
  ('primary',   'ask_for_help',    4, '{"es": "Sé a quién pedir ayuda"}'),
  ('secondary', 'understand_feel', 1, '{"es": "Entiendo lo que siento y por qué"}'),
  ('secondary', 'safe_online',     2, '{"es": "Me cuido en internet y en las redes"}'),
  ('secondary', 'say_no',          3, '{"es": "Sé decir que no sin pelear"}'),
  ('secondary', 'support_network', 4, '{"es": "Sé a quién acudir si necesito apoyo"}')
on conflict (level, code) do update set position = excluded.position, statement = excluded.statement;

-- Student saves the start or end self-assessment of the current month
create or replace function public.submit_self_assessment(p_period public.assessment_period, p_answers jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_student uuid := private.auth_student_id();
  v_group   uuid := private.auth_group_id();
  v_level   public.school_level := private.auth_level();
  v_month   date := date_trunc('month', (now() at time zone 'America/Managua'))::date;
  v_bad     text;
begin
  if v_student is null then
    raise exception 'Not allowed' using errcode = '42501';
  end if;

  if jsonb_typeof(p_answers) is distinct from 'object' then
    raise exception 'INVALID_ANSWERS';
  end if;

  -- Every statement of the level must be answered
  select string_agg(i.code, ', ' order by i.position) into v_bad
  from public.self_assessment_items i
  where i.level = v_level and not (p_answers ? i.code);
  if v_bad is not null then
    raise exception 'MISSING_ITEMS: %', v_bad;
  end if;

  -- No unknown codes, and every value is 1, 2 or 3
  select string_agg(e.key, ', ') into v_bad
  from jsonb_each(p_answers) e
  where not exists (select 1 from public.self_assessment_items i where i.level = v_level and i.code = e.key)
     or jsonb_typeof(e.value) <> 'number'
     or (e.value #>> '{}')::numeric not in (1, 2, 3);
  if v_bad is not null then
    raise exception 'INVALID_ANSWERS: %', v_bad;
  end if;

  insert into public.self_assessments (student_id, group_id, month, period, answers)
  values (v_student, v_group, v_month, p_period, p_answers)
  on conflict (student_id, month, period)
  do update set answers = excluded.answers, group_id = excluded.group_id, updated_at = now();

  return jsonb_build_object('month', v_month, 'period', p_period, 'saved', true);
end;
$$;

-- Group summary for one period: average and distribution per statement, hidden below 3
create or replace function private.self_assessment_period_summary(
  p_group_id uuid, p_month date, p_period public.assessment_period)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with sa as (
    select s.answers
    from public.self_assessments s
    join public.students st on st.id = s.student_id and st.active
    where s.group_id = p_group_id and s.month = p_month and s.period = p_period
  ),
  n as (select count(*)::int as respondents from sa),
  -- step 1: one row per statement with its average and counts
  per_item as (
    select i.code, i.statement, i.position,
           round(avg((sa.answers ->> i.code)::numeric), 2)           as average,
           count(*) filter (where (sa.answers ->> i.code)::int = 1)  as c1,
           count(*) filter (where (sa.answers ->> i.code)::int = 2)  as c2,
           count(*) filter (where (sa.answers ->> i.code)::int = 3)  as c3
    from public.self_assessment_items i
    join public.groups g on g.id = p_group_id and g.level = i.level
    cross join sa
    group by i.code, i.statement, i.position
  )
  -- step 2: put those rows into a JSON array
  select case
    when n.respondents < 3 then jsonb_build_object(
      'hidden', true, 'reason', 'TOO_FEW_RESPONSES', 'min_respondents', 3, 'respondents', n.respondents)
    else jsonb_build_object(
      'hidden', false, 'respondents', n.respondents,
      'items', (select jsonb_agg(jsonb_build_object(
                         'code', p.code,
                         'statement', p.statement,
                         'average', p.average,
                         'distribution', jsonb_build_object('1', p.c1, '2', p.c2, '3', p.c3)
                       ) order by p.position)
                from per_item p))
  end
  from n;
$$;

revoke execute on function private.self_assessment_period_summary(uuid, date, public.assessment_period)
  from public, anon, authenticated;

-- Teacher / school leaders: start vs end of a month, aggregated
create or replace function public.self_assessment_summary(p_group_id uuid, p_month date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_month date := date_trunc('month', coalesce(p_month, (now() at time zone 'America/Managua')::date))::date;
begin
  if not (private.is_teacher_of_group(p_group_id) or private.can_lead_group(p_group_id)) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'month', v_month,
    'start', private.self_assessment_period_summary(p_group_id, v_month, 'start'),
    'end',   private.self_assessment_period_summary(p_group_id, v_month, 'end'));
end;
$$;

revoke execute on function
  public.submit_self_assessment(public.assessment_period, jsonb),
  public.self_assessment_summary(uuid, date)
from public, anon;
grant execute on function
  public.submit_self_assessment(public.assessment_period, jsonb),
  public.self_assessment_summary(uuid, date)
to authenticated;