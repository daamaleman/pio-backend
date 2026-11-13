-- ============================================================
-- Migration: secondary toolbox (plans) and month goal.
-- The TEXT lives only on the phone. The server keeps that it exists and which days it was practiced.
-- ============================================================

create table public.student_tools (
  id          uuid primary key,                 -- generated on the phone, links to the local text
  student_id  uuid not null references public.students (id) on delete cascade,
  lesson_id   uuid not null,
  position    smallint not null,
  created_on  date not null,
  archived_on date,
  foreign key (lesson_id, position) references public.lesson_steps (lesson_id, position)
);
create index student_tools_student_idx on public.student_tools (student_id);

create table public.student_tool_uses (
  tool_id uuid not null references public.student_tools (id) on delete cascade,
  used_on date not null,
  primary key (tool_id, used_on)
);

create table public.student_goals (
  id         uuid primary key,                  -- generated on the phone
  student_id uuid not null references public.students (id) on delete cascade,
  month      date not null check (extract(day from month) = 1),
  created_on date not null,
  outcome    text check (outcome in ('achieved', 'partly', 'not_yet')),   -- set at the end of the month
  unique (student_id, month)                    -- one goal per month
);

create table public.student_goal_checks (
  goal_id    uuid not null references public.student_goals (id) on delete cascade,
  checked_on date not null,
  done       boolean not null,
  primary key (goal_id, checked_on)
);

alter table public.student_tools       enable row level security;
alter table public.student_tool_uses   enable row level security;
alter table public.student_goals       enable row level security;
alter table public.student_goal_checks enable row level security;

-- The student reads only their own rows. Writes only through sync_toolbox().
create policy "own tools" on public.student_tools
  for select to authenticated using (student_id = private.auth_student_id());
create policy "own tool uses" on public.student_tool_uses
  for select to authenticated using (exists (
    select 1 from public.student_tools t where t.id = tool_id and t.student_id = private.auth_student_id()));
create policy "own goals" on public.student_goals
  for select to authenticated using (student_id = private.auth_student_id());
create policy "own goal checks" on public.student_goal_checks
  for select to authenticated using (exists (
    select 1 from public.student_goals g where g.id = goal_id and g.student_id = private.auth_student_id()));

-- One door for everything the phone has queued (offline-friendly, idempotent)
create or replace function public.sync_toolbox(p_payload jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_student  uuid := private.auth_student_id();
  v_today    date := (now() at time zone 'America/Managua')::date;
  v_rejected jsonb := '[]'::jsonb;
  n_tools    integer := 0;
  n_uses     integer := 0;
  n_goals    integer := 0;
  n_checks   integer := 0;
  r          jsonb;
  v_lesson   uuid;
  v_id       uuid;
  v_date     date;
begin
  if v_student is null or private.auth_level()::text <> 'secondary' then
    raise exception 'Not allowed' using errcode = '42501';
  end if;

  -- 1. Tools (plans): must come from a 'plan' step of a lesson
  for r in select * from jsonb_array_elements(coalesce(p_payload -> 'tools', '[]'::jsonb)) loop
    begin
      v_id := null;
      v_date := (r ->> 'created_on')::date;
      if v_date not between v_today - 60 and v_today + 1 then
        v_rejected := v_rejected || jsonb_build_object('type', 'tool', 'ref', r ->> 'id', 'code', 'DATE_OUT_OF_RANGE');
        continue;
      end if;

      select ls.lesson_id into v_lesson
      from public.lesson_steps ls join public.lessons l on l.id = ls.lesson_id
      where l.slug = r ->> 'lesson_slug' and ls.position = (r ->> 'position')::int and ls.kind = 'plan';
      if not found then
        v_rejected := v_rejected || jsonb_build_object('type', 'tool', 'ref', r ->> 'id', 'code', 'PLAN_STEP_NOT_FOUND');
        continue;
      end if;

      insert into public.student_tools (id, student_id, lesson_id, position, created_on, archived_on)
      values ((r ->> 'id')::uuid, v_student, v_lesson, (r ->> 'position')::int, v_date, (r ->> 'archived_on')::date)
      on conflict (id) do update set archived_on = excluded.archived_on
        where public.student_tools.student_id = v_student   -- never touch another student's row
      returning id into v_id;

      if v_id is null then
        v_rejected := v_rejected || jsonb_build_object('type', 'tool', 'ref', r ->> 'id', 'code', 'NOT_OWNER');
      else
        n_tools := n_tools + 1;
      end if;
    exception when others then
      v_rejected := v_rejected || jsonb_build_object('type', 'tool', 'ref', r ->> 'id', 'code', sqlstate);
    end;
  end loop;

  -- 2. Days a tool was used
  for r in select * from jsonb_array_elements(coalesce(p_payload -> 'tool_uses', '[]'::jsonb)) loop
    begin
      v_date := (r ->> 'used_on')::date;
      if v_date not between v_today - 60 and v_today + 1 then
        v_rejected := v_rejected || jsonb_build_object('type', 'tool_use', 'ref', r ->> 'tool_id', 'code', 'DATE_OUT_OF_RANGE');
        continue;
      end if;
      if not exists (select 1 from public.student_tools t
                     where t.id = (r ->> 'tool_id')::uuid and t.student_id = v_student) then
        v_rejected := v_rejected || jsonb_build_object('type', 'tool_use', 'ref', r ->> 'tool_id', 'code', 'NOT_OWNER');
        continue;
      end if;
      insert into public.student_tool_uses (tool_id, used_on)
      values ((r ->> 'tool_id')::uuid, v_date)
      on conflict do nothing;
      n_uses := n_uses + 1;
    exception when others then
      v_rejected := v_rejected || jsonb_build_object('type', 'tool_use', 'ref', r ->> 'tool_id', 'code', sqlstate);
    end;
  end loop;

  -- 3. Month goals (one per month)
  for r in select * from jsonb_array_elements(coalesce(p_payload -> 'goals', '[]'::jsonb)) loop
    begin
      v_id := null;
      insert into public.student_goals (id, student_id, month, created_on, outcome)
      values ((r ->> 'id')::uuid, v_student,
              date_trunc('month', (r ->> 'created_on')::date)::date,
              (r ->> 'created_on')::date, r ->> 'outcome')
      on conflict (id) do update set outcome = excluded.outcome
        where public.student_goals.student_id = v_student
      returning id into v_id;

      if v_id is null then
        v_rejected := v_rejected || jsonb_build_object('type', 'goal', 'ref', r ->> 'id', 'code', 'NOT_OWNER');
      else
        n_goals := n_goals + 1;
      end if;
    exception
      when unique_violation then   -- another goal already exists for that month
        v_rejected := v_rejected || jsonb_build_object('type', 'goal', 'ref', r ->> 'id', 'code', 'GOAL_EXISTS_FOR_MONTH');
      when others then
        v_rejected := v_rejected || jsonb_build_object('type', 'goal', 'ref', r ->> 'id', 'code', sqlstate);
    end;
  end loop;

  -- 4. Daily goal checks (the latest value of the day wins)
  for r in select * from jsonb_array_elements(coalesce(p_payload -> 'goal_checks', '[]'::jsonb)) loop
    begin
      v_date := (r ->> 'checked_on')::date;
      if v_date not between v_today - 60 and v_today + 1 then
        v_rejected := v_rejected || jsonb_build_object('type', 'goal_check', 'ref', r ->> 'goal_id', 'code', 'DATE_OUT_OF_RANGE');
        continue;
      end if;
      if not exists (select 1 from public.student_goals g
                     where g.id = (r ->> 'goal_id')::uuid and g.student_id = v_student) then
        v_rejected := v_rejected || jsonb_build_object('type', 'goal_check', 'ref', r ->> 'goal_id', 'code', 'NOT_OWNER');
        continue;
      end if;
      insert into public.student_goal_checks (goal_id, checked_on, done)
      values ((r ->> 'goal_id')::uuid, v_date, (r ->> 'done')::boolean)
      on conflict (goal_id, checked_on) do update set done = excluded.done;
      n_checks := n_checks + 1;
    exception when others then
      v_rejected := v_rejected || jsonb_build_object('type', 'goal_check', 'ref', r ->> 'goal_id', 'code', sqlstate);
    end;
  end loop;

  return jsonb_build_object(
    'accepted', jsonb_build_object('tools', n_tools, 'tool_uses', n_uses, 'goals', n_goals, 'goal_checks', n_checks),
    'rejected', v_rejected);
end;
$$;

revoke execute on function public.sync_toolbox(jsonb) from public, anon;
grant  execute on function public.sync_toolbox(jsonb) to authenticated;