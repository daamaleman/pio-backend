-- ============================================================
-- Migration: anonymous group polls (secondary, step kind 'poll')
-- WHO answered and WHAT was answered live in two tables with no link between them.
-- ============================================================

-- WHAT was answered (no student)
create table private.poll_responses (
  id          uuid primary key default gen_random_uuid(),   -- random, so the order reveals nothing
  group_id    uuid not null references public.groups (id) on delete cascade,
  lesson_id   uuid not null references public.lessons (id) on delete cascade,
  option_id   text not null check (option_id ~ '^[a-z0-9_]{1,30}$'),
  answered_on date not null default ((now() at time zone 'America/Managua')::date)  -- date only, no time
);
create index poll_responses_group_lesson_idx on private.poll_responses (group_id, lesson_id);

-- WHO answered (no answer)
create table private.poll_participation (
  student_id  uuid not null references public.students (id) on delete cascade,
  lesson_id   uuid not null references public.lessons (id) on delete cascade,
  answered_on date not null default ((now() at time zone 'America/Managua')::date),
  primary key (student_id, lesson_id)
);

alter table private.poll_responses     enable row level security;
alter table private.poll_participation enable row level security;
-- No policies on purpose: only the functions below touch these tables.

-- Group results, hidden below 3 responses
create or replace function private.poll_results_for(p_group_id uuid, p_lesson_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with r as (
    select option_id, count(*)::int as n
    from private.poll_responses
    where group_id = p_group_id and lesson_id = p_lesson_id
    group by option_id
  ),
  t as (select coalesce(sum(n), 0)::int as total from r)
  select case
    when t.total < 3 then jsonb_build_object(
      'hidden', true, 'reason', 'TOO_FEW_RESPONSES', 'min_respondents', 3, 'total', t.total)
    else jsonb_build_object(
      'hidden', false, 'total', t.total,
      'options', (select jsonb_agg(jsonb_build_object(
                           'option_id', r.option_id, 'count', r.n,
                           'pct', round(100.0 * r.n / t.total))
                         order by r.n desc, r.option_id)
                  from r))
  end
  from t;
$$;

revoke execute on function private.poll_results_for(uuid, uuid) from public, anon, authenticated;

-- Student answers the poll of a lesson (idempotent: a second answer is ignored)
create or replace function public.submit_poll(p_lesson_slug text, p_option_id text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_student  uuid := private.auth_student_id();
  v_group    uuid := private.auth_group_id();
  v_lesson   uuid;
  v_inserted integer;
begin
  if v_student is null then
    raise exception 'Not allowed' using errcode = '42501';
  end if;

  select l.id into v_lesson from public.lessons l where l.slug = p_lesson_slug;
  if not found then
    raise exception 'LESSON_NOT_FOUND';
  end if;

  if not exists (select 1 from public.lesson_steps ls where ls.lesson_id = v_lesson and ls.kind = 'poll') then
    raise exception 'NO_POLL_IN_LESSON';
  end if;

  -- The lesson must be assigned to this student (same rule as sync_progress)
  if not exists (
    select 1 from public.assignments a
    where a.group_id = v_group and a.lesson_id = v_lesson
      and (a.targets_all or exists (select 1 from public.assignment_students ast
                                    where ast.assignment_id = a.id and ast.student_id = v_student))
  ) then
    raise exception 'LESSON_LOCKED';
  end if;

  if p_option_id is null or p_option_id !~ '^[a-z0-9_]{1,30}$' then
    raise exception 'INVALID_OPTION';
  end if;

  -- If the lesson content already defines the poll, the option must be one of its options
  if exists (select 1 from public.lesson_contents lc
             where lc.lesson_id = v_lesson
               and jsonb_path_exists(lc.payload, '$.steps[*] ? (@.kind == "poll")'))
     and not exists (select 1 from public.lesson_contents lc
                     where lc.lesson_id = v_lesson
                       and jsonb_path_exists(lc.payload,
                             '$.steps[*] ? (@.kind == "poll").options[*] ? (@.id == $opt)',
                             jsonb_build_object('opt', p_option_id))) then
    raise exception 'INVALID_OPTION';
  end if;

  -- 1. Record WHO answered (only once)
  insert into private.poll_participation (student_id, lesson_id)
  values (v_student, v_lesson)
  on conflict do nothing;
  get diagnostics v_inserted = row_count;

  -- 2. Record WHAT was answered, only if this is the first answer. No student id here.
  if v_inserted = 1 then
    insert into private.poll_responses (group_id, lesson_id, option_id)
    values (v_group, v_lesson, p_option_id);
  end if;

  return jsonb_build_object(
    'already_answered', v_inserted = 0,
    'results', private.poll_results_for(v_group, v_lesson));
end;
$$;

-- Results: a student (only after answering) or the group's teacher / school leaders
create or replace function public.poll_results(p_lesson_slug text, p_group_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_student uuid := private.auth_student_id();
  v_group   uuid;
  v_lesson  uuid;
begin
  select l.id into v_lesson from public.lessons l where l.slug = p_lesson_slug;
  if not found then
    raise exception 'LESSON_NOT_FOUND';
  end if;

  if v_student is not null then
    v_group := private.auth_group_id();
    if not exists (select 1 from private.poll_participation pp
                   where pp.student_id = v_student and pp.lesson_id = v_lesson) then
      raise exception 'ANSWER_FIRST';
    end if;
  else
    v_group := p_group_id;
    if v_group is null
       or not (private.is_teacher_of_group(v_group) or private.can_lead_group(v_group)) then
      raise exception 'Not allowed' using errcode = '42501';
    end if;
  end if;

  return private.poll_results_for(v_group, v_lesson);
end;
$$;

revoke execute on function public.submit_poll(text, text), public.poll_results(text, uuid) from public, anon;
grant  execute on function public.submit_poll(text, text), public.poll_results(text, uuid) to authenticated;