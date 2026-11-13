-- ============================================================
-- Migration: AI chat foundation (secondary). The OpenAI integration lives in an Edge Function
-- (owned by the AI integrator). This migration enforces WHO may chat, WHERE messages live,
-- that NO staff can read them, 30-day retention, and risk alerts for counseling only.
-- ============================================================

-- A. Terms of the AI chat accepted by the student (the "página de términos de IA")
create table public.ai_terms_acceptances (
  student_id    uuid not null references public.students (id) on delete cascade,
  terms_version text not null check (terms_version ~ '^[0-9]{4}-[0-9]{2}$'),
  accepted_at   timestamptz not null default now(),
  primary key (student_id, terms_version)
);
alter table public.ai_terms_acceptances enable row level security;
create policy "own ai terms" on public.ai_terms_acceptances
  for select to authenticated using (student_id = private.auth_student_id());

-- B. Messages: private schema, NO policies → no staff role can read them, ever
create table private.ai_messages (
  id           bigint generated always as identity primary key,
  student_id   uuid not null references public.students (id) on delete cascade,
  role         text not null check (role in ('student', 'assistant')),
  content      text not null check (char_length(content) between 1 and 2000),
  risk_flagged boolean not null default false,
  created_at   timestamptz not null default now()
);
create index ai_messages_student_idx on private.ai_messages (student_id, created_at desc);
alter table private.ai_messages enable row level security;

-- C. One place that decides whether a student may chat right now
create or replace function private.ai_chat_status(p_student_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  c_terms_version  constant text    := '2026-11';   -- bump when the terms text changes
  c_max_per_hour   constant integer := 30;
  v_ok             boolean;
begin
  select (g.ai_chat_enabled and g.level::text = 'secondary' and s.active and g.active)
    into v_ok
  from public.students s join public.groups g on g.id = s.group_id
  where s.id = p_student_id;

  if not coalesce(v_ok, false) then
    return jsonb_build_object('allowed', false, 'reason', 'AI_CHAT_DISABLED', 'terms_version', c_terms_version);
  end if;

  if not exists (select 1 from public.ai_terms_acceptances t
                 where t.student_id = p_student_id and t.terms_version = c_terms_version) then
    return jsonb_build_object('allowed', false, 'reason', 'TERMS_NOT_ACCEPTED', 'terms_version', c_terms_version);
  end if;

  if (select count(*) from private.ai_messages m
      where m.student_id = p_student_id and m.role = 'student'
        and m.created_at > now() - interval '1 hour') >= c_max_per_hour then
    return jsonb_build_object('allowed', false, 'reason', 'RATE_LIMITED', 'terms_version', c_terms_version);
  end if;

  return jsonb_build_object('allowed', true, 'terms_version', c_terms_version);
end;
$$;
revoke execute on function private.ai_chat_status(uuid) from public, anon, authenticated;

-- D. For the student (app)
create or replace function public.my_chat_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if private.auth_student_id() is null then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  return private.ai_chat_status(private.auth_student_id());
end;
$$;

create or replace function public.accept_ai_terms(p_version text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_student uuid := private.auth_student_id();
  v_status  jsonb;
begin
  if v_student is null then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  v_status := private.ai_chat_status(v_student);
  if v_status ->> 'reason' = 'AI_CHAT_DISABLED' then
    raise exception 'AI_CHAT_DISABLED';
  end if;
  if p_version is distinct from v_status ->> 'terms_version' then
    raise exception 'WRONG_TERMS_VERSION';   -- must accept the CURRENT terms
  end if;

  insert into public.ai_terms_acceptances (student_id, terms_version)
  values (v_student, p_version)
  on conflict do nothing;

  return private.ai_chat_status(v_student);
end;
$$;

-- The student's own conversation (last 30 days). Staff have no equivalent: by design.
create or replace function public.my_chat_history(p_limit integer default 50)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('role', m.role, 'content', m.content, 'at', m.created_at)
                            order by m.created_at), '[]'::jsonb)
  from (select * from private.ai_messages
        where student_id = private.auth_student_id()
          and created_at > now() - interval '30 days'
        order by created_at desc
        limit least(greatest(coalesce(p_limit, 50), 1), 200)) m;
$$;

-- E. For the AI Edge Function (service_role only)
-- Before calling OpenAI: may this student chat, and what was said recently?
create or replace function public.ai_chat_context(p_student_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select private.ai_chat_status(p_student_id) || jsonb_build_object(
    'history', coalesce((
      select jsonb_agg(jsonb_build_object('role', m.role, 'content', m.content) order by m.created_at)
      from (select * from private.ai_messages
            where student_id = p_student_id and created_at > now() - interval '30 days'
            order by created_at desc limit 20) m), '[]'::jsonb));
$$;

-- After answering: store the exchange; on risk, alert counseling with the CATEGORY only
create or replace function public.ai_chat_record(
  p_student_id        uuid,
  p_student_message   text,
  p_assistant_message text,
  p_risk_category     text default null      -- null | self_harm | abuse | violence | other
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_group uuid;
  v_alert text := 'none';
begin
  if not (private.ai_chat_status(p_student_id) ->> 'allowed')::boolean then
    raise exception 'NOT_ALLOWED: %', private.ai_chat_status(p_student_id) ->> 'reason';
  end if;
  if p_risk_category is not null
     and p_risk_category not in ('self_harm', 'abuse', 'violence', 'other') then
    raise exception 'INVALID_RISK_CATEGORY';
  end if;

  insert into private.ai_messages (student_id, role, content, risk_flagged)
  values (p_student_id, 'student', p_student_message, p_risk_category is not null),
         (p_student_id, 'assistant', p_assistant_message, false);

  if p_risk_category is not null then
    select s.group_id into v_group from public.students s where s.id = p_student_id;
    begin
      insert into public.alerts (student_id, group_id, origin, level, reason_code, details)
      values (p_student_id, v_group, 'chat', 'risk_high', 'chat_risk',
              jsonb_build_object('category', p_risk_category));   -- never the text
      v_alert := 'created';
    exception when unique_violation then
      v_alert := 'already_open';                                   -- an open chat alert exists
    end;
  end if;

  return jsonb_build_object('stored', true, 'alert', v_alert);
end;
$$;

revoke execute on function
  public.my_chat_status(), public.accept_ai_terms(text), public.my_chat_history(integer),
  public.ai_chat_context(uuid), public.ai_chat_record(uuid, text, text, text)
from public, anon, authenticated;
grant execute on function
  public.my_chat_status(), public.accept_ai_terms(text), public.my_chat_history(integer)
to authenticated;
grant execute on function
  public.ai_chat_context(uuid), public.ai_chat_record(uuid, text, text, text)
to service_role;

-- F. Retention: chat messages live 30 days (spec)
select cron.schedule('purge-ai-messages', '30 6 * * *',
  $$delete from private.ai_messages where created_at < now() - interval '30 days'$$);

-- G. Chat risk alerts notify counseling (and the director) immediately, never the teacher
alter table private.notification_queue drop constraint notification_queue_kind_check;
alter table private.notification_queue add constraint notification_queue_kind_check
  check (kind in ('new_lesson', 'due_reminder', 'new_alert', 'help_request', 'risk_alert'));

create or replace function private.on_alert_created()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_school uuid;
begin
  select g.school_id into v_school from public.groups g where g.id = new.group_id;

  if new.origin::text = 'chat' then
    -- risk detected in the AI chat: counselors and directors of the school, right away
    insert into private.notification_queue (user_id, kind, data, not_before)
    select ss.profile_id, 'risk_alert', jsonb_build_object('alert_id', new.id), now()
    from public.staff_schools ss
    join public.profiles p on p.id = ss.profile_id
    where ss.school_id = v_school and p.role::text in ('counselor', 'director') and p.active;

  elsif new.origin::text = 'help_request' and new.details ->> 'wants' = 'counselor' then
    insert into private.notification_queue (user_id, kind, data, not_before)
    select ss.profile_id, 'help_request', jsonb_build_object('alert_id', new.id), now()
    from public.staff_schools ss
    join public.profiles p on p.id = ss.profile_id
    where ss.school_id = v_school and p.role::text = 'counselor' and p.active;

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