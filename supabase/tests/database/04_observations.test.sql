-- Teacher observations (migration 34). Uses the demo seed; everything is rolled back.
begin;
select plan(6);

create temp table ctx on commit drop as
select '30000000-0000-4000-8000-000000000002'::uuid as carlos;   -- 3.º B, Ana's student
grant select on ctx to authenticated;

set local role authenticated;

-- Ana (teacher of 3.º B)
select set_config('request.jwt.claims',
  '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated","app_role":"teacher"}', true);

select lives_ok(
  $$ select public.add_observation((select carlos from ctx), 'emotional', 'Hoy estuvo callado en la clase.', null, null, true) $$,
  'A teacher records an observation and asks counseling for support');

select is(
  (select count(*)::int from public.teacher_observations where student_id = (select carlos from ctx)),
  1, 'The teacher reads her own observation');

-- Luis (teacher in another school)
select set_config('request.jwt.claims',
  '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated","app_role":"teacher"}', true);

select throws_ok(
  $$ select public.add_observation((select carlos from ctx), 'other', 'No es mi estudiante.') $$,
  '42501', null, 'A teacher cannot write observations about another teacher''s student');

select is(
  (select count(*)::int from public.teacher_observations where student_id = (select carlos from ctx)),
  0, 'A teacher cannot read observations about another teacher''s student');

-- Marta (counseling, same school)
select set_config('request.jwt.claims',
  '{"sub":"a0000000-0000-4000-8000-000000000004","role":"authenticated","app_role":"counselor"}', true);

select is(
  (select count(*)::int from public.teacher_observations where student_id = (select carlos from ctx)),
  0, 'Counseling never reads the text of observations');

select is(
  (select details ->> 'category' from public.alerts
    where student_id = (select carlos from ctx) and reason_code = 'teacher_referral' and status <> 'closed'),
  'emotional', 'Counseling gets the referral alert with the category only');

select * from finish();
rollback;