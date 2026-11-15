-- Assign a lesson to a whole group or to specific students, atomically.
-- SECURITY INVOKER: runs with the teacher's own permissions, so RLS policies,
-- column grants and the assignments_validate / *_notify triggers apply as usual.
create or replace function public.assign_lesson(
  p_group_id uuid,
  p_lesson_id uuid,
  p_class_date date,
  p_due_date date,
  p_message text default null,
  p_student_ids uuid[] default null,      -- null or empty = whole group
  p_notify_families boolean default false,
  p_remind_day_before boolean default true
)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_id uuid;
  v_targets_all boolean := coalesce(cardinality(p_student_ids), 0) = 0;
begin
  insert into public.assignments (
    group_id, lesson_id, class_date, due_date, message,
    targets_all, notify_families, remind_day_before
  )
  values (
    p_group_id, p_lesson_id, p_class_date, p_due_date, nullif(btrim(p_message), ''),
    v_targets_all, p_notify_families, p_remind_day_before
  )
  returning id into v_id;

  if not v_targets_all then
    insert into public.assignment_students (assignment_id, student_id)
    select distinct v_id, s
    from unnest(p_student_ids) as s;
  end if;

  return v_id;
end;
$$;

revoke all on function public.assign_lesson(uuid, uuid, date, date, text, uuid[], boolean, boolean) from public, anon;
grant execute on function public.assign_lesson(uuid, uuid, date, date, text, uuid[], boolean, boolean) to authenticated;