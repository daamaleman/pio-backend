-- ============================================================
-- Migration: sync_progress() (only write path for progress) + my_week() v2 with real progress
-- ============================================================

-- Rank of a step status: higher = more progress ("gana el avance mayor")
create or replace function private.step_status_rank(p public.step_status)
returns smallint
language sql
immutable
set search_path = ''
as $$
  select (case p when 'in_progress' then 1 when 'skipped' then 2 when 'completed' then 3 else 0 end)::smallint;
$$;

-- Rank of an indicator result: higher = better result (null = 0)
create or replace function private.indicator_rank(p public.indicator_result)
returns smallint
language sql
immutable
set search_path = ''
as $$
  select (case p when 'needs_support' then 1 when 'in_progress' then 2 when 'achieved' then 3 else 0 end)::smallint;
$$;

-- Evaluate a minigame result on the SERVER from its achievement_rules
-- rules: {"metric": "correct", "total": 8, "achieved_min": 6, "in_progress_min": 4}
create or replace function private.evaluate_indicator(p_rules jsonb, p_metrics jsonb)
returns public.indicator_result
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_value numeric;
begin
  v_value := (p_metrics ->> (p_rules ->> 'metric'))::numeric;
  if v_value is null then
    return null;                      -- the app did not send the metric: no result (never invent one)
  end if;
  if v_value >= (p_rules ->> 'achieved_min')::numeric then
    return 'achieved';
  elsif v_value >= (p_rules ->> 'in_progress_min')::numeric then
    return 'in_progress';
  end if;
  return 'needs_support';
end;
$$;

create or replace function public.sync_progress(p_payload jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  c_tz           constant text    := 'America/Managua';
  c_max_checkins constant integer := 60;
  c_max_lessons  constant integer := 10;
  c_max_steps    constant integer := 30;

  v_today        date := (now() at time zone c_tz)::date;
  v_student_id   uuid := private.auth_student_id();
  v_group        record;
  v_lesson       record;
  v_step         record;
  v_item         jsonb;
  v_lesson_item  jsonb;
  v_step_item    jsonb;
  v_assignment_id uuid;
  v_status       public.step_status;
  v_metrics      jsonb;
  v_indicator    public.indicator_result;
  v_device_ts    timestamptz;
  v_date         date;
  v_card_code    text;

  v_ok_checkins  integer := 0;
  v_ok_steps     integer := 0;
  v_rejected     jsonb := '[]'::jsonb;
  v_new_flowers  jsonb := '[]'::jsonb;
  v_new_badges   jsonb := '[]'::jsonb;
  v_new_cards    jsonb := '[]'::jsonb;
  v_touched      uuid[] := '{}';
begin
  -- ===== 1. Who is calling (from the JWT, never from the payload) =====
  if private.auth_role() is distinct from 'student' or v_student_id is null then
    raise exception 'sync_progress() is only available to students' using errcode = '42501';
  end if;

  select g.id, g.level, g.grade into v_group
  from public.students s
  join public.groups g on g.id = s.group_id
  where s.id = v_student_id and s.active and g.active;

  if not found then
    raise exception 'Student or group is not active' using errcode = '42501';
  end if;

  -- ===== 2. Payload shape and size limits =====
  p_payload := coalesce(p_payload, '{}'::jsonb);
  if jsonb_typeof(p_payload) <> 'object'
     or jsonb_array_length(coalesce(p_payload -> 'checkins', '[]'::jsonb)) > c_max_checkins
     or jsonb_array_length(coalesce(p_payload -> 'lessons',  '[]'::jsonb)) > c_max_lessons then
    raise exception 'Invalid or too large payload' using errcode = '22023';
  end if;

  -- ===== 3. Emotion check-ins (latest answer for the day wins: the child may change their mind) =====
  for v_item in select value from jsonb_array_elements(coalesce(p_payload -> 'checkins', '[]'::jsonb)) loop
    begin
      v_date := (v_item ->> 'date')::date;
      if v_date is null or v_date < v_today - 7 or v_date > v_today + 1 then
        raise exception 'DATE_OUT_OF_RANGE';
      end if;

      insert into public.emotion_checkins
        (student_id, checkin_date, context, prefers_not_to_say, emotion, intensity, scale_1_5, lesson_id)
      values (
        v_student_id,
        v_date,
        coalesce(v_item ->> 'context', 'daily')::public.checkin_context,
        coalesce((v_item ->> 'prefers_not_to_say')::boolean, false),
        (v_item ->> 'emotion')::public.emotion,
        (v_item ->> 'intensity')::public.emotion_intensity,
        (v_item ->> 'scale_1_5')::smallint,
        (select l.id from public.lessons l where l.slug = v_item ->> 'lesson_slug')
      )
      on conflict (student_id, checkin_date, context) do update
        set prefers_not_to_say = excluded.prefers_not_to_say,
            emotion            = excluded.emotion,
            intensity          = excluded.intensity,
            scale_1_5          = excluded.scale_1_5,
            lesson_id          = excluded.lesson_id;

      v_ok_checkins := v_ok_checkins + 1;
    exception when others then
      v_rejected := v_rejected || jsonb_build_object(
        'type', 'checkin', 'ref', v_item ->> 'date',
        'code', case when sqlstate = 'P0001' then sqlerrm else sqlstate end);
    end;
  end loop;

  -- ===== 4. Lessons and their steps =====
  for v_lesson_item in select value from jsonb_array_elements(coalesce(p_payload -> 'lessons', '[]'::jsonb)) loop
    begin
      -- 4.1 The lesson must be published and match my group's level and grade
      select l.id, l.slug, l.emotion into v_lesson
      from public.lessons l
      where l.slug = v_lesson_item ->> 'lesson_slug'
        and l.status = 'published'
        and l.level = v_group.level and l.grade = v_group.grade;

      if not found then
        raise exception 'LESSON_NOT_FOUND';
      end if;

      -- 4.2 ...and be assigned to me (unlocked)
      select a.id into v_assignment_id
      from public.assignments a
      where a.group_id = v_group.id
        and a.lesson_id = v_lesson.id
        and (a.targets_all or exists (
              select 1 from public.assignment_students ast
              where ast.assignment_id = a.id and ast.student_id = v_student_id));

      if v_assignment_id is null then
        raise exception 'LESSON_LOCKED';
      end if;

      if jsonb_array_length(coalesce(v_lesson_item -> 'steps', '[]'::jsonb)) > c_max_steps then
        raise exception 'TOO_MANY_STEPS';
      end if;

      -- 4.3 Lesson progress: furthest position wins
      v_device_ts := least(coalesce((v_lesson_item ->> 'device_updated_at')::timestamptz, now()), now());

      insert into public.lesson_progress as lp
        (student_id, lesson_id, assignment_id, current_position, content_version, started_at, device_updated_at)
      values (
        v_student_id, v_lesson.id, v_assignment_id,
        greatest(coalesce((v_lesson_item ->> 'current_position')::smallint, 1), 1),
        coalesce((v_lesson_item ->> 'content_version')::integer, 1),
        v_device_ts, v_device_ts
      )
      on conflict (student_id, lesson_id) do update
        set current_position  = greatest(lp.current_position, excluded.current_position),
            device_updated_at = greatest(lp.device_updated_at, excluded.device_updated_at),
            assignment_id     = coalesce(lp.assignment_id, excluded.assignment_id);

      -- 4.4 Each step in its own sub-transaction
      for v_step_item in select value from jsonb_array_elements(coalesce(v_lesson_item -> 'steps', '[]'::jsonb)) loop
        begin
          select s.position, s.kind, s.is_skippable, m.achievement_rules, m.badge_code
            into v_step
          from public.lesson_steps s
          left join public.minigames m on m.id = s.minigame_id
          where s.lesson_id = v_lesson.id
            and s.position = (v_step_item ->> 'position')::smallint;

          if not found then
            raise exception 'STEP_NOT_FOUND';
          end if;

          v_status := (v_step_item ->> 'status')::public.step_status;
          if v_status = 'skipped' and not v_step.is_skippable then
            raise exception 'STEP_NOT_SKIPPABLE';
          end if;

          -- Keep ONLY numeric metrics (never personal text)
          select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into v_metrics
          from jsonb_each(
            case when jsonb_typeof(v_step_item -> 'metrics') = 'object'
                 then v_step_item -> 'metrics' else '{}'::jsonb end)
          where jsonb_typeof(value) = 'number';

          -- Indicator computed by the server, only for completed minigames
          v_indicator := case
            when v_step.kind = 'minigame' and v_status = 'completed'
              then private.evaluate_indicator(v_step.achievement_rules, v_metrics)
          end;

          v_device_ts := least(coalesce((v_step_item ->> 'device_updated_at')::timestamptz, now()), now());

          insert into public.step_progress as sp
            (student_id, lesson_id, position, status, metrics, indicator_result, difficulty,
             completed_at, device_updated_at)
          values (
            v_student_id, v_lesson.id, v_step.position, v_status, v_metrics, v_indicator,
            (v_step_item ->> 'difficulty')::smallint,
            case when v_status = 'in_progress' then null else v_device_ts end,
            v_device_ts
          )
          on conflict (student_id, lesson_id, position) do update
            set status = case
                  when private.step_status_rank(excluded.status) > private.step_status_rank(sp.status)
                  then excluded.status else sp.status end,
                completed_at = coalesce(sp.completed_at, excluded.completed_at),
                indicator_result = case
                  when private.indicator_rank(excluded.indicator_result) > private.indicator_rank(sp.indicator_result)
                  then excluded.indicator_result else sp.indicator_result end,
                metrics = case
                  when private.indicator_rank(excluded.indicator_result) > private.indicator_rank(sp.indicator_result)
                  then excluded.metrics else sp.metrics end,
                difficulty = coalesce(excluded.difficulty, sp.difficulty),
                device_updated_at = greatest(sp.device_updated_at, excluded.device_updated_at);

          -- Badge: for COMPLETING the minigame (not for speed or a perfect score)
          if v_status = 'completed' and v_step.badge_code is not null then
            insert into public.student_badges (student_id, badge_code)
            values (v_student_id, v_step.badge_code)
            on conflict do nothing;
            if found then
              v_new_badges := v_new_badges || to_jsonb(v_step.badge_code);
            end if;
          end if;

          -- Card: for completing the "Mi tarjeta" step
          if v_status = 'completed' and v_step.kind = 'card' then
            select c.code into v_card_code from public.cards c where c.lesson_id = v_lesson.id;
            if v_card_code is not null then
              insert into public.student_cards (student_id, card_code)
              values (v_student_id, v_card_code)
              on conflict do nothing;
              if found then
                v_new_cards := v_new_cards || to_jsonb(v_card_code);
              end if;
            end if;
          end if;

          v_ok_steps := v_ok_steps + 1;
        exception when others then
          v_rejected := v_rejected || jsonb_build_object(
            'type', 'step', 'ref', v_lesson.slug || '#' || coalesce(v_step_item ->> 'position', '?'),
            'code', case when sqlstate = 'P0001' then sqlerrm else sqlstate end);
        end;
      end loop;

      -- 4.5 Lesson complete? (every step completed, or skipped when allowed)
      if not exists (
        select 1
        from public.lesson_steps s
        left join public.step_progress sp
          on sp.student_id = v_student_id and sp.lesson_id = s.lesson_id and sp.position = s.position
        where s.lesson_id = v_lesson.id
          and (sp.status is null or sp.status = 'in_progress')
      ) then
        update public.lesson_progress lp
        set status = 'completed',
            completed_at = coalesce(
              (select max(sp.completed_at) from public.step_progress sp
               where sp.student_id = v_student_id and sp.lesson_id = v_lesson.id),
              now())
        where lp.student_id = v_student_id and lp.lesson_id = v_lesson.id and lp.status <> 'completed';

        -- One flower per lesson, color of the lesson's emotion. Never wilts.
        if v_lesson.emotion is not null then
          insert into public.garden_items (student_id, lesson_id, emotion)
          values (v_student_id, v_lesson.id, v_lesson.emotion)
          on conflict do nothing;
          if found then
            v_new_flowers := v_new_flowers || to_jsonb(v_lesson.slug);
          end if;
        end if;
      end if;

      v_touched := v_touched || v_lesson.id;
    exception when others then
      v_rejected := v_rejected || jsonb_build_object(
        'type', 'lesson', 'ref', v_lesson_item ->> 'lesson_slug',
        'code', case when sqlstate = 'P0001' then sqlerrm else sqlstate end);
    end;
  end loop;

  -- ===== 5. Answer: what was accepted, new rewards and the OFFICIAL state of touched lessons =====
  return jsonb_build_object(
    'accepted', jsonb_build_object('checkins', v_ok_checkins, 'steps', v_ok_steps),
    'rejected', v_rejected,
    'rewards',  jsonb_build_object('flowers', v_new_flowers, 'badges', v_new_badges, 'cards', v_new_cards),
    'lessons', coalesce((
      select jsonb_agg(jsonb_build_object(
        'lesson_slug',      l.slug,
        'status',           lp.status,
        'current_position', lp.current_position,
        'completed_at',     lp.completed_at,
        'steps', coalesce((
          select jsonb_agg(jsonb_build_object(
                   'position', sp.position,
                   'status', sp.status,
                   'indicator_result', sp.indicator_result) order by sp.position)
          from public.step_progress sp
          where sp.student_id = v_student_id and sp.lesson_id = l.id), '[]'::jsonb)
      ))
      from public.lesson_progress lp
      join public.lessons l on l.id = lp.lesson_id
      where lp.student_id = v_student_id and lp.lesson_id = any (v_touched)
    ), '[]'::jsonb)
  );
end;
$$;

revoke execute on function public.sync_progress(jsonb) from public, anon;
grant execute on function public.sync_progress(jsonb) to authenticated;

create or replace function public.my_week()
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  c_tz         constant text := 'America/Managua';
  v_today      date := (now() at time zone c_tz)::date;
  v_week_start date := v_today - (extract(isodow from v_today)::int - 1);
  v_student    record;
  v_current    record;
  v_next_class date;
begin
  if private.auth_role() is distinct from 'student' then
    raise exception 'my_week() is only available to students' using errcode = '42501';
  end if;

  select s.id, s.display_name,
         coalesce(s.language, g.language) as language,
         g.id as group_id, g.level, g.grade, g.section, g.class_weekday,
         p.full_name as teacher_name
    into v_student
  from public.students s
  join public.groups g on g.id = s.group_id
  left join public.profiles p on p.id = g.teacher_id
  where s.id = private.auth_student_id();

  if not found then
    raise exception 'Student not found' using errcode = 'P0002';
  end if;

  v_next_class := v_today + ((v_student.class_weekday - extract(isodow from v_today)::int + 7) % 7);

  select a.id, a.lesson_id, a.class_date, a.due_date, a.message, a.mode,
         l.slug, l.title, l.week, l.emotion, l.parts_count, l.duration_min
    into v_current
  from public.assignments a
  join public.lessons l on l.id = a.lesson_id
  order by a.class_date desc, a.created_at desc
  limit 1;

  return jsonb_build_object(
    'today', v_today,
    'student', jsonb_build_object(
      'id', v_student.id,
      'display_name', v_student.display_name,
      'language', v_student.language
    ),
    'group', jsonb_build_object(
      'id', v_student.group_id,
      'level', v_student.level,
      'grade', v_student.grade,
      'section', v_student.section,
      'class_weekday', v_student.class_weekday,
      'next_class_date', v_next_class
    ),
    'teacher_name', v_student.teacher_name,
    'today_checkin', (
      select jsonb_build_object(
               'emotion', ec.emotion,
               'intensity', ec.intensity,
               'scale_1_5', ec.scale_1_5,
               'prefers_not_to_say', ec.prefers_not_to_say)
      from public.emotion_checkins ec
      where ec.student_id = v_student.id
        and ec.checkin_date = v_today
        and ec.context = 'daily'
    ),
    'current', case when v_current.id is null then null else jsonb_build_object(
      'assignment_id', v_current.id,
      'lesson_slug',   v_current.slug,
      'title',         v_current.title,
      'week',          v_current.week,
      'emotion',       v_current.emotion,
      'duration_min',  v_current.duration_min,
      'class_date',    v_current.class_date,
      'due_date',      v_current.due_date,
      'message',       v_current.message,
      'mode',          v_current.mode,
      'status', coalesce((
        select lp.status::text from public.lesson_progress lp
        where lp.student_id = v_student.id and lp.lesson_id = v_current.lesson_id), 'not_started'),
      'current_position', coalesce((
        select lp.current_position from public.lesson_progress lp
        where lp.student_id = v_student.id and lp.lesson_id = v_current.lesson_id), 1),
      'parts', (
        select jsonb_agg(jsonb_build_object(
                 'part', p.part,
                 'steps_total', p.total,
                 'steps_done', p.done,
                 'status', case
                   when p.done = p.total then 'completed'
                   when p.touched > 0    then 'in_progress'
                   else 'not_started' end
               ) order by p.part)
        from (
          select s.part,
                 count(*) as total,
                 count(*) filter (where sp.status in ('completed', 'skipped')) as done,
                 count(sp.position) as touched
          from public.lesson_steps s
          left join public.step_progress sp
            on sp.student_id = v_student.id and sp.lesson_id = s.lesson_id and sp.position = s.position
          where s.lesson_id = v_current.lesson_id
          group by s.part
        ) as p
      )
    ) end,
    'garden', jsonb_build_object(
      'flowers', (select count(*) from public.garden_items gi where gi.student_id = v_student.id),
      'seeds',   (select count(*) from public.step_progress sp
                  where sp.student_id = v_student.id and sp.status = 'completed'),
      'days_this_week', (
        select count(distinct (sp.device_updated_at at time zone c_tz)::date)
        from public.step_progress sp
        where sp.student_id = v_student.id
          and (sp.device_updated_at at time zone c_tz)::date between v_week_start and v_today)
    ),
    'lessons', coalesce((
      select jsonb_agg(jsonb_build_object(
               'slug', l.slug,
               'week', l.week,
               'title', l.title,
               'emotion', l.emotion,
               'unlocked', a.id is not null,
               'assignment_id', a.id,
               'due_date', a.due_date,
               'status', coalesce(lp.status::text, 'not_started')
             ) order by l.week)
      from public.lessons l
      left join public.assignments a on a.lesson_id = l.id
      left join public.lesson_progress lp on lp.lesson_id = l.id and lp.student_id = v_student.id
      where l.level = v_student.level and l.grade = v_student.grade
    ), '[]'::jsonb)
  );
end;
$$;
