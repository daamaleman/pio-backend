-- Anonymous question box (migration 35). Uses the demo seed; everything is rolled back.
-- Daniela = 1.er año A (secondary, teacher Ana, lesson s1-w1 assigned). María = 3.º B (primary).
begin;
select plan(9);

select hasnt_column('public', 'anonymous_questions', 'student_id',
  'Anonymous questions have no link to the student');

set local role authenticated;

-- Daniela (secondary student)
select set_config('request.jwt.claims', json_build_object(
  'sub', '30000000-0000-4000-8000-000000000004', 'role', 'authenticated', 'app_role', 'student',
  'student_id', '30000000-0000-4000-8000-000000000004',
  'group_id', '20000000-0000-4000-8000-000000000003', 'level', 'secondary')::text, true);

select lives_ok(
  $$ select public.submit_anonymous_question('s1-w1', '¿Es normal sentirse diferente a los demás?') $$,
  'A secondary student sends an anonymous question');

do $$ begin
  perform public.submit_anonymous_question('s1-w1', 'Segunda pregunta de prueba');
  perform public.submit_anonymous_question('s1-w1', 'Tercera pregunta de prueba');
end $$;

select throws_ok(
  $$ select public.submit_anonymous_question('s1-w1', 'Cuarta pregunta') $$,
  'P0001', 'TOO_MANY_QUESTIONS',
  'A student can send at most 3 questions per lesson');

-- María (primary student)
select set_config('request.jwt.claims', json_build_object(
  'sub', '30000000-0000-4000-8000-000000000001', 'role', 'authenticated', 'app_role', 'student',
  'student_id', '30000000-0000-4000-8000-000000000001',
  'group_id', '20000000-0000-4000-8000-000000000001', 'level', 'primary')::text, true);

select throws_ok(
  $$ select public.submit_anonymous_question('p3-w1', 'Pregunta') $$,
  'P0001', 'NOT_FOR_LEVEL',
  'The question box is only for secondary');

-- Ana (teacher of 1.er año A)
select set_config('request.jwt.claims',
  '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated","app_role":"teacher"}', true);

select is(
  (select count(*)::int from public.anonymous_questions where group_id = '20000000-0000-4000-8000-000000000003'),
  3, 'The group''s teacher reads the questions');

select lives_ok(
  $$ select public.set_question_status(
       (select id from public.anonymous_questions where group_id = '20000000-0000-4000-8000-000000000003' limit 1),
       'answered') $$,
  'The teacher marks a question as answered');

-- Luis (teacher in another school)
select set_config('request.jwt.claims',
  '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated","app_role":"teacher"}', true);

select is(
  (select count(*)::int from public.anonymous_questions where group_id = '20000000-0000-4000-8000-000000000003'),
  0, 'Another teacher cannot read the questions');

reset role;
create temp table q on commit drop as
  select id from public.anonymous_questions where group_id = '20000000-0000-4000-8000-000000000003' limit 1;
grant select on q to authenticated;
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated","app_role":"teacher"}', true);

select throws_ok(
  $$ select public.set_question_status((select id from q), 'hidden') $$,
  '42501', null,
  'Another teacher cannot change the status');

-- Marta (counseling, same school)
select set_config('request.jwt.claims',
  '{"sub":"a0000000-0000-4000-8000-000000000004","role":"authenticated","app_role":"counselor"}', true);

select is(
  (select count(*)::int from public.anonymous_questions where group_id = '20000000-0000-4000-8000-000000000003'),
  3, 'School counseling reads the questions');

select * from finish();
rollback;