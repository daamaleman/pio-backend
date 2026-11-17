-- Anonymous question box (secondary). The question and who wrote it live in two unlinked tables,
-- like polls: public.anonymous_questions has no student column, and only the date (no time) is kept.

create table public.anonymous_questions (
  id          uuid primary key default gen_random_uuid(),
  group_id    uuid not null references public.groups(id) on delete cascade,
  lesson_id   uuid not null references public.lessons(id),
  body        text not null check (char_length(btrim(body)) between 3 and 280),
  status      text not null default 'new' check (status in ('new', 'answered', 'hidden')),
  created_on  date not null default ((now() at time zone 'America/Managua')::date),
  answered_at timestamptz
);

create index anonymous_questions_group_idx on public.anonymous_questions (group_id, status, created_on desc);

alter table public.anonymous_questions enable row level security;
revoke all on public.anonymous_questions from anon, authenticated;
grant select on public.anonymous_questions to authenticated;   -- writes only through the functions

create policy "questions: the group's teacher reads"
  on public.anonymous_questions for select to authenticated
  using (private.is_teacher_of_group(group_id));

create policy "questions: school counseling reads"
  on public.anonymous_questions for select to authenticated
  using (exists (select 1 from public.groups g
                 where g.id = group_id
                   and private.is_staff_of_school(g.school_id, array['counselor'::public.app_role])));

-- Only how many questions each student sent per lesson (anti-spam). Never linked to the text.
create table private.anonymous_question_counts (
  student_id uuid not null references public.students(id) on delete cascade,
  lesson_id  uuid not null references public.lessons(id),
  questions  smallint not null default 0,
  primary key (student_id, lesson_id)
);

create or replace function public.submit_anonymous_question(p_lesson_slug text, p_body text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student uuid := private.auth_student_id();
  v_group   uuid := private.auth_group_id();
  v_body    text := btrim(coalesce(p_body, ''));
  v_lesson  uuid;
  v_count   integer;
begin
  if v_student is null then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  if private.auth_level()::text <> 'secondary' then
    raise exception 'NOT_FOR_LEVEL';
  end if;
  if char_length(v_body) < 3 or char_length(v_body) > 280 then
    raise exception 'INVALID_LENGTH';
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

  -- Up to 3 questions per student and lesson
  insert into private.anonymous_question_counts (student_id, lesson_id, questions)
  values (v_student, v_lesson, 1)
  on conflict (student_id, lesson_id) do update
    set questions = private.anonymous_question_counts.questions + 1
    where private.anonymous_question_counts.questions < 3
  returning questions into v_count;

  if v_count is null then
    raise exception 'TOO_MANY_QUESTIONS';
  end if;

  insert into public.anonymous_questions (group_id, lesson_id, body)
  values (v_group, v_lesson, v_body);

  return jsonb_build_object('saved', true, 'remaining', 3 - v_count);
end;
$$;

revoke all on function public.submit_anonymous_question(text, text) from public, anon;
grant execute on function public.submit_anonymous_question(text, text) to authenticated;

create or replace function public.set_question_status(p_question_id uuid, p_status text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_group uuid;
begin
  select q.group_id into v_group from public.anonymous_questions q where q.id = p_question_id;
  if v_group is null or not coalesce(private.is_teacher_of_group(v_group), false) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_status not in ('new', 'answered', 'hidden') then
    raise exception 'INVALID_STATUS';
  end if;

  update public.anonymous_questions
     set status = p_status,
         answered_at = case when p_status = 'answered' then now() else null end
   where id = p_question_id;

  return jsonb_build_object('status', p_status);
end;
$$;

revoke all on function public.set_question_status(uuid, text) from public, anon;
grant execute on function public.set_question_status(uuid, text) to authenticated;