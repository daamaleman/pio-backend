-- ============================================================
-- Migration: school panel for director/counselor/admin
--   private.climate_for_groups  (single climate calculation, internal only)
--   group_climate               (now security definer, teacher OR school leader)
--   school_overview             (aggregates only, no student names)
-- ============================================================

-- A. Permission helpers
create or replace function private.can_lead_school(p_school_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_admin()
      or private.is_staff_of_school(p_school_id, array['director', 'counselor']::public.app_role[]);
$$;

create or replace function private.can_lead_group(p_group_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.groups g
    where g.id = p_group_id and private.can_lead_school(g.school_id));
$$;

grant execute on function private.can_lead_school(uuid), private.can_lead_group(uuid) to authenticated;

-- B. The ONE climate calculation (moved from group_climate, now for one or many groups)
create or replace function private.climate_for_groups(p_group_ids uuid[], p_week_start date default null)
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
  -- Normalize to the Monday of that week
  v_start := coalesce(p_week_start, v_today);
  v_start := v_start - (extract(isodow from v_start)::int - 1);

  select count(distinct ec.student_id) filter (where not ec.prefers_not_to_say),
         count(*)                      filter (where not ec.prefers_not_to_say),
         count(*)                      filter (where ec.prefers_not_to_say)
    into v_respondents, v_total, v_declined
  from public.emotion_checkins ec
  join public.students s on s.id = ec.student_id
  where s.group_id = any (p_group_ids) and s.active
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
        where s.group_id = any (p_group_ids) and s.active
          and ec.context = 'daily'
          and not ec.prefers_not_to_say
          and ec.checkin_date between v_start and v_start + 6
        group by ec.emotion
      ) as c on c.emotion = e.emotion
    )
  );
end;
$$;

-- Internal only: no permission check inside, so nobody may call it directly.
-- It runs only inside the security definer functions below (as their owner).
revoke execute on function private.climate_for_groups(uuid[], date) from public, anon, authenticated;

-- C. group_climate: same output as before, now for the teacher OR a school leader
create or replace function public.group_climate(p_group_id uuid, p_week_start date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not (private.is_teacher_of_group(p_group_id) or private.can_lead_group(p_group_id)) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;

  return private.climate_for_groups(array[p_group_id], p_week_start);
end;
$$;

-- D. School panel (DIR-01): aggregates only
create or replace function public.school_overview(p_school_id uuid, p_week_start date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  c_tz      constant text := 'America/Managua';
  v_today   date := (now() at time zone c_tz)::date;
  v_school  record;
  v_groups  uuid[];
begin
  if not private.can_lead_school(p_school_id) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;

  select sc.id, sc.name into v_school from public.schools sc where sc.id = p_school_id;
  if not found then
    raise exception 'SCHOOL_NOT_FOUND';
  end if;

  select coalesce(array_agg(g.id), '{}') into v_groups
  from public.groups g
  where g.school_id = p_school_id and g.active;

  return jsonb_build_object(
    'school', jsonb_build_object('id', v_school.id, 'name', v_school.name),
    'totals', jsonb_build_object(
      'groups',        cardinality(v_groups),
      'teachers',      (select count(distinct g.teacher_id) from public.groups g where g.id = any (v_groups)),
      'students',      (select count(*) from public.students s where s.group_id = any (v_groups) and s.active),
      'badges_earned', (select count(*) from public.student_badges sb
                        join public.students s on s.id = sb.student_id
                        where s.group_id = any (v_groups) and s.active),
      'active_alerts', (select count(*) from public.alerts a
                        where a.group_id = any (v_groups) and a.status::text <> 'closed')
    ),
    'climate', private.climate_for_groups(v_groups, p_week_start),
    'groups', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id',            g.id,
               'level',         g.level,
               'grade',         g.grade,
               'section',       g.section,
               'teacher_name',  p.full_name,
               'students',      st.n,
               'badges_earned', b.n,
               'alerts',        jsonb_build_object('open', al.open, 'in_attention', al.in_attention),
               'climate',       private.climate_for_groups(array[g.id], p_week_start),
               'current_assignment', ca.obj
             ) order by g.level, g.grade, g.section)
      from public.groups g
      left join public.profiles p on p.id = g.teacher_id
      cross join lateral (
        select count(*) as n from public.students s where s.group_id = g.id and s.active
      ) as st
      cross join lateral (
        select count(*) as n from public.student_badges sb
        join public.students s on s.id = sb.student_id
        where s.group_id = g.id and s.active
      ) as b
      cross join lateral (
        select count(*) filter (where a.status::text not in ('in_attention', 'closed')) as open,
               count(*) filter (where a.status::text = 'in_attention')               as in_attention
        from public.alerts a where a.group_id = g.id
      ) as al
      -- newest assignment still open (same targeted/completed formula as group_overview)
      left join lateral (
        select jsonb_build_object(
                 'assignment_id', a.id,
                 'lesson_slug',   l.slug,
                 'week',          l.week,
                 'due_date',      a.due_date,
                 'targeted',      t.n,
                 'completed',     c.n,
                 'completed_pct', case when t.n = 0 then 0 else round(100.0 * c.n / t.n) end
               ) as obj
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
        where a.group_id = g.id and a.due_date >= v_today
        order by a.class_date desc
        limit 1
      ) as ca on true
      where g.id = any (v_groups)
    ), '[]'::jsonb)
  );
end;
$$;

revoke execute on function public.school_overview(uuid, date) from public, anon;
grant  execute on function public.school_overview(uuid, date) to authenticated;