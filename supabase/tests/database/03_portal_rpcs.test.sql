-- Tests for migrations 30–33: assign_lesson, remind_pending, record_family_sheet and API grants.
-- Uses the demo seed (Ana = teacher of 3.º B, Luis = teacher in Bluefields). Everything is rolled back.
begin;
select plan(13);

-- ---------- Fixed ids from the seed ----------
create temp table ctx on commit drop as
select
  'a0000000-0000-4000-8000-000000000001'::uuid as ana,
  'a0000000-0000-4000-8000-000000000002'::uuid as luis,
  '20000000-0000-4000-8000-000000000001'::uuid as g3b,
  '30000000-0000-4000-8000-000000000001'::uuid as maria,
  '30000000-0000-4000-8000-000000000003'::uuid as sofia,
  '30000000-0000-4000-8000-000000000006'::uuid as kevin,
  (select id from public.lessons where slug = 'p3-w1') as l1,
  (select id from public.lessons where slug = 'p3-w3') as l3,
  (select id from public.lessons where slug = 'p3-w4') as l4,
  (select a.id from public.assignments a
     join public.lessons l on l.id = a.lesson_id
    where a.group_id = '20000000-0000-4000-8000-000000000001' and l.slug = 'p3-w1') as a1,
  (select s.id from public.students s
    where s.group_id = '20000000-0000-4000-8000-000000000001'
      and not exists (select 1 from public.family_sheets fs
                      join public.lessons l on l.id = fs.lesson_id
                      where fs.student_id = s.id and l.slug = 'p3-w1')
    order by s.id limit 1) as fam_student;
grant select on ctx to authenticated;

-- ======================= assign_lesson (migration 30) =======================
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated","app_role":"teacher"}', true);

select lives_ok(
  $$ select public.assign_lesson(
       (select g3b from ctx), (select l3 from ctx), current_date, current_date + 7, 'Prueba',
       array[(select maria from ctx), (select sofia from ctx)]) $$,
  'A teacher assigns a lesson to two specific students');

select is(
  (select count(*)::int from public.assignment_students ast
     join public.assignments a on a.id = ast.assignment_id
    where a.group_id = (select g3b from ctx) and a.lesson_id = (select l3 from ctx) and not a.targets_all),
  2, 'The assignment targets exactly those two students');

select throws_ok(
  $$ select public.assign_lesson(
       (select g3b from ctx), (select l4 from ctx), current_date, current_date + 7, null,
       array[(select maria from ctx), (select kevin from ctx)]) $$,
  null, null,
  'Assigning to a student of another school fails');

select is(
  (select count(*)::int from public.assignments
    where group_id = (select g3b from ctx) and lesson_id = (select l4 from ctx)),
  0, 'A failed assignment leaves nothing half-created');

-- ======================= remind_pending (migration 31) ======================
select set_config('request.jwt.claims',
  '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated","app_role":"teacher"}', true);

select throws_ok(
  $$ select public.remind_pending((select a1 from ctx)) $$,
  '42501', null,
  'A teacher cannot send reminders for another teacher''s assignment');

select set_config('request.jwt.claims',
  '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated","app_role":"teacher"}', true);

select lives_ok(
  $$ select public.remind_pending((select a1 from ctx)) $$,
  'The teacher of the group can send reminders');

-- ======================= record_family_sheet (migration 33) ==================
select lives_ok(
  $$ select public.record_family_sheet((select fam_student from ctx), (select l1 from ctx), 'yes', 'interest', 'joy', 'Lo hicimos en la cena') $$,
  'A teacher records a paper family sheet');

select is(
  (select source from public.family_sheets
    where student_id = (select fam_student from ctx) and lesson_id = (select l1 from ctx)),
  'paper', 'The sheet is marked as paper');

select set_config('request.jwt.claims',
  json_build_object(
    'sub', (select fam_student from ctx), 'role', 'authenticated', 'app_role', 'student',
    'student_id', (select fam_student from ctx), 'group_id', (select g3b from ctx), 'level', 'primary')::text,
  true);

select lives_ok(
  $$ select public.submit_family_sheet('p3-w1', 'partly', 'difficulty', null, null) $$,
  'The family fills the same sheet in the app');

select set_config('request.jwt.claims',
  '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated","app_role":"teacher"}', true);

select is(
  (select source from public.family_sheets
    where student_id = (select fam_student from ctx) and lesson_id = (select l1 from ctx)),
  'app', 'The app submission replaces the paper one');

select throws_ok(
  $$ select public.record_family_sheet((select fam_student from ctx), (select l1 from ctx), 'no', 'declined') $$,
  'P0001', 'ALREADY_SUBMITTED_IN_APP',
  'A teacher never overwrites a sheet the family filled in the app');

select set_config('request.jwt.claims',
  '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated","app_role":"teacher"}', true);

select throws_ok(
  $$ select public.record_family_sheet((select maria from ctx), (select l1 from ctx), 'yes', 'interest') $$,
  '42501', null,
  'A teacher cannot record sheets for another teacher''s students');

-- ======================= API grants (migration 32) ==========================
reset role;

select is(
  (select count(*)::int from information_schema.role_table_grants
    where table_schema = 'public' and grantee in ('anon', 'authenticated')
      and privilege_type in ('TRUNCATE', 'TRIGGER')),
  0, 'API roles have no TRUNCATE or TRIGGER on public tables');

select * from finish();
rollback;
