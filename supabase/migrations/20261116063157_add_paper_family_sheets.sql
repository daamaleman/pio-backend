-- FAM-03: the teacher can record a family sheet that was filled on paper.
-- A sheet submitted in the app always wins: the teacher never overwrites the family's own answers.

alter table public.family_sheets
  add column source text not null default 'app' check (source in ('app', 'paper')),
  add column recorded_by uuid references public.profiles(id);

-- Teacher records (or corrects) a paper sheet for one of their students
create or replace function public.record_family_sheet(
  p_student_id uuid,
  p_lesson_id uuid,
  p_challenge_done public.family_challenge_done,
  p_how_responded public.family_how_responded,
  p_emotion_mentioned public.emotion default null,
  p_comment text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_group    uuid;
  v_level    public.school_level;
  v_comment  text := nullif(btrim(coalesce(p_comment, '')), '');
  v_existing text;
begin
  if not coalesce(private.is_teacher_of_student(p_student_id), false) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select s.group_id, g.level into v_group, v_level
  from public.students s join public.groups g on g.id = s.group_id
  where s.id = p_student_id;

  if v_level <> 'primary' then
    raise exception 'NOT_FOR_LEVEL';
  end if;
  if v_comment is not null and char_length(v_comment) > 280 then
    raise exception 'COMMENT_TOO_LONG';
  end if;

  if not exists (
    select 1 from public.assignments a
    where a.group_id = v_group and a.lesson_id = p_lesson_id
      and (a.targets_all or exists (select 1 from public.assignment_students ast
                                    where ast.assignment_id = a.id and ast.student_id = p_student_id))
  ) then
    raise exception 'LESSON_NOT_ASSIGNED';
  end if;

  select fs.source into v_existing
  from public.family_sheets fs
  where fs.student_id = p_student_id and fs.lesson_id = p_lesson_id;

  if v_existing = 'app' then
    raise exception 'ALREADY_SUBMITTED_IN_APP';
  end if;

  insert into public.family_sheets
    (student_id, lesson_id, challenge_done, emotion_mentioned, how_responded, comment, source, recorded_by)
  values
    (p_student_id, p_lesson_id, p_challenge_done, p_emotion_mentioned, p_how_responded, v_comment, 'paper', auth.uid())
  on conflict (student_id, lesson_id) do update set
    challenge_done    = excluded.challenge_done,
    emotion_mentioned = excluded.emotion_mentioned,
    how_responded     = excluded.how_responded,
    comment           = excluded.comment,
    source            = 'paper',
    recorded_by       = auth.uid(),
    submitted_at      = now();

  return jsonb_build_object('saved', true, 'source', 'paper');
end;
$$;

revoke all on function public.record_family_sheet(uuid, uuid, public.family_challenge_done, public.family_how_responded, public.emotion, text) from public, anon;
grant execute on function public.record_family_sheet(uuid, uuid, public.family_challenge_done, public.family_how_responded, public.emotion, text) to authenticated;

-- Same function as before; only the two marked lines are new (an app submission replaces a paper one)
create or replace function public.submit_family_sheet(
  p_lesson_slug text,
  p_challenge_done public.family_challenge_done,
  p_how_responded public.family_how_responded,
  p_emotion_mentioned public.emotion default null,
  p_comment text default null
)
returns jsonb
language plpgsql
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
    source            = 'app',   -- new
    recorded_by       = null,    -- new
    submitted_at      = now();

  return jsonb_build_object('lesson_slug', p_lesson_slug, 'saved', true);
end;
$$;