-- ============================================================
-- Migration: support alerts (DOC-07) + nightly detection with pg_cron
-- Rule (decided 12 nov 2026, pending psychology validation):
--   sadness, fear or anger on >= 3 DISTINCT days within the last 7 days → 'support' alert
-- ============================================================

create type public.alert_origin as enum ('checkin', 'chat', 'teacher_observation');
create type public.alert_level  as enum ('support', 'risk_moderate', 'risk_high');
create type public.alert_status as enum ('open', 'in_attention', 'closed');

create table public.alerts (
  id          uuid primary key default gen_random_uuid(),
  student_id  uuid not null references public.students (id) on delete cascade,
  group_id    uuid not null references public.groups (id),
  origin      public.alert_origin not null,
  level       public.alert_level not null,
  status      public.alert_status not null default 'open',
  reason_code text not null,                      -- 'difficult_emotions_streak', later 'self_harm', ...
  details     jsonb not null default '{}'::jsonb check (jsonb_typeof(details) = 'object'),  -- counts only, no text
  attended_by uuid references public.profiles (id),
  opened_at   timestamptz not null default now(),
  closed_at   timestamptz,
  updated_at  timestamptz not null default now(),
  constraint alerts_closed_at check ((status = 'closed') = (closed_at is not null))
);

-- Only ONE open (or in attention) alert per student and reason
create unique index alerts_one_active_per_reason
  on public.alerts (student_id, reason_code)
  where status <> 'closed';

create index alerts_group_id_idx on public.alerts (group_id);

create trigger alerts_set_updated_at
  before update on public.alerts
  for each row execute function private.set_updated_at();

-- When the status changes: who attended (from the session), closed_at (server time), no reopening
create or replace function private.on_alert_status_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status is distinct from old.status then
    if old.status = 'closed' then
      raise exception 'ALERT_ALREADY_CLOSED' using errcode = '23514';
    end if;
    new.attended_by := coalesce((select auth.uid()), new.attended_by);
    new.closed_at   := case when new.status = 'closed' then now() else null end;
  end if;
  return new;
end;
$$;

create trigger alerts_status_change
  before update of status on public.alerts
  for each row execute function private.on_alert_status_change();

alter table public.alerts enable row level security;

revoke all on public.alerts from anon;
-- Alerts are created only by the detection job (or Edge Functions). Staff can only change the status.
revoke insert, update, delete on public.alerts from authenticated;
grant update (status) on public.alerts to authenticated;

-- Teacher: alerts of their groups; may attend/close those that do NOT come from the AI chat
create policy alerts_select_teacher on public.alerts
  for select to authenticated
  using (private.is_teacher_of_group(group_id));

create policy alerts_update_teacher on public.alerts
  for update to authenticated
  using (private.is_teacher_of_group(group_id) and origin <> 'chat')
  with check (private.is_teacher_of_group(group_id) and origin <> 'chat');

-- Counselor / director: alerts of their school (including chat ones, later with the minimal excerpt)
create policy alerts_select_school_leaders on public.alerts
  for select to authenticated
  using (exists (
    select 1 from public.groups g
    where g.id = alerts.group_id
      and private.is_staff_of_school(g.school_id, array['counselor','director']::public.app_role[])));

create policy alerts_update_school_leaders on public.alerts
  for update to authenticated
  using (exists (
    select 1 from public.groups g
    where g.id = alerts.group_id
      and private.is_staff_of_school(g.school_id, array['counselor','director']::public.app_role[])))
  with check (exists (
    select 1 from public.groups g
    where g.id = alerts.group_id
      and private.is_staff_of_school(g.school_id, array['counselor','director']::public.app_role[])));

-- Returns how many NEW alerts were created
create or replace function private.detect_support_alerts()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_tz          constant text    := 'America/Managua';
  c_window_days constant integer := 7;    -- look at the last 7 days
  c_min_days    constant integer := 3;    -- difficult emotions on at least 3 distinct days
  c_cooldown    constant interval := interval '7 days';  -- after closing, wait before re-alerting
  c_reason      constant text    := 'difficult_emotions_streak';
  v_today   date := (now() at time zone c_tz)::date;
  v_created integer;
begin
  with candidates as (
    select ec.student_id, s.group_id, count(distinct ec.checkin_date) as difficult_days
    from public.emotion_checkins ec
    join public.students s on s.id = ec.student_id
    join public.groups   g on g.id = s.group_id
    where ec.checkin_date between v_today - (c_window_days - 1) and v_today
      and not ec.prefers_not_to_say                     -- "prefiero no decirlo" never counts
      and ec.emotion in ('sadness', 'fear', 'anger')
      and s.active and g.active
    group by ec.student_id, s.group_id
    having count(distinct ec.checkin_date) >= c_min_days
  ),
  inserted as (
    insert into public.alerts (student_id, group_id, origin, level, reason_code, details)
    select c.student_id, c.group_id, 'checkin', 'support', c_reason,
           jsonb_build_object('difficult_days', c.difficult_days, 'window_days', c_window_days)
    from candidates c
    where not exists (                                   -- cooldown after a recently closed alert
      select 1 from public.alerts a
      where a.student_id = c.student_id
        and a.reason_code = c_reason
        and a.closed_at > now() - c_cooldown)
    on conflict (student_id, reason_code) where status <> 'closed' do nothing
    returning 1
  )
  select count(*) into v_created from inserted;

  return v_created;
end;
$$;

-- pg_cron: run every night at 05:00 UTC = 11:00 p. m. in Nicaragua
create extension if not exists pg_cron with schema pg_catalog;
grant usage on schema cron to postgres;

select cron.schedule(
  'detect-support-alerts',
  '0 5 * * *',
  $$select private.detect_support_alerts();$$
);

