-- "Remind the N pending" button (teacher progress screen).
-- SECURITY DEFINER because teachers cannot write to private.notification_queue;
-- it checks first that the caller manages the assignment.
create or replace function public.remind_pending(p_assignment_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pending       integer;
  v_without_app   integer;
  v_queued        integer;
begin
  if not coalesce(private.can_manage_assignment(p_assignment_id), false) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  with targets as (
    select s.id as student_id, s.auth_user_id, a.id as assignment_id, a.lesson_id
    from public.assignments a
    join public.students s on s.group_id = a.group_id and s.active
    where a.id = p_assignment_id
      and (a.targets_all or exists (select 1 from public.assignment_students ast
                                    where ast.assignment_id = a.id and ast.student_id = s.id))
      and not exists (select 1 from public.lesson_progress lp
                      where lp.student_id = s.id and lp.lesson_id = a.lesson_id and lp.status = 'completed')
  ),
  queued as (
    insert into private.notification_queue (user_id, kind, data, not_before)
    select t.auth_user_id, 'pending_reminder',
           jsonb_build_object('assignment_id', t.assignment_id, 'lesson_id', t.lesson_id),
           private.next_send_time()
    from targets t
    where t.auth_user_id is not null
      and not exists (select 1 from private.notification_queue q        -- not twice in 12 hours
                      where q.user_id = t.auth_user_id and q.kind = 'pending_reminder'
                        and q.data ->> 'assignment_id' = t.assignment_id::text
                        and q.created_at > now() - interval '12 hours')
    returning 1
  )
  select (select count(*) from targets),
         (select count(*) from targets where auth_user_id is null),
         (select count(*) from queued)
    into v_pending, v_without_app, v_queued;

  return jsonb_build_object(
    'pending', v_pending,
    'queued', v_queued,
    'without_app', v_without_app,
    'already_reminded', v_pending - v_without_app - v_queued
  );
end;
$$;

revoke all on function public.remind_pending(uuid) from public, anon;
grant execute on function public.remind_pending(uuid) to authenticated;