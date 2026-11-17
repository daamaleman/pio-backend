-- Teacher observations: what the teacher sees in class, next to the app data.
-- Only the student's teacher can read them. Counseling never sees the text: if the teacher
-- asks for support, counseling gets an alert with the category only.

create table public.teacher_observations (
  id          uuid primary key default gen_random_uuid(),
  student_id  uuid not null references public.students(id) on delete cascade,
  author_id   uuid not null references public.profiles(id),
  lesson_id   uuid references public.lessons(id),
  category    text not null check (category in ('emotional', 'social', 'participation', 'learning', 'family', 'other')),
  note        text not null check (char_length(btrim(note)) between 3 and 500),
  observed_on date not null default ((now() at time zone 'America/Managua')::date),
  referred    boolean not null default false,
  created_at  timestamptz not null default now()
);

create index teacher_observations_student_idx on public.teacher_observations (student_id, observed_on desc);

alter table public.teacher_observations enable row level security;
revoke all on public.teacher_observations from anon, authenticated;
grant select, delete on public.teacher_observations to authenticated;   -- writes only through add_observation()

create policy "observations: the student's teacher reads"
  on public.teacher_observations for select to authenticated
  using (private.is_teacher_of_student(student_id));

create policy "observations: the author deletes"
  on public.teacher_observations for delete to authenticated
  using (author_id = (select auth.uid()) and private.is_teacher_of_student(student_id));

create or replace function public.add_observation(
  p_student_id uuid,
  p_category text,
  p_note text,
  p_lesson_id uuid default null,
  p_observed_on date default null,
  p_refer boolean default false     -- true = ask counseling for support
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today date := (now() at time zone 'America/Managua')::date;
  v_day   date := coalesce(p_observed_on, v_today);
  v_group uuid;
  v_id    uuid;
  v_alert text := 'none';
begin
  if not coalesce(private.is_teacher_of_student(p_student_id), false) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_day > v_today or v_day < v_today - 60 then
    raise exception 'DATE_OUT_OF_RANGE';
  end if;

  select s.group_id into v_group from public.students s where s.id = p_student_id;

  insert into public.teacher_observations (student_id, author_id, lesson_id, category, note, observed_on, referred)
  values (p_student_id, auth.uid(), p_lesson_id, p_category, btrim(p_note), v_day, p_refer)
  returning id into v_id;

  if p_refer then
    -- The alert carries the category, never the note
    insert into public.alerts (student_id, group_id, origin, level, reason_code, details)
    values (p_student_id, v_group, 'teacher_observation', 'support', 'teacher_referral',
            jsonb_build_object('category', p_category))
    on conflict do nothing;                                  -- one active referral per student
    v_alert := case when found then 'created' else 'already_open' end;
  end if;

  return jsonb_build_object('id', v_id, 'alert', v_alert);
end;
$$;

revoke all on function public.add_observation(uuid, text, text, uuid, date, boolean) from public, anon;
grant execute on function public.add_observation(uuid, text, text, uuid, date, boolean) to authenticated;