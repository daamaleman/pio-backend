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
-- Groups (class code shown as the child sees it)
--   4.° B  primary   Ana   4B·AN·27   María Rivera 3714 · Carlos Martínez 2589 · Sofía López 1593
--   4.° A  primary   Ana   4A·AN·35   (no students)
--   1.er A secondary Ana   1A·AN·46   Daniela Hernández 4826 · José Téllez 7391   (AI chat ON)
--   1.er A secondary Luis  1A·LU·58   Kevin Obando 6240
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
   'a0000000-0000-4000-8000-000000000001', 'primary',   4, 'B', 1, 'es', '4BAN27', 2026, false),
  ('20000000-0000-4000-8000-000000000002', '10000000-0000-4000-8000-000000000001',
   'a0000000-0000-4000-8000-000000000001', 'primary',   4, 'A', 3, 'es', '4AAN35', 2026, false),
  ('20000000-0000-4000-8000-000000000003', '10000000-0000-4000-8000-000000000001',
   'a0000000-0000-4000-8000-000000000001', 'secondary', 1, 'A', 2, 'es', '1AAN46', 2026, true),
  ('20000000-0000-4000-8000-000000000004', '10000000-0000-4000-8000-000000000002',
   'a0000000-0000-4000-8000-000000000002', 'secondary', 1, 'A', 4, 'en', '1ALU58', 2026, false);

-- ---------- Students (no shadow users: student-login creates them on first login) ----------
insert into public.students (id, group_id, display_name) values
  ('30000000-0000-4000-8000-000000000001', '20000000-0000-4000-8000-000000000001', 'María Rivera'),
  ('30000000-0000-4000-8000-000000000002', '20000000-0000-4000-8000-000000000001', 'Carlos Martínez'),
  ('30000000-0000-4000-8000-000000000003', '20000000-0000-4000-8000-000000000001', 'Sofía López'),
  ('30000000-0000-4000-8000-000000000004', '20000000-0000-4000-8000-000000000003', 'Daniela Hernández'),
  ('30000000-0000-4000-8000-000000000005', '20000000-0000-4000-8000-000000000003', 'José Téllez'),
  ('30000000-0000-4000-8000-000000000006', '20000000-0000-4000-8000-000000000004', 'Kevin Obando');

-- ---------- PINs (primary: digits 1–9 only, the design grid has 9 drawings) ----------
insert into private.student_credentials (student_id, pin_hash)
select v.student_id, extensions.crypt(v.pin, extensions.gen_salt('bf', 10))
from (values
  ('30000000-0000-4000-8000-000000000001'::uuid, '3714'),
  ('30000000-0000-4000-8000-000000000002'::uuid, '2589'),
  ('30000000-0000-4000-8000-000000000003'::uuid, '1593'),
  ('30000000-0000-4000-8000-000000000004'::uuid, '4826'),
  ('30000000-0000-4000-8000-000000000005'::uuid, '7391'),
  ('30000000-0000-4000-8000-000000000006'::uuid, '6240')
) as v(student_id, pin);

