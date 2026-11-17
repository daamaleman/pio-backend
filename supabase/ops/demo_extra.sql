-- ============================================================
-- demo_extra.sql — EXTRA DEMO DATA, STAGING ONLY. Never run in production.
-- Run in the SQL Editor AFTER `db reset --remote` and AFTER smoke_demo.sql
-- (it adds rows, so the smoke test numbers stop matching).
--
-- One transaction: if any line fails, nothing is saved.
-- It refuses to run twice (checks for the first extra student).
-- Everything goes through the real RPCs (sync_progress, submit_poll, add_observation…),
-- acting as each student or teacher, so the same rules as the apps apply.
--
-- Adds:
--   3.º A (Ana)      8 students · lesson 1 last week · check-ins · family sheets and consents
--   1.er A (Ana)     4 students · lesson s1-w1 progress · poll · self-assessment · anonymous questions
--   Bluefields (Luis) 4 students · lesson s1-w1 assigned and played · poll · questions in English
--   3.º B            Monday check-ins · family sheets (app + paper) · consents · self-assessment
--   Alerts           help requests, one in attention, a teacher referral, a chat risk, closed history
--   Observations     notes from Ana and Luis
-- New PINs are listed at the end of this file.
-- ============================================================

begin;

-- ---------- Guard: run only once ----------
do $$
begin
  if exists (select 1 from public.students where id = '30000000-0000-4000-8000-000000000101') then
    raise exception 'DEMO_EXTRA_ALREADY_APPLIED: run db reset --remote first if you want to load it again';
  end if;
end;
$$;

-- ---------- Helpers (dropped at the end) ----------
create function private.demo_as_student(p_student uuid)
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object(
            'sub', gen_random_uuid(), 'role', 'authenticated', 'app_role', 'student',
            'student_id', s.id, 'group_id', s.group_id, 'level', g.level)::text, true)
  from public.students s join public.groups g on g.id = s.group_id
  where s.id = p_student;
end;
$$;

create function private.demo_as_staff(p_profile uuid)
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object(
            'sub', p.id, 'role', 'authenticated', 'app_role', p.role)::text, true)
  from public.profiles p where p.id = p_profile;
end;
$$;

create function private.demo_at(p_day date, p_hour int)
returns timestamptz language sql as $$
  select (p_day::timestamp + make_interval(hours => p_hour)) at time zone 'America/Managua';
$$;

-- Steps 1..p_upto completed, with optional metrics per position
create function private.demo_lesson(p_slug text, p_upto int, p_ts timestamptz, p_metrics jsonb)
returns jsonb language sql as $$
  select jsonb_build_object('lessons', jsonb_build_array(jsonb_build_object(
           'lesson_slug', p_slug,
           'current_position', p_upto,
           'steps', coalesce((
             select jsonb_agg(
                      jsonb_build_object('position', n, 'status', 'completed',
                                         'device_updated_at', p_ts + make_interval(mins => 3 * n))
                      || case when p_metrics ? n::text
                              then jsonb_build_object('metrics', p_metrics -> n::text)
                              else '{}'::jsonb end
                      order by n)
             from generate_series(1, p_upto) as n), '[]'::jsonb))));
$$;

create function private.demo_sync(p_student uuid, p_payload jsonb)
returns void language plpgsql as $$
begin
  perform private.demo_as_student(p_student);
  perform public.sync_progress(p_payload);
end;
$$;

create function private.demo_checkin(p_student uuid, p_date date, p_emotion text, p_intensity text, p_scale int)
returns void language plpgsql as $$
begin
  perform private.demo_sync(p_student, jsonb_build_object('checkins', jsonb_build_array(
    jsonb_strip_nulls(jsonb_build_object('date', p_date, 'emotion', p_emotion,
                                         'intensity', p_intensity, 'scale_1_5', p_scale)))));
end;
$$;

-- ---------- New students (same as the seed: no auth user until first login) ----------
insert into public.students (id, group_id, display_name) values
  -- 3.º A (Ana, primary)
  ('30000000-0000-4000-8000-000000000101', '20000000-0000-4000-8000-000000000002', 'Andrea Mejía'),
  ('30000000-0000-4000-8000-000000000102', '20000000-0000-4000-8000-000000000002', 'Gabriel Ortega'),
  ('30000000-0000-4000-8000-000000000103', '20000000-0000-4000-8000-000000000002', 'Ximena Duarte'),
  ('30000000-0000-4000-8000-000000000104', '20000000-0000-4000-8000-000000000002', 'Ángel Morales'),
  ('30000000-0000-4000-8000-000000000105', '20000000-0000-4000-8000-000000000002', 'Paola Reyes'),
  ('30000000-0000-4000-8000-000000000106', '20000000-0000-4000-8000-000000000002', 'Bryan Zeledón'),
  ('30000000-0000-4000-8000-000000000107', '20000000-0000-4000-8000-000000000002', 'Nicole Vargas'),
  ('30000000-0000-4000-8000-000000000108', '20000000-0000-4000-8000-000000000002', 'Emilio Chávez'),
  -- 1.er año A (Ana, secondary, chat on)
  ('30000000-0000-4000-8000-000000000111', '20000000-0000-4000-8000-000000000003', 'Alejandra Montoya'),
  ('30000000-0000-4000-8000-000000000112', '20000000-0000-4000-8000-000000000003', 'Ricardo Solórzano'),
  ('30000000-0000-4000-8000-000000000113', '20000000-0000-4000-8000-000000000003', 'Mariela Dávila'),
  ('30000000-0000-4000-8000-000000000114', '20000000-0000-4000-8000-000000000003', 'Kenneth Arróliga'),
  -- Year 1 A (Luis, Bluefields, English)
  ('30000000-0000-4000-8000-000000000121', '20000000-0000-4000-8000-000000000004', 'Keisha Hodgson'),
  ('30000000-0000-4000-8000-000000000122', '20000000-0000-4000-8000-000000000004', 'Brandon Downs'),
  ('30000000-0000-4000-8000-000000000123', '20000000-0000-4000-8000-000000000004', 'Shanice Forbes'),
  ('30000000-0000-4000-8000-000000000124', '20000000-0000-4000-8000-000000000004', 'Darwin Cayasso');

insert into private.student_credentials (student_id, pin_hash)
select v.student_id, extensions.crypt(v.pin, extensions.gen_salt('bf', 10))
from (values
  ('30000000-0000-4000-8000-000000000101'::uuid, '4172'),
  ('30000000-0000-4000-8000-000000000102'::uuid, '5823'),
  ('30000000-0000-4000-8000-000000000103'::uuid, '6394'),
  ('30000000-0000-4000-8000-000000000104'::uuid, '7215'),
  ('30000000-0000-4000-8000-000000000105'::uuid, '8436'),
  ('30000000-0000-4000-8000-000000000106'::uuid, '9157'),
  ('30000000-0000-4000-8000-000000000107'::uuid, '2768'),
  ('30000000-0000-4000-8000-000000000108'::uuid, '3489'),
  ('30000000-0000-4000-8000-000000000111'::uuid, '1904'),
  ('30000000-0000-4000-8000-000000000112'::uuid, '5530'),
  ('30000000-0000-4000-8000-000000000113'::uuid, '2087'),
  ('30000000-0000-4000-8000-000000000114'::uuid, '6619'),
  ('30000000-0000-4000-8000-000000000121'::uuid, '3302'),
  ('30000000-0000-4000-8000-000000000122'::uuid, '4471'),
  ('30000000-0000-4000-8000-000000000123'::uuid, '8820'),
  ('30000000-0000-4000-8000-000000000124'::uuid, '1196')
) as v(student_id, pin);

-- ---------- New assignments (same date rule as the seed) ----------
-- 3.º A: lesson 1 LAST week (this week's lesson stays free to assign live in the demo).
-- Bluefields: s1-w1 THIS week.
with today as (select (now() at time zone 'America/Managua')::date as d),
base as (
  select g.id as group_id, g.teacher_id,
         t.d - ((extract(isodow from t.d)::int - g.class_weekday + 7) % 7) as last_class
  from public.groups g cross join today t
)
insert into public.assignments
  (group_id, lesson_id, assigned_by, class_date, due_date, message, targets_all, notify_families, remind_day_before)
select b.group_id, l.id, b.teacher_id,
       b.last_class + v.week_offset * 7,
       b.last_class + v.week_offset * 7 + 7,
       v.message, true, v.notify_families, true
from (values
  ('3AAN35', 'p3-w1', -1, '¡Hola, chavalos! Esta semana conocemos las gotas de las emociones.', true),
  ('1ALU58', 's1-w1',  0, 'This week we talk about changes. Everyone at their own pace.',       false)
) as v(class_code, lesson_slug, week_offset, message, notify_families)
join public.groups  g on g.class_code = v.class_code
join base           b on b.group_id = g.id
join public.lessons l on l.slug = v.lesson_slug;

-- ============================================================
-- Activity, acting as each student and teacher
-- ============================================================
do $$
declare
  ana   constant uuid := 'a0000000-0000-4000-8000-000000000001';
  luis  constant uuid := 'a0000000-0000-4000-8000-000000000002';
  marta constant uuid := 'a0000000-0000-4000-8000-000000000004';
  v_today  date := (now() at time zone 'America/Managua')::date;
  v_monday date := v_today - (extract(isodow from v_today)::int - 1);
  t_prev   timestamptz := private.demo_at(v_monday - 10, 16);   -- last week's homework
  t_now    timestamptz := least(now() - interval '1 hour', private.demo_at(v_monday, 17));
  m_p3w1   jsonb;
  l_p3w1   uuid := (select id from public.lessons where slug = 'p3-w1');
  l_s1w1   uuid := (select id from public.lessons where slug = 's1-w1');
  q        record;
  s        uuid;
begin
  -- ----- 3.º A: lesson 1 (6 completed, 1 halfway, 1 not started) -----
  m_p3w1 := '{"6":{"distinct_emotions_correct":4,"total":4},"7":{"emotions_mapped":4,"total":4}}';
  perform private.demo_sync('30000000-0000-4000-8000-000000000101', private.demo_lesson('p3-w1', 12, t_prev, m_p3w1));
  perform private.demo_sync('30000000-0000-4000-8000-000000000102', private.demo_lesson('p3-w1', 12, t_prev, '{"6":{"distinct_emotions_correct":3,"total":4},"7":{"emotions_mapped":4,"total":4}}'));
  perform private.demo_sync('30000000-0000-4000-8000-000000000103', private.demo_lesson('p3-w1', 12, t_prev, m_p3w1));
  perform private.demo_sync('30000000-0000-4000-8000-000000000104', private.demo_lesson('p3-w1', 12, t_prev, '{"6":{"distinct_emotions_correct":2,"total":4},"7":{"emotions_mapped":2,"total":4}}'));
  perform private.demo_sync('30000000-0000-4000-8000-000000000105', private.demo_lesson('p3-w1', 12, t_prev, m_p3w1));
  perform private.demo_sync('30000000-0000-4000-8000-000000000107', private.demo_lesson('p3-w1', 12, t_prev, '{"6":{"distinct_emotions_correct":4,"total":4},"7":{"emotions_mapped":3,"total":4}}'));
  perform private.demo_sync('30000000-0000-4000-8000-000000000106', private.demo_lesson('p3-w1', 7, t_prev, '{"6":{"distinct_emotions_correct":2,"total":4}}'));

  -- ----- 1.er año A and Bluefields: s1-w1 -----
  perform private.demo_sync('30000000-0000-4000-8000-000000000005', private.demo_lesson('s1-w1', 13, t_now, '{"8":{"correct":8,"total":10},"9":{"items_completed":2,"total":2}}'));
  perform private.demo_sync('30000000-0000-4000-8000-000000000111', private.demo_lesson('s1-w1', 13, t_now, '{"8":{"correct":9,"total":10},"9":{"items_completed":2,"total":2}}'));
  perform private.demo_sync('30000000-0000-4000-8000-000000000112', private.demo_lesson('s1-w1', 13, t_now, '{"8":{"correct":6,"total":10},"9":{"items_completed":1,"total":2}}'));
  perform private.demo_sync('30000000-0000-4000-8000-000000000113', private.demo_lesson('s1-w1', 9,  t_now, '{"8":{"correct":7,"total":10}}'));
  perform private.demo_sync('30000000-0000-4000-8000-000000000114', private.demo_lesson('s1-w1', 3,  t_now, '{}'));

  perform private.demo_sync('30000000-0000-4000-8000-000000000006', private.demo_lesson('s1-w1', 13, t_now, '{"8":{"correct":7,"total":10},"9":{"items_completed":2,"total":2}}'));
  perform private.demo_sync('30000000-0000-4000-8000-000000000121', private.demo_lesson('s1-w1', 13, t_now, '{"8":{"correct":10,"total":10},"9":{"items_completed":2,"total":2}}'));
  perform private.demo_sync('30000000-0000-4000-8000-000000000122', private.demo_lesson('s1-w1', 13, t_now, '{"8":{"correct":5,"total":10},"9":{"items_completed":2,"total":2}}'));
  perform private.demo_sync('30000000-0000-4000-8000-000000000123', private.demo_lesson('s1-w1', 8,  t_now, '{"8":{"correct":4,"total":10}}'));

  -- ----- Check-ins this week (at most one difficult day per student: no new streak alerts) -----
  -- 3.º B, Monday
  perform private.demo_checkin('30000000-0000-4000-8000-000000000001', v_monday, 'calm', 'quite', null);
  perform private.demo_checkin('30000000-0000-4000-8000-000000000003', v_monday, 'joy',  'a_lot', null);
  perform private.demo_checkin('30000000-0000-4000-8000-000000000007', v_monday, 'love', 'quite', null);
  perform private.demo_checkin('30000000-0000-4000-8000-000000000008', v_monday, 'joy',  'quite', null);
  perform private.demo_checkin('30000000-0000-4000-8000-000000000011', v_monday, 'fear', 'a_little', null);
  perform private.demo_checkin('30000000-0000-4000-8000-000000000013', v_monday, 'calm', 'quite', null);
  perform private.demo_checkin('30000000-0000-4000-8000-000000000015', v_monday, 'joy',  'quite', null);
  -- 3.º A, today
  perform private.demo_checkin('30000000-0000-4000-8000-000000000101', v_today, 'joy',     'a_lot',    null);
  perform private.demo_checkin('30000000-0000-4000-8000-000000000102', v_today, 'calm',    'quite',    null);
  perform private.demo_checkin('30000000-0000-4000-8000-000000000103', v_today, 'love',    'quite',    null);
  perform private.demo_checkin('30000000-0000-4000-8000-000000000104', v_today, 'sadness', 'a_little', null);
  perform private.demo_checkin('30000000-0000-4000-8000-000000000105', v_today, 'joy',     'quite',    null);
  perform private.demo_checkin('30000000-0000-4000-8000-000000000107', v_today, 'calm',    'a_little', null);
  perform private.demo_checkin('30000000-0000-4000-8000-000000000108', v_today, 'joy',     'quite',    null);
  -- 1.er año A, today (secondary: emotion + "¿cómo llegás hoy?" 1–5)
  perform private.demo_checkin('30000000-0000-4000-8000-000000000005', v_today, 'joy',     null, 4);
  perform private.demo_checkin('30000000-0000-4000-8000-000000000111', v_today, 'calm',    null, 4);
  perform private.demo_checkin('30000000-0000-4000-8000-000000000112', v_today, 'anger',   null, 2);
  perform private.demo_checkin('30000000-0000-4000-8000-000000000113', v_today, 'love',    null, 5);
  perform private.demo_checkin('30000000-0000-4000-8000-000000000114', v_today, 'sadness', null, 2);
  -- Bluefields, today
  perform private.demo_checkin('30000000-0000-4000-8000-000000000006', v_today, 'joy',  null, 4);
  perform private.demo_checkin('30000000-0000-4000-8000-000000000121', v_today, 'calm', null, 5);
  perform private.demo_checkin('30000000-0000-4000-8000-000000000122', v_today, 'fear', null, 3);
  perform private.demo_checkin('30000000-0000-4000-8000-000000000123', v_today, 'joy',  null, 4);
  perform private.demo_checkin('30000000-0000-4000-8000-000000000124', v_today, 'love', null, 4);

  -- ----- Family consents (version 2026-11) -----
  foreach s in array array[
    '30000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000002', '30000000-0000-4000-8000-000000000003',
    '30000000-0000-4000-8000-000000000007', '30000000-0000-4000-8000-000000000008', '30000000-0000-4000-8000-000000000009',
    '30000000-0000-4000-8000-000000000010', '30000000-0000-4000-8000-000000000011', '30000000-0000-4000-8000-000000000013',
    '30000000-0000-4000-8000-000000000101', '30000000-0000-4000-8000-000000000102', '30000000-0000-4000-8000-000000000103',
    '30000000-0000-4000-8000-000000000105', '30000000-0000-4000-8000-000000000005', '30000000-0000-4000-8000-000000000111',
    '30000000-0000-4000-8000-000000000112', '30000000-0000-4000-8000-000000000113', '30000000-0000-4000-8000-000000000121',
    '30000000-0000-4000-8000-000000000122']::uuid[]
  loop
    perform private.demo_as_student(s);
    perform public.record_family_consent('2026-11', true);
  end loop;
  perform private.demo_as_student('30000000-0000-4000-8000-000000000012');
  perform public.record_family_consent('2026-11', false);   -- one family withdrew

  -- ----- Family sheets for lesson 1 (primary only): in the app -----
  perform private.demo_as_student('30000000-0000-4000-8000-000000000001');
  perform public.submit_family_sheet('p3-w1', 'yes', 'interest', 'joy', 'Le gustó mucho dibujar las gotas con su hermanito.');
  perform private.demo_as_student('30000000-0000-4000-8000-000000000003');
  perform public.submit_family_sheet('p3-w1', 'yes', 'interest', 'calm', null);
  perform private.demo_as_student('30000000-0000-4000-8000-000000000007');
  perform public.submit_family_sheet('p3-w1', 'partly', 'interest', 'love', 'Lo hicimos en la noche, estaba cansada.');
  perform private.demo_as_student('30000000-0000-4000-8000-000000000009');
  perform public.submit_family_sheet('p3-w1', 'yes', 'difficulty', 'fear', 'Le costó hablar del miedo, pero lo intentó.');
  perform private.demo_as_student('30000000-0000-4000-8000-000000000011');
  perform public.submit_family_sheet('p3-w1', 'yes', 'interest', 'joy', null);
  perform private.demo_as_student('30000000-0000-4000-8000-000000000013');
  perform public.submit_family_sheet('p3-w1', 'partly', 'declined', null, null);
  perform private.demo_as_student('30000000-0000-4000-8000-000000000101');
  perform public.submit_family_sheet('p3-w1', 'yes', 'interest', 'joy', '¡Nos reímos mucho!');
  perform private.demo_as_student('30000000-0000-4000-8000-000000000103');
  perform public.submit_family_sheet('p3-w1', 'yes', 'interest', 'love', null);

  -- ... and on paper, entered by Ana
  perform private.demo_as_staff(ana);
  perform public.record_family_sheet('30000000-0000-4000-8000-000000000008', l_p3w1, 'yes', 'interest', 'calm', 'Ficha devuelta en papel.');
  perform public.record_family_sheet('30000000-0000-4000-8000-000000000010', l_p3w1, 'partly', 'difficulty', 'anger', null);
  perform public.record_family_sheet('30000000-0000-4000-8000-000000000102', l_p3w1, 'yes', 'interest', null, null);

  -- ----- Self-assessment of the month -----
  foreach s in array array[
    '30000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000003', '30000000-0000-4000-8000-000000000007',
    '30000000-0000-4000-8000-000000000008', '30000000-0000-4000-8000-000000000009', '30000000-0000-4000-8000-000000000011',
    '30000000-0000-4000-8000-000000000012', '30000000-0000-4000-8000-000000000013', '30000000-0000-4000-8000-000000000014']::uuid[]
  loop
    perform private.demo_as_student(s);
    perform public.submit_self_assessment('start', jsonb_build_object(
      'name_emotions', 1 + (get_byte(decode(md5(s::text || 'a'), 'hex'), 0) % 2),
      'calm_down',     1 + (get_byte(decode(md5(s::text || 'b'), 'hex'), 0) % 2),
      'treat_well',    2 + (get_byte(decode(md5(s::text || 'c'), 'hex'), 0) % 2),
      'ask_for_help',  1 + (get_byte(decode(md5(s::text || 'd'), 'hex'), 0) % 3)));
  end loop;
  foreach s in array array[
    '30000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000003', '30000000-0000-4000-8000-000000000007',
    '30000000-0000-4000-8000-000000000009', '30000000-0000-4000-8000-000000000013']::uuid[]
  loop
    perform private.demo_as_student(s);
    perform public.submit_self_assessment('end', jsonb_build_object(
      'name_emotions', 3, 'calm_down', 2 + (get_byte(decode(md5(s::text || 'e'), 'hex'), 0) % 2),
      'treat_well', 3, 'ask_for_help', 2 + (get_byte(decode(md5(s::text || 'f'), 'hex'), 0) % 2)));
  end loop;
  foreach s in array array[
    '30000000-0000-4000-8000-000000000005', '30000000-0000-4000-8000-000000000111', '30000000-0000-4000-8000-000000000112',
    '30000000-0000-4000-8000-000000000113', '30000000-0000-4000-8000-000000000114']::uuid[]
  loop
    perform private.demo_as_student(s);
    perform public.submit_self_assessment('start', jsonb_build_object(
      'understand_feel', 1 + (get_byte(decode(md5(s::text || 'g'), 'hex'), 0) % 3),
      'safe_online',     2 + (get_byte(decode(md5(s::text || 'h'), 'hex'), 0) % 2),
      'say_no',          1 + (get_byte(decode(md5(s::text || 'i'), 'hex'), 0) % 2),
      'support_network', 1 + (get_byte(decode(md5(s::text || 'j'), 'hex'), 0) % 3)));
  end loop;

  -- ----- Anonymous poll of s1-w1 (Daniela is left out so the demo shows it fresh) -----
  perform private.demo_as_student('30000000-0000-4000-8000-000000000005');  perform public.submit_poll('s1-w1', 'si');
  perform private.demo_as_student('30000000-0000-4000-8000-000000000111');  perform public.submit_poll('s1-w1', 'si');
  perform private.demo_as_student('30000000-0000-4000-8000-000000000112');  perform public.submit_poll('s1-w1', 'a_veces');
  perform private.demo_as_student('30000000-0000-4000-8000-000000000113');  perform public.submit_poll('s1-w1', 'si');
  perform private.demo_as_student('30000000-0000-4000-8000-000000000114');  perform public.submit_poll('s1-w1', 'no');
  perform private.demo_as_student('30000000-0000-4000-8000-000000000006');  perform public.submit_poll('s1-w1', 'a_veces');
  perform private.demo_as_student('30000000-0000-4000-8000-000000000121');  perform public.submit_poll('s1-w1', 'si');
  perform private.demo_as_student('30000000-0000-4000-8000-000000000122');  perform public.submit_poll('s1-w1', 'si');
  perform private.demo_as_student('30000000-0000-4000-8000-000000000123');  perform public.submit_poll('s1-w1', 'no');

  -- ----- Anonymous questions -----
  perform private.demo_as_student('30000000-0000-4000-8000-000000000005');
  perform public.submit_anonymous_question('s1-w1', '¿Es normal sentirse triste algunos días sin saber por qué?');
  perform private.demo_as_student('30000000-0000-4000-8000-000000000111');
  perform public.submit_anonymous_question('s1-w1', '¿Cómo le digo a mi mamá que me siento mal sin que se preocupe mucho?');
  perform private.demo_as_student('30000000-0000-4000-8000-000000000112');
  perform public.submit_anonymous_question('s1-w1', '¿Por qué a veces me enojo por cosas pequeñas?');
  perform private.demo_as_student('30000000-0000-4000-8000-000000000113');
  perform public.submit_anonymous_question('s1-w1', '¿Qué hago si alguien me presiona para mandar fotos?');
  perform private.demo_as_student('30000000-0000-4000-8000-000000000114');
  perform public.submit_anonymous_question('s1-w1', 'jajaja hola profe');
  perform private.demo_as_student('30000000-0000-4000-8000-000000000121');
  perform public.submit_anonymous_question('s1-w1', 'Is it normal to feel nervous all the time before tests?');
  perform private.demo_as_student('30000000-0000-4000-8000-000000000122');
  perform public.submit_anonymous_question('s1-w1', 'How can I help a friend who is always sad?');

  perform private.demo_as_staff(ana);
  for q in select id, body from public.anonymous_questions
           where body in ('¿Es normal sentirse triste algunos días sin saber por qué?',
                          '¿Por qué a veces me enojo por cosas pequeñas?', 'jajaja hola profe')
  loop
    perform public.set_question_status(q.id, case when q.body = 'jajaja hola profe' then 'hidden' else 'answered' end);
  end loop;
  perform private.demo_as_staff(luis);
  perform public.set_question_status(
    (select id from public.anonymous_questions where body = 'Is it normal to feel nervous all the time before tests?'), 'answered');

  -- ----- Teacher observations (one asks counseling for support) -----
  perform private.demo_as_staff(ana);
  perform public.add_observation('30000000-0000-4000-8000-000000000010', 'social',
    'En el recreo se enojó con dos compañeros y luego se quedó aparte. Conversamos y se calmó con el semáforo.',
    l_p3w1, v_today - 3, true);
  perform public.add_observation('30000000-0000-4000-8000-000000000008', 'participation',
    'Hoy participó mucho en el juego de las gotas y ayudó a un compañero.', l_p3w1, v_today - 8, false);
  perform public.add_observation('30000000-0000-4000-8000-000000000011', 'emotional',
    'Comentó que le da miedo la oscuridad. Le propuse practicar la respiración en casa.', null, v_today - 1, false);
  perform public.add_observation('30000000-0000-4000-8000-000000000104', 'learning',
    'Le costó identificar el miedo en el juego. Repasar con láminas la próxima clase.', l_p3w1, v_today - 6, false);
  perform public.add_observation('30000000-0000-4000-8000-000000000112', 'emotional',
    'Llegó molesto después del receso. Hablamos un momento y se integró al grupo.', l_s1w1, v_today, false);
  perform private.demo_as_staff(luis);
  perform public.add_observation('30000000-0000-4000-8000-000000000122', 'participation',
    'Very engaged in the myths and truths game; helped explain the answers to the group.', l_s1w1, v_today - 1, false);

  -- ----- Help requests ("Quiero hablar con alguien") -----
  perform private.demo_as_student('30000000-0000-4000-8000-000000000005');   -- José → teacher
  perform public.request_help('teacher');
  perform private.demo_as_student('30000000-0000-4000-8000-000000000113');   -- Mariela → counseling (teachers don't see it)
  perform public.request_help('counselor');
  perform private.demo_as_student('30000000-0000-4000-8000-000000000101');   -- Andrea (3.º A) → teacher
  perform public.request_help('teacher');

  -- Ana is already handling José's request
  perform private.demo_as_staff(ana);
  update public.alerts set status = 'in_attention'
  where student_id = '30000000-0000-4000-8000-000000000005' and reason_code = 'help_request';

  -- A risk detected in the "Pío te escucha" chat (only counseling and the principal see it; category only)
  insert into public.alerts (student_id, group_id, origin, level, reason_code, details, opened_at)
  values ('30000000-0000-4000-8000-000000000114', '20000000-0000-4000-8000-000000000003',
          'chat', 'risk_moderate', 'chat_risk', '{"category":"other"}', now() - interval '3 hours');

  -- Closed history (attended and closed in past weeks)
  insert into public.alerts (student_id, group_id, origin, level, status, reason_code, details, attended_by, opened_at, closed_at)
  values
    ('30000000-0000-4000-8000-000000000007', '20000000-0000-4000-8000-000000000001', 'checkin', 'support', 'closed',
     'difficult_emotions_streak', '{"difficult_days":3,"window_days":7}', ana, now() - interval '15 days', now() - interval '13 days'),
    ('30000000-0000-4000-8000-000000000008', '20000000-0000-4000-8000-000000000001', 'help_request', 'support', 'closed',
     'help_request', '{"wants":"teacher"}', ana, now() - interval '9 days', now() - interval '8 days'),
    ('30000000-0000-4000-8000-000000000111', '20000000-0000-4000-8000-000000000003', 'help_request', 'support', 'closed',
     'help_request', '{"wants":"counselor"}', marta, now() - interval '6 days', now() - interval '5 days');

  perform set_config('request.jwt.claims', '', true);
  perform private.detect_support_alerts();
end;
$$;

-- ---------- Clean up the helpers ----------
drop function private.demo_checkin(uuid, date, text, text, int);
drop function private.demo_sync(uuid, jsonb);
drop function private.demo_lesson(text, int, timestamptz, jsonb);
drop function private.demo_at(date, int);
drop function private.demo_as_staff(uuid);
drop function private.demo_as_student(uuid);

-- ---------- What the demo has now (every row should show a number > 0) ----------
select 'Estudiantes' as dato, count(*) as total from public.students
union all select 'Asignaciones', count(*) from public.assignments
union all select 'Lecciones terminadas', count(*) from public.lesson_progress where status = 'completed'
union all select 'Check-ins', count(*) from public.emotion_checkins
union all select 'Alertas activas', count(*) from public.alerts where status <> 'closed'
union all select 'Alertas cerradas', count(*) from public.alerts where status = 'closed'
union all select 'Observaciones', count(*) from public.teacher_observations
union all select 'Preguntas anónimas', count(*) from public.anonymous_questions
union all select 'Fichas de familia', count(*) from public.family_sheets
union all select 'Permisos de familia', count(*) from public.family_consents
union all select 'Autoevaluaciones', count(*) from public.self_assessments
union all select 'Votos en encuestas', count(*) from private.poll_responses
union all select 'Sellos ganados', count(*) from public.student_badges
union all select 'Flores en jardines', count(*) from public.garden_items;

commit;

-- ============================================================
-- New PINs (all fictitious)
--   3.º A  (3AAN35): Andrea Mejía 4172 · Gabriel Ortega 5823 · Ximena Duarte 6394 · Ángel Morales 7215
--                    Paola Reyes 8436 · Bryan Zeledón 9157 · Nicole Vargas 2768 · Emilio Chávez 3489
--   1.er A (1AAN46): Alejandra Montoya 1904 · Ricardo Solórzano 5530 · Mariela Dávila 2087 · Kenneth Arróliga 6619
--   Bluefields (1ALU58): Keisha Hodgson 3302 · Brandon Downs 4471 · Shanice Forbes 8820 · Darwin Cayasso 1196
-- ============================================================
