-- ============================================================
-- Migration: teacher views — group_climate, assignment_progress, group_overview
-- All run with the CALLER's permissions (RLS applies) + an explicit teacher check.
-- ============================================================

-- DOC-06: aggregated emotions of the week, WITHOUT names. Hidden below a minimum of respondents.
create or replace function public.group_climate(p_group_id uuid, p_week_start date default null)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  c_tz              constant text    := 'America/Managua';
  c_min_respondents constant integer := 3;     -- pending validation (§21.12)
  v_today       date := (now() at time zone c_tz)::date;
  v_start       date;
  v_respondents integer;
  v_total       integer;
  v_declined    integer;
begin
  if not private.is_teacher_of_group(p_group_id) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;

  -- Normalize to the Monday of that week
  v_start := coalesce(p_week_start, v_today);
  v_start := v_start - (extract(isodow from v_start)::int - 1);

  select count(distinct ec.student_id) filter (where not ec.prefers_not_to_say),
         count(*)                      filter (where not ec.prefers_not_to_say),
         count(*)                      filter (where ec.prefers_not_to_say)
    into v_respondents, v_total, v_declined
  from public.emotion_checkins ec
  join public.students s on s.id = ec.student_id
  where s.group_id = p_group_id and s.active
    and ec.context = 'daily'
    and ec.checkin_date between v_start and v_start + 6;

  if v_respondents < c_min_respondents then
    return jsonb_build_object(
      'week_start', v_start,
      'hidden', true,
      'reason', 'TOO_FEW_RESPONSES',
      'min_respondents', c_min_respondents);
  end if;

  return jsonb_build_object(
    'week_start', v_start,
    'hidden', false,
    'checkins', v_total,
    'declined', v_declined,
    -- all 6 emotions, always in the brand order, including zeros
    'distribution', (
      select jsonb_agg(jsonb_build_object(
               'emotion', e.emotion,
               'count', coalesce(c.n, 0),
               'pct', round(100.0 * coalesce(c.n, 0) / v_total)
             ) order by e.ord)
      from unnest(enum_range(null::public.emotion)) with ordinality as e(emotion, ord)
      left join (
        select ec.emotion, count(*) as n
        from public.emotion_checkins ec
        join public.students s on s.id = ec.student_id
        where s.group_id = p_group_id and s.active
          and ec.context = 'daily'
          and not ec.prefers_not_to_say
          and ec.checkin_date between v_start and v_start + 6
        group by ec.emotion
      ) as c on c.emotion = e.emotion
    )
  );
end;
$$;

-- DOC-05: progress of one assignment, per student and per indicator (qualitative scale, no grades)
create or replace function public.assignment_progress(p_assignment_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  c_tz       constant text := 'America/Managua';
  v_today    date := (now() at time zone c_tz)::date;
  v_a        record;
begin
  if not private.can_manage_assignment(p_assignment_id) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;

  select a.id, a.group_id, a.lesson_id, a.class_date, a.due_date, a.targets_all,
         l.slug, l.title, l.week
    into v_a
  from public.assignments a
  join public.lessons l on l.id = a.lesson_id
  where a.id = p_assignment_id;

  return (
    with targeted as (
      -- the students this assignment is for (whole group or specific ones)
      select s.id, s.display_name
      from public.students s
      where s.group_id = v_a.group_id and s.active
        and (v_a.targets_all or exists (
              select 1 from public.assignment_students ast
              where ast.assignment_id = v_a.id and ast.student_id = s.id))
    ),
    progress_rows as (
      select t.id,
             t.display_name,
             coalesce(lp.status::text, 'not_started') as status,
             lp.completed_at,
             lp.current_position,
             (lp.completed_at at time zone c_tz)::date <= v_a.due_date as on_time,
             -- most recent daily check-in of the last 7 days (null if "prefiero no decirlo")
             (select case when ec.prefers_not_to_say then null else ec.emotion end
              from public.emotion_checkins ec
              where ec.student_id = t.id and ec.context = 'daily'
                and ec.checkin_date between v_today - 6 and v_today
              order by ec.checkin_date desc
              limit 1) as latest_emotion,
             -- result per minigame / indicator
             (select coalesce(jsonb_agg(jsonb_build_object(
                        'number', m.number_in_unit,
                        'name', m.name,
                        'indicator', m.indicator,
                        'result', sp.indicator_result
                      ) order by m.number_in_unit), '[]'::jsonb)
              from public.lesson_steps ls
              join public.minigames m on m.id = ls.minigame_id
              left join public.step_progress sp
                on sp.student_id = t.id and sp.lesson_id = ls.lesson_id and sp.position = ls.position
              where ls.lesson_id = v_a.lesson_id) as indicators
      from targeted t
      left join public.lesson_progress lp
        on lp.student_id = t.id and lp.lesson_id = v_a.lesson_id
    )
    select jsonb_build_object(
      'assignment_id', v_a.id,
      'lesson_slug',   v_a.slug,
      'title',         v_a.title,
      'week',          v_a.week,
      'class_date',    v_a.class_date,
      'due_date',      v_a.due_date,
      'summary', jsonb_build_object(
        'students',      count(*),
        'completed',     count(*) filter (where status = 'completed'),
        'in_progress',   count(*) filter (where status = 'in_progress'),
        'not_started',   count(*) filter (where status = 'not_started'),
        'completed_pct', case when count(*) = 0 then 0
                              else round(100.0 * count(*) filter (where status = 'completed') / count(*)) end,
        'badges_earned', (
          select count(*)
          from public.student_badges sb
          join public.minigames m on m.badge_code = sb.badge_code
          where m.lesson_id = v_a.lesson_id
            and sb.student_id in (select id from targeted))
      ),
      'students', coalesce(jsonb_agg(jsonb_build_object(
          'id',               id,
          'display_name',     display_name,
          'status',           status,
          'completed_at',     completed_at,
          'on_time',          on_time,
          'current_position', current_position,
          'latest_emotion',   latest_emotion,
          'indicators',       indicators
        ) order by (status = 'completed') desc, completed_at desc nulls last, display_name), '[]'::jsonb)
    )
    from progress_rows
  );
end;
$$;

-- Teacher home panel: group header, totals, active assignments and this week's climate
create or replace function public.group_overview(p_group_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  c_tz    constant text := 'America/Managua';
  v_today date := (now() at time zone c_tz)::date;
  v_group record;
begin
  if not private.is_teacher_of_group(p_group_id) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;

  select g.id, g.level, g.grade, g.section, g.class_code, g.class_weekday, g.ai_chat_enabled,
         sc.name as school_name
    into v_group
  from public.groups g
  join public.schools sc on sc.id = g.school_id
  where g.id = p_group_id;

  return jsonb_build_object(
    'group', jsonb_build_object(
      'id', v_group.id, 'level', v_group.level, 'grade', v_group.grade, 'section', v_group.section,
      'class_code', v_group.class_code, 'class_weekday', v_group.class_weekday,
      'ai_chat_enabled', v_group.ai_chat_enabled, 'school_name', v_group.school_name),
    'students', (select count(*) from public.students s where s.group_id = p_group_id and s.active),
    'badges_earned', (
      select count(*) from public.student_badges sb
      join public.students s on s.id = sb.student_id
      where s.group_id = p_group_id and s.active),
    'climate', public.group_climate(p_group_id),
    -- "Tareas activas": assignments still in their window (due date not older than a week)
    'assignments', coalesce((
      select jsonb_agg(jsonb_build_object(
               'assignment_id', a.id,
               'lesson_slug',   l.slug,
               'title',         l.title,
               'week',          l.week,
               'due_date',      a.due_date,
               'targets_all',   a.targets_all,
               'targeted',      t.n,
               'completed',     c.n
             ) order by a.class_date desc)
      from public.assignments a
      join public.lessons l on l.id = a.lesson_id
      cross join lateral (
        select count(*) as n from public.students s
        where s.group_id = a.group_id and s.active
          and (a.targets_all or exists (select 1 from public.assignment_students ast
                                        where ast.assignment_id = a.id and ast.student_id = s.id))
      ) as t
      cross join lateral (
        select count(*) as n from public.lesson_progress lp
        join public.students s on s.id = lp.student_id
        where lp.lesson_id = a.lesson_id and lp.status = 'completed'
          and s.group_id = a.group_id and s.active
          and (a.targets_all or exists (select 1 from public.assignment_students ast
                                        where ast.assignment_id = a.id and ast.student_id = s.id))
      ) as c
      where a.group_id = p_group_id
        and a.due_date >= v_today - 7
    ), '[]'::jsonb)
  );
end;
$$;

-- Teachers (and only via these checks) may call them
revoke execute on function
  public.group_climate(uuid, date),
  public.assignment_progress(uuid),
  public.group_overview(uuid)
from public, anon;

grant execute on function
  public.group_climate(uuid, date),
  public.assignment_progress(uuid),
  public.group_overview(uuid)
to authenticated;

