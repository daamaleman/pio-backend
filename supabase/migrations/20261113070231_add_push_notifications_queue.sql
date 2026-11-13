-- ============================================================
-- Migration: push notifications — device tokens, a queue filled by triggers/cron,
--            and two service_role functions used by the send-push Edge Function
-- ============================================================

-- A. Device tokens (Expo). One phone can hold several profiles → key is (token, user)
create table public.push_tokens (
  token      text not null check (token ~ '^Expo(nent)?PushToken\[[^\]]+\]$'),
  user_id    uuid not null references auth.users (id) on delete cascade,
  platform   text not null check (platform in ('android', 'ios')),
  updated_at timestamptz not null default now(),
  primary key (token, user_id)
);

alter table public.push_tokens enable row level security;
create policy "own push tokens" on public.push_tokens
  for select to authenticated using (user_id = (select auth.uid()));

create or replace function public.register_push_token(p_token text, p_platform text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  if p_token !~ '^Expo(nent)?PushToken\[[^\]]+\]$' or p_platform not in ('android', 'ios') then
    raise exception 'INVALID_TOKEN';
  end if;

  insert into public.push_tokens (token, user_id, platform)
  values (p_token, auth.uid(), p_platform)
  on conflict (token, user_id) do update set platform = excluded.platform, updated_at = now();

  return jsonb_build_object('registered', true);
end;
$$;

create or replace function public.unregister_push_token(p_token text)
returns jsonb
language sql
volatile
security definer
set search_path = ''
as $$
  with d as (delete from public.push_tokens where token = p_token and user_id = auth.uid() returning 1)
  select jsonb_build_object('removed', (select count(*) from d));
$$;

-- B. The queue (private: never exposed)
create table private.notification_queue (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users (id) on delete cascade,
  kind       text not null check (kind in ('new_lesson', 'due_reminder', 'new_alert', 'help_request')),
  data       jsonb not null default '{}'::jsonb,       -- ids only, never names or emotions
  not_before timestamptz not null default now(),
  status     text not null default 'pending'
             check (status in ('pending', 'sending', 'sent', 'failed', 'skipped')),
  attempts   smallint not null default 0,
  error      text,
  created_at timestamptz not null default now(),
  sent_at    timestamptz
);
create index notification_queue_pending_idx on private.notification_queue (status, not_before);
alter table private.notification_queue enable row level security;

-- Quiet hours: 7 p.m. to 7 a.m. Nicaragua → wait until 7 a.m.
create or replace function private.next_send_time()
returns timestamptz
language sql
stable
set search_path = ''
as $$
  select case
    when extract(hour from now() at time zone 'America/Managua') between 7 and 18 then now()
    when extract(hour from now() at time zone 'America/Managua') < 7
      then (date_trunc('day', now() at time zone 'America/Managua') + interval '7 hours') at time zone 'America/Managua'
    else (date_trunc('day', now() at time zone 'America/Managua') + interval '1 day 7 hours') at time zone 'America/Managua'
  end;
$$;

-- C. Triggers that enqueue
create or replace function private.on_assignment_created()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.targets_all then
    insert into private.notification_queue (user_id, kind, data, not_before)
    select s.auth_user_id, 'new_lesson',
           jsonb_build_object('assignment_id', new.id, 'lesson_id', new.lesson_id),
           private.next_send_time()
    from public.students s
    where s.group_id = new.group_id and s.active and s.auth_user_id is not null;
  end if;
  return null;
end;
$$;

create trigger assignments_notify
after insert on public.assignments
for each row execute function private.on_assignment_created();

-- Specific students (targets_all = false) are added row by row
create or replace function private.on_assignment_target_added()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into private.notification_queue (user_id, kind, data, not_before)
  select s.auth_user_id, 'new_lesson',
         jsonb_build_object('assignment_id', a.id, 'lesson_id', a.lesson_id),
         private.next_send_time()
  from public.students s
  join public.assignments a on a.id = new.assignment_id
  where s.id = new.student_id and s.active and s.auth_user_id is not null;
  return null;
end;
$$;

create trigger assignment_students_notify
after insert on public.assignment_students
for each row execute function private.on_assignment_target_added();

create or replace function private.on_alert_created()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_school uuid;
begin
  if new.origin::text = 'help_request' and new.details ->> 'wants' = 'counselor' then
    -- addressed to counseling: notify the school's counselors, never the teacher
    select g.school_id into v_school from public.groups g where g.id = new.group_id;
    insert into private.notification_queue (user_id, kind, data, not_before)
    select ss.profile_id, 'help_request', jsonb_build_object('alert_id', new.id), now()
    from public.staff_schools ss
    join public.profiles p on p.id = ss.profile_id
    where ss.school_id = v_school and p.role::text = 'counselor' and p.active;
  elsif new.origin::text = 'chat' then
    null;   -- chat alerts are handled in the AI chat step
  else
    insert into private.notification_queue (user_id, kind, data, not_before)
    select g.teacher_id,
           case when new.origin::text = 'help_request' then 'help_request' else 'new_alert' end,
           jsonb_build_object('alert_id', new.id),
           case when new.origin::text = 'help_request' then now() else private.next_send_time() end
    from public.groups g
    where g.id = new.group_id and g.teacher_id is not null;
  end if;
  return null;
end;
$$;

create trigger alerts_notify
after insert on public.alerts
for each row execute function private.on_alert_created();

-- D. Daily reminder: lessons due tomorrow, only for students who have not completed them
create or replace function private.enqueue_due_reminders()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tomorrow date := (now() at time zone 'America/Managua')::date + 1;
  v_count    integer;
begin
  insert into private.notification_queue (user_id, kind, data, not_before)
  select s.auth_user_id, 'due_reminder',
         jsonb_build_object('assignment_id', a.id, 'lesson_id', a.lesson_id),
         private.next_send_time()
  from public.assignments a
  join public.students s on s.group_id = a.group_id and s.active and s.auth_user_id is not null
  where a.remind_day_before
    and a.due_date = v_tomorrow
    and (a.targets_all or exists (select 1 from public.assignment_students ast
                                  where ast.assignment_id = a.id and ast.student_id = s.id))
    and not exists (select 1 from public.lesson_progress lp
                    where lp.student_id = s.id and lp.lesson_id = a.lesson_id and lp.status = 'completed')
    and not exists (select 1 from private.notification_queue q          -- never twice
                    where q.user_id = s.auth_user_id and q.kind = 'due_reminder'
                      and q.data ->> 'assignment_id' = a.id::text);
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- 23:00 UTC = 5 p.m. Nicaragua
select cron.schedule('enqueue-due-reminders', '0 23 * * *', $$select private.enqueue_due_reminders()$$);

-- E. For the send-push Edge Function (service_role only)
-- Take a batch of pending notifications, with their device tokens and language
create or replace function public.claim_notifications(p_limit integer default 200)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_out jsonb;
begin
  with picked as (
    select q.id from private.notification_queue q
    where q.status = 'pending' and q.not_before <= now()
    order by q.id
    limit p_limit
    for update skip locked                        -- two senders never take the same row
  ),
  claimed as (
    update private.notification_queue q
    set status = 'sending', attempts = q.attempts + 1
    from picked
    where q.id = picked.id
    returning q.id, q.user_id, q.kind, q.data
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', c.id,
           'kind', c.kind,
           'data', c.data,
           'language', coalesce(st.language::text, pr.preferred_language::text, 'es'),
           'tokens', coalesce((select jsonb_agg(t.token) from public.push_tokens t where t.user_id = c.user_id),
                              '[]'::jsonb))), '[]'::jsonb)
    into v_out
  from claimed c
  left join public.students st on st.auth_user_id = c.user_id
  left join public.profiles pr on pr.id = c.user_id;

  -- People without a registered phone: nothing to send
  update private.notification_queue q
  set status = 'skipped', error = 'NO_DEVICE'
  where q.id in (select (e ->> 'id')::bigint from jsonb_array_elements(v_out) e
                 where jsonb_array_length(e -> 'tokens') = 0);

  return v_out;
end;
$$;

-- Report what happened: sent ids, failed ids (retried up to 3 times), tokens Expo says are dead
create or replace function public.finish_notifications(
  p_sent bigint[], p_failed jsonb default '[]'::jsonb, p_invalid_tokens text[] default '{}')
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  update private.notification_queue
  set status = 'sent', sent_at = now(), error = null
  where id = any (p_sent);

  update private.notification_queue q
  set status     = case when q.attempts >= 3 then 'failed' else 'pending' end,
      error      = f ->> 'error',
      not_before = now() + interval '10 minutes'
  from jsonb_array_elements(p_failed) f
  where q.id = (f ->> 'id')::bigint;

  delete from public.push_tokens where token = any (p_invalid_tokens);

  return jsonb_build_object('sent', cardinality(p_sent),
                            'failed', jsonb_array_length(p_failed),
                            'tokens_removed', cardinality(p_invalid_tokens));
end;
$$;

revoke execute on function
  public.register_push_token(text, text), public.unregister_push_token(text),
  public.claim_notifications(integer), public.finish_notifications(bigint[], jsonb, text[])
from public, anon;
grant execute on function
  public.register_push_token(text, text), public.unregister_push_token(text)
to authenticated;
revoke execute on function
  public.claim_notifications(integer), public.finish_notifications(bigint[], jsonb, text[])
from authenticated;
grant execute on function
  public.claim_notifications(integer), public.finish_notifications(bigint[], jsonb, text[])
to service_role;