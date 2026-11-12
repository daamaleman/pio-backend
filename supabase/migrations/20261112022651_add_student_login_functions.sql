-- ============================================================
-- Migration: DB functions used by the student-login Edge Function
-- (callable ONLY with service_role)
-- ============================================================

create table private.rate_limits (
  key          text primary key,                 -- e.g. 'resolve:203.0.113.5'
  window_start timestamptz not null default now(),
  hits         integer not null default 0
);
alter table private.rate_limits enable row level security;

-- Returns true if the request is allowed, false if the limit was exceeded
create or replace function public.check_rate_limit(p_key text, p_max integer, p_window_seconds integer)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hits integer;
begin
  insert into private.rate_limits as rl (key, window_start, hits)
  values (p_key, now(), 1)
  on conflict (key) do update
    set hits = case
                 when rl.window_start < now() - make_interval(secs => p_window_seconds) then 1
                 else rl.hits + 1
               end,
        window_start = case
                 when rl.window_start < now() - make_interval(secs => p_window_seconds) then now()
                 else rl.window_start
               end
  returning hits into v_hits;

  return v_hits <= p_max;
end;
$$;

-- Normalizes the code ("4b · ana · 27" → "4BANA27") and returns the group + active student list
create or replace function public.resolve_class_code(p_class_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_code  text;
  v_group record;
begin
  v_code := regexp_replace(upper(coalesce(p_class_code, '')), '[^A-Z0-9]', '', 'g');

  select g.id, g.level, g.grade, g.section, g.language
    into v_group
  from public.groups g
  where g.class_code = v_code and g.active;

  if not found then
    return null;
  end if;

  return jsonb_build_object(
    'group_id', v_group.id,
    'level',    v_group.level,
    'grade',    v_group.grade,
    'section',  v_group.section,
    'language', v_group.language,
    'students', coalesce((
      select jsonb_agg(
               jsonb_build_object('id', s.id, 'display_name', s.display_name, 'avatar_key', s.avatar_key)
               order by s.display_name)
      from public.students s
      where s.group_id = v_group.id and s.active
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.verify_student_pin(p_group_id uuid, p_student_id uuid, p_pin text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  c_max_attempts constant integer  := 5;
  c_lock         constant interval := interval '5 minutes';
  v_student record;
  v_cred    private.student_credentials%rowtype;
begin
  -- 1. The student must belong to that group, and both must be active
  select s.id, s.auth_user_id, g.level
    into v_student
  from public.students s
  join public.groups g on g.id = s.group_id
  where s.id = p_student_id and s.group_id = p_group_id
    and s.active and g.active;

  if not found then
    return jsonb_build_object('ok', false, 'code', 'STUDENT_NOT_FOUND');
  end if;

  -- 2. PIN format: 4 digits (image PINs are also sent as 4 digits by the app)
  if p_pin is null or p_pin !~ '^[0-9]{4}$' then
    return jsonb_build_object('ok', false, 'code', 'INVALID_PIN_FORMAT');
  end if;

  -- 3. Lock the credentials row until this transaction ends
  select * into v_cred
  from private.student_credentials
  where student_id = p_student_id
  for update;

  if not found then
    return jsonb_build_object('ok', false, 'code', 'PIN_NOT_SET');
  end if;

  -- 4. Currently locked?
  if v_cred.locked_until is not null and v_cred.locked_until > now() then
    return jsonb_build_object(
      'ok', false, 'code', 'PIN_LOCKED',
      'retry_after_seconds', ceil(extract(epoch from v_cred.locked_until - now()))::integer
    );
  end if;

  -- 5. Correct PIN → reset counters
  if v_cred.pin_hash = extensions.crypt(p_pin, v_cred.pin_hash) then
    update private.student_credentials
    set failed_pin_attempts = 0, locked_until = null
    where student_id = p_student_id;

    return jsonb_build_object(
      'ok', true,
      'student_id',   v_student.id,
      'auth_user_id', v_student.auth_user_id,
      'level',        v_student.level
    );
  end if;

  -- 6. Wrong PIN → count, and lock when reaching the limit
  if v_cred.failed_pin_attempts + 1 >= c_max_attempts then
    update private.student_credentials
    set failed_pin_attempts = 0, locked_until = now() + c_lock
    where student_id = p_student_id;

    return jsonb_build_object(
      'ok', false, 'code', 'PIN_LOCKED',
      'retry_after_seconds', extract(epoch from c_lock)::integer
    );
  end if;

  update private.student_credentials
  set failed_pin_attempts = failed_pin_attempts + 1
  where student_id = p_student_id;

  return jsonb_build_object(
    'ok', false, 'code', 'INVALID_PIN',
    'attempts_left', c_max_attempts - (v_cred.failed_pin_attempts + 1)
  );
end;
$$;

-- These live in public (so the Edge Function can call them via supabase.rpc),
-- but ONLY service_role may execute them.
revoke execute on function
  public.check_rate_limit(text, integer, integer),
  public.resolve_class_code(text),
  public.verify_student_pin(uuid, uuid, text)
from public, anon, authenticated;

grant execute on function
  public.check_rate_limit(text, integer, integer),
  public.resolve_class_code(text),
  public.verify_student_pin(uuid, uuid, text)
to service_role;

