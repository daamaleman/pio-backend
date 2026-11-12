-- ============================================================
-- seed.sql — DEMO DATA FOR LOCAL DEVELOPMENT ONLY. Never run in production.
-- All names are fictitious.
--
-- Staff (password for all: Demo1234!)
--   ana.lopez@demo.pio      teacher   Escuela Rubén Darío (Managua)
--   luis.mendez@demo.pio    teacher   Instituto Nacional de Bluefields
--   rosa.gutierrez@demo.pio director  Escuela Rubén Darío
--   marta.solis@demo.pio    counselor Escuela Rubén Darío
--   admin@demo.pio          admin
--
-- Groups (class code shown as the child sees it) — PINs use digits 1–9 in primary (9-drawing grid)
--   3.° B  primary   Ana   3B·AN·27   12 students:
--          María Rivera 3714 · Carlos Martínez 2589 · Sofía López 1593 · Valeria Gómez 2468
--          Mateo Pérez 1357 · Camila Ruiz 9182 · Diego Castillo 7531 · Lucía Sánchez 4567
--          Javier Torres 8642 · Isabella Rocha 3691 · Samuel Aguilar 5274 · Fernanda Urbina 6813
--   3.° A  primary   Ana   3A·AN·35   (no students)
--   1.er A secondary Ana   1A·AN·46   Daniela Hernández 4826 · José Téllez 7391   (AI chat ON)
--   1.er A secondary Luis  1A·LU·58   Kevin Obando 6240
--
-- Demo story (dates relative to the day the seed runs, Nicaragua time):
--   3.° B: lesson 1 assigned LAST week (10/12 done) · lesson 2 assigned THIS week (5 done, 3 halfway, 4 not started)
--   6 students earned "Me calmo" · today's check-ins for the class climate · Carlos → 1 support alert
-- ============================================================

-- Helper: create a confirmed email/password user in Supabase Auth.
-- pg_temp = temporary schema: this function disappears when the seed finishes.
create function pg_temp.create_demo_user(p_id uuid, p_email text, p_password text)
returns void
language sql
as $$
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change
  ) values (
    '00000000-0000-0000-0000-000000000000', p_id, 'authenticated', 'authenticated', p_email,
    extensions.crypt(p_password, extensions.gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}', '{}', now(), now(),
    '', '', '', ''
  );

  insert into auth.identities (
    id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at
  ) values (
    gen_random_uuid(), p_id, p_id::text,
    jsonb_build_object('sub', p_id::text, 'email', p_email, 'email_verified', true),
    'email', now(), now(), now()
  );
$$;

-- ---------- Schools ----------
insert into public.schools (id, name, department, municipality, region) values
  ('10000000-0000-4000-8000-000000000001', 'Escuela Rubén Darío', 'Managua', 'Managua', 'pacific'),
  ('10000000-0000-4000-8000-000000000002', 'Instituto Nacional de Bluefields',
   'Región Autónoma de la Costa Caribe Sur', 'Bluefields', 'caribbean');

-- ---------- Staff users ----------
select pg_temp.create_demo_user('a0000000-0000-4000-8000-000000000001', 'ana.lopez@demo.pio',      'Demo1234!');
select pg_temp.create_demo_user('a0000000-0000-4000-8000-000000000002', 'luis.mendez@demo.pio',    'Demo1234!');
select pg_temp.create_demo_user('a0000000-0000-4000-8000-000000000003', 'rosa.gutierrez@demo.pio', 'Demo1234!');
select pg_temp.create_demo_user('a0000000-0000-4000-8000-000000000004', 'marta.solis@demo.pio',    'Demo1234!');
select pg_temp.create_demo_user('a0000000-0000-4000-8000-000000000005', 'admin@demo.pio',          'Demo1234!');

insert into public.profiles (id, role, full_name) values
  ('a0000000-0000-4000-8000-000000000001', 'teacher',   'Ana López'),
  ('a0000000-0000-4000-8000-000000000002', 'teacher',   'Luis Méndez'),
  ('a0000000-0000-4000-8000-000000000003', 'director',  'Rosa Gutiérrez'),
  ('a0000000-0000-4000-8000-000000000004', 'counselor', 'Marta Solís'),
  ('a0000000-0000-4000-8000-000000000005', 'admin',     'Equipo Pío');

insert into public.staff_schools (profile_id, school_id) values
  ('a0000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001'),
  ('a0000000-0000-4000-8000-000000000002', '10000000-0000-4000-8000-000000000002'),
  ('a0000000-0000-4000-8000-000000000003', '10000000-0000-4000-8000-000000000001'),
  ('a0000000-0000-4000-8000-000000000004', '10000000-0000-4000-8000-000000000001');

-- ---------- Groups (explicit class codes so the demo is always the same) ----------
insert into public.groups
  (id, school_id, teacher_id, level, grade, section, class_weekday, language, class_code, school_year, ai_chat_enabled)
values
  ('20000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001',
   'a0000000-0000-4000-8000-000000000001', 'primary',   3, 'B', 1, 'es', '3BAN27', 2026, false),
  ('20000000-0000-4000-8000-000000000002', '10000000-0000-4000-8000-000000000001',
   'a0000000-0000-4000-8000-000000000001', 'primary',   3, 'A', 3, 'es', '3AAN35', 2026, false),
  ('20000000-0000-4000-8000-000000000003', '10000000-0000-4000-8000-000000000001',
   'a0000000-0000-4000-8000-000000000001', 'secondary', 1, 'A', 2, 'es', '1AAN46', 2026, true),
  ('20000000-0000-4000-8000-000000000004', '10000000-0000-4000-8000-000000000002',
   'a0000000-0000-4000-8000-000000000002', 'secondary', 1, 'A', 4, 'en', '1ALU58', 2026, false);

-- ---------- Students (no shadow users: student-login creates them on first login) ----------
insert into public.students (id, group_id, display_name) values
  -- 3.° B (12)
  ('30000000-0000-4000-8000-000000000001', '20000000-0000-4000-8000-000000000001', 'María Rivera'),
  ('30000000-0000-4000-8000-000000000002', '20000000-0000-4000-8000-000000000001', 'Carlos Martínez'),
  ('30000000-0000-4000-8000-000000000003', '20000000-0000-4000-8000-000000000001', 'Sofía López'),
  ('30000000-0000-4000-8000-000000000007', '20000000-0000-4000-8000-000000000001', 'Valeria Gómez'),
  ('30000000-0000-4000-8000-000000000008', '20000000-0000-4000-8000-000000000001', 'Mateo Pérez'),
  ('30000000-0000-4000-8000-000000000009', '20000000-0000-4000-8000-000000000001', 'Camila Ruiz'),
  ('30000000-0000-4000-8000-000000000010', '20000000-0000-4000-8000-000000000001', 'Diego Castillo'),
  ('30000000-0000-4000-8000-000000000011', '20000000-0000-4000-8000-000000000001', 'Lucía Sánchez'),
  ('30000000-0000-4000-8000-000000000012', '20000000-0000-4000-8000-000000000001', 'Javier Torres'),
  ('30000000-0000-4000-8000-000000000013', '20000000-0000-4000-8000-000000000001', 'Isabella Rocha'),
  ('30000000-0000-4000-8000-000000000014', '20000000-0000-4000-8000-000000000001', 'Samuel Aguilar'),
  ('30000000-0000-4000-8000-000000000015', '20000000-0000-4000-8000-000000000001', 'Fernanda Urbina'),
  -- 1.er año A (Ana)
  ('30000000-0000-4000-8000-000000000004', '20000000-0000-4000-8000-000000000003', 'Daniela Hernández'),
  ('30000000-0000-4000-8000-000000000005', '20000000-0000-4000-8000-000000000003', 'José Téllez'),
  -- 1.er año A (Luis, Bluefields)
  ('30000000-0000-4000-8000-000000000006', '20000000-0000-4000-8000-000000000004', 'Kevin Obando');

-- ---------- PINs (primary: digits 1–9 only, the design grid has 9 drawings) ----------
insert into private.student_credentials (student_id, pin_hash)
select v.student_id, extensions.crypt(v.pin, extensions.gen_salt('bf', 10))
from (values
  ('30000000-0000-4000-8000-000000000001'::uuid, '3714'),
  ('30000000-0000-4000-8000-000000000002'::uuid, '2589'),
  ('30000000-0000-4000-8000-000000000003'::uuid, '1593'),
  ('30000000-0000-4000-8000-000000000007'::uuid, '2468'),
  ('30000000-0000-4000-8000-000000000008'::uuid, '1357'),
  ('30000000-0000-4000-8000-000000000009'::uuid, '9182'),
  ('30000000-0000-4000-8000-000000000010'::uuid, '7531'),
  ('30000000-0000-4000-8000-000000000011'::uuid, '4567'),
  ('30000000-0000-4000-8000-000000000012'::uuid, '8642'),
  ('30000000-0000-4000-8000-000000000013'::uuid, '3691'),
  ('30000000-0000-4000-8000-000000000014'::uuid, '5274'),
  ('30000000-0000-4000-8000-000000000015'::uuid, '6813'),
  ('30000000-0000-4000-8000-000000000004'::uuid, '4826'),
  ('30000000-0000-4000-8000-000000000005'::uuid, '7391'),
  ('30000000-0000-4000-8000-000000000006'::uuid, '6240')
) as v(student_id, pin);

-- ---------- Assignments (relative to "today" in Managua) ----------
with today as (select (now() at time zone 'America/Managua')::date as d),
base as (
  select g.id as group_id, g.teacher_id,
         t.d - ((extract(isodow from t.d)::int - g.class_weekday + 7) % 7) as last_class
  from public.groups g
  cross join today t
)
insert into public.assignments
  (group_id, lesson_id, assigned_by, class_date, due_date, message, targets_all, notify_families, remind_day_before)
select b.group_id, l.id, b.teacher_id,
       b.last_class + v.week_offset * 7,
       b.last_class + v.week_offset * 7 + 7,
       v.message, true, v.notify_families, true
from (values
  ('3BAN27', 'p3-w1', -1, '¡Hola, chavalos! Esta semana conocemos las gotas de las emociones.', true),
  ('3BAN27', 'p3-w2',  0, 'Esta semana practicamos el semáforo de la calma. ¡Ustedes pueden!', true),
  ('1AAN46', 's1-w1',  0, 'Esta semana hablamos de los cambios. Cada quien a su ritmo.',       false)
) as v(class_code, lesson_slug, week_offset, message, notify_families)
join public.groups  g on g.class_code = v.class_code
join base           b on b.group_id = g.id
join public.lessons l on l.slug = v.lesson_slug
;

-- ============================================================
-- Demo progress: act as each student and call the real sync_progress()
-- ============================================================

create function pg_temp.at_day(p_day date, p_hour int)
returns timestamptz language sql as $$
  select (p_day::timestamp + make_interval(hours => p_hour)) at time zone 'America/Managua';
$$;

create function pg_temp.steps(p_from int, p_to int, p_ts timestamptz, p_metrics jsonb)
returns jsonb language sql as $$
  select coalesce(jsonb_agg(
           jsonb_build_object('position', n, 'status', 'completed',
                              'device_updated_at', p_ts + make_interval(mins => 3 * n))
           || case when p_metrics ? n::text
                   then jsonb_build_object('metrics', p_metrics -> n::text)
                   else '{}'::jsonb end
           order by n), '[]'::jsonb)
  from generate_series(p_from, p_to) as n;
$$;

create function pg_temp.lesson(p_slug text, p_upto int, p_ts timestamptz, p_metrics jsonb)
returns jsonb language sql as $$
  select jsonb_build_object('lessons', jsonb_build_array(jsonb_build_object(
           'lesson_slug', p_slug,
           'current_position', p_upto,
           'steps', pg_temp.steps(1, p_upto, p_ts, p_metrics))));
$$;

create function pg_temp.demo_sync(p_student uuid, p_payload jsonb)
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object(
            'sub', gen_random_uuid(), 'role', 'authenticated', 'app_role', 'student',
            'student_id', s.id, 'group_id', s.group_id, 'level', g.level)::text, true)
  from public.students s
  join public.groups g on g.id = s.group_id
  where s.id = p_student;

  perform public.sync_progress(p_payload);
end;
$$;

do $$
declare
  v_today date := (now() at time zone 'America/Managua')::date;
  v_last date := v_today - ((extract(isodow from v_today)::int - 1 + 7) % 7);
  t1 timestamptz := pg_temp.at_day(v_last - 5, 16);
  t2 timestamptz := pg_temp.at_day(least(v_today, v_last + 1), 15);
begin
  -- Lesson 1: 10 completed, Carlos halfway, Fernanda not started.
  perform pg_temp.demo_sync('30000000-0000-4000-8000-000000000001', pg_temp.lesson('p3-w1', 12, t1, '{"6":{"distinct_emotions_correct":4,"total":4},"7":{"emotions_mapped":4,"total":4}}'));
  perform pg_temp.demo_sync('30000000-0000-4000-8000-000000000003', pg_temp.lesson('p3-w1', 12, t1, '{"6":{"distinct_emotions_correct":4,"total":4},"7":{"emotions_mapped":3,"total":4}}'));
  perform pg_temp.demo_sync('30000000-0000-4000-8000-000000000007', pg_temp.lesson('p3-w1', 12, t1, '{"6":{"distinct_emotions_correct":4,"total":4},"7":{"emotions_mapped":4,"total":4}}'));
  perform pg_temp.demo_sync('30000000-0000-4000-8000-000000000008', pg_temp.lesson('p3-w1', 12, t1, '{"6":{"distinct_emotions_correct":4,"total":4},"7":{"emotions_mapped":2,"total":4}}'));
  perform pg_temp.demo_sync('30000000-0000-4000-8000-000000000009', pg_temp.lesson('p3-w1', 12, t1, '{"6":{"distinct_emotions_correct":4,"total":4},"7":{"emotions_mapped":4,"total":4}}'));
  perform pg_temp.demo_sync('30000000-0000-4000-8000-000000000010', pg_temp.lesson('p3-w1', 12, t1, '{"6":{"distinct_emotions_correct":3,"total":4},"7":{"emotions_mapped":3,"total":4}}'));
  perform pg_temp.demo_sync('30000000-0000-4000-8000-000000000011', pg_temp.lesson('p3-w1', 12, t1, '{"6":{"distinct_emotions_correct":4,"total":4},"7":{"emotions_mapped":4,"total":4}}'));
  perform pg_temp.demo_sync('30000000-0000-4000-8000-000000000012', pg_temp.lesson('p3-w1', 12, t1, '{"6":{"distinct_emotions_correct":2,"total":4},"7":{"emotions_mapped":3,"total":4}}'));
  perform pg_temp.demo_sync('30000000-0000-4000-8000-000000000013', pg_temp.lesson('p3-w1', 12, t1, '{"6":{"distinct_emotions_correct":4,"total":4},"7":{"emotions_mapped":4,"total":4}}'));
  perform pg_temp.demo_sync('30000000-0000-4000-8000-000000000014', pg_temp.lesson('p3-w1', 12, t1, '{"6":{"distinct_emotions_correct":3,"total":4},"7":{"emotions_mapped":4,"total":4}}'));
  perform pg_temp.demo_sync('30000000-0000-4000-8000-000000000002', pg_temp.lesson('p3-w1', 6, t1, '{"6":{"distinct_emotions_correct":1,"total":4}}'));

  -- Lesson 2: 5 completed, 3 halfway, 4 not started.
  perform pg_temp.demo_sync('30000000-0000-4000-8000-000000000001', pg_temp.lesson('p3-w2', 13, t2, '{"6":{"correct":3,"total":3},"7":{"rounds_completed":3,"total":3},"8":{"correct":8,"total":8}}'));
  perform pg_temp.demo_sync('30000000-0000-4000-8000-000000000003', pg_temp.lesson('p3-w2', 13, t2, '{"6":{"correct":2,"total":3},"7":{"rounds_completed":3,"total":3},"8":{"correct":7,"total":8}}'));
  perform pg_temp.demo_sync('30000000-0000-4000-8000-000000000007', pg_temp.lesson('p3-w2', 13, t2, '{"6":{"correct":3,"total":3},"7":{"rounds_completed":3,"total":3},"8":{"correct":6,"total":8}}'));
  perform pg_temp.demo_sync('30000000-0000-4000-8000-000000000008', pg_temp.lesson('p3-w2', 13, t2, '{"6":{"correct":3,"total":3},"7":{"rounds_completed":2,"total":3},"8":{"correct":7,"total":8}}'));
  perform pg_temp.demo_sync('30000000-0000-4000-8000-000000000013', pg_temp.lesson('p3-w2', 13, t2, '{"6":{"correct":3,"total":3},"7":{"rounds_completed":3,"total":3},"8":{"correct":8,"total":8}}'));
  perform pg_temp.demo_sync('30000000-0000-4000-8000-000000000009', pg_temp.lesson('p3-w2', 8, t2, '{"6":{"correct":2,"total":3},"7":{"rounds_completed":3,"total":3},"8":{"correct":5,"total":8}}'));
  perform pg_temp.demo_sync('30000000-0000-4000-8000-000000000010', pg_temp.lesson('p3-w2', 6, t2, '{"6":{"correct":1,"total":3}}'));
  perform pg_temp.demo_sync('30000000-0000-4000-8000-000000000011', pg_temp.lesson('p3-w2', 4, t2, '{}'));

  -- Today's class climate check-ins.
  perform pg_temp.demo_sync('30000000-0000-4000-8000-000000000001', jsonb_build_object('checkins', jsonb_build_array(jsonb_build_object('date', v_today, 'emotion', 'joy', 'intensity', 'quite'))));
  perform pg_temp.demo_sync('30000000-0000-4000-8000-000000000003', jsonb_build_object('checkins', jsonb_build_array(jsonb_build_object('date', v_today, 'emotion', 'calm', 'intensity', 'a_little'))));
  perform pg_temp.demo_sync('30000000-0000-4000-8000-000000000007', jsonb_build_object('checkins', jsonb_build_array(jsonb_build_object('date', v_today, 'emotion', 'joy', 'intensity', 'a_lot'))));
  perform pg_temp.demo_sync('30000000-0000-4000-8000-000000000008', jsonb_build_object('checkins', jsonb_build_array(jsonb_build_object('date', v_today, 'emotion', 'love', 'intensity', 'quite'))));
  perform pg_temp.demo_sync('30000000-0000-4000-8000-000000000009', jsonb_build_object('checkins', jsonb_build_array(jsonb_build_object('date', v_today, 'emotion', 'joy', 'intensity', 'quite'))));
  perform pg_temp.demo_sync('30000000-0000-4000-8000-000000000010', jsonb_build_object('checkins', jsonb_build_array(jsonb_build_object('date', v_today, 'emotion', 'anger', 'intensity', 'a_little'))));
  perform pg_temp.demo_sync('30000000-0000-4000-8000-000000000011', jsonb_build_object('checkins', jsonb_build_array(jsonb_build_object('date', v_today, 'emotion', 'calm', 'intensity', 'quite'))));
  perform pg_temp.demo_sync('30000000-0000-4000-8000-000000000012', jsonb_build_object('checkins', jsonb_build_array(jsonb_build_object('date', v_today, 'emotion', 'joy', 'intensity', 'quite'))));
  perform pg_temp.demo_sync('30000000-0000-4000-8000-000000000013', jsonb_build_object('checkins', jsonb_build_array(jsonb_build_object('date', v_today, 'emotion', 'joy', 'intensity', 'quite'))));
  perform pg_temp.demo_sync('30000000-0000-4000-8000-000000000014', jsonb_build_object('checkins', jsonb_build_array(jsonb_build_object('date', v_today, 'prefers_not_to_say', true))));
  perform pg_temp.demo_sync('30000000-0000-4000-8000-000000000002', jsonb_build_object('checkins', jsonb_build_array(
    jsonb_build_object('date', v_today, 'emotion', 'sadness', 'intensity', 'a_lot'),
    jsonb_build_object('date', v_today - 2, 'emotion', 'fear', 'intensity', 'quite'),
    jsonb_build_object('date', v_today - 4, 'emotion', 'anger', 'intensity', 'a_little'))));

  -- Secondary student started lesson 1 and checked in.
  perform pg_temp.demo_sync('30000000-0000-4000-8000-000000000004', pg_temp.lesson('s1-w1', 4, t2, '{}')
    || jsonb_build_object('checkins', jsonb_build_array(jsonb_build_object('date', v_today, 'emotion', 'calm', 'scale_1_5', 4))));

  perform private.detect_support_alerts();
end;
$$;