-- ============================================================
-- Business rules: one vote per student, idempotent syncs, validations, ownership.
-- Uses 3 temporary students so it behaves the same on a used local DB and on a fresh CI DB.
-- ============================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(15);

-- ---------- Temporary students (undone by the final rollback) ----------
insert into public.students (id, group_id, display_name) values
  ('eeeeeeee-0000-4000-8000-000000000001', '20000000-0000-4000-8000-000000000003', 'Prueba Uno'),   -- secondary
  ('eeeeeeee-0000-4000-8000-000000000002', '20000000-0000-4000-8000-000000000003', 'Prueba Dos'),   -- secondary
  ('eeeeeeee-0000-4000-8000-000000000003', '20000000-0000-4000-8000-000000000001', 'Prueba Tres');  -- primary

-- ---------- Structural guarantees (as postgres) ----------
select hasnt_column('private', 'poll_responses', 'student_id',
  'Poll answers have no link to the student (anonymity)');
select is((select count(*)::int from pg_policies where schemaname = 'private' and tablename = 'ai_messages'), 0,
  'AI chat messages have no RLS policy: nobody reads them through the API');
select throws_like($$
  insert into public.lesson_contents (lesson_id, language, version, schema_version, payload)
  select id, 'es', 99, '1', '{"lesson_slug":"p3-w1","steps":[{"position":1,"kind":"quiz"}]}'::jsonb
  from public.lessons where slug = 'p3-w1' $$,
  'STEP_MISMATCH%', 'Lesson content that does not match its structure is rejected');

-- ---------- Prueba Uno (secondary) ----------
select set_config('request.jwt.claims', json_build_object(
  'sub','eeeeeeee-1111-4000-8000-000000000001', 'role','authenticated', 'app_role','student',
  'student_id','eeeeeeee-0000-4000-8000-000000000001',
  'group_id','20000000-0000-4000-8000-000000000003', 'level','secondary')::text, true);
set local role authenticated;

select is((public.submit_poll('s1-w1', 'yes') ->> 'already_answered')::boolean, false,
  'First poll answer is counted');
select is((public.submit_poll('s1-w1', 'no') ->> 'already_answered')::boolean, true,
  'A second poll answer is ignored');

select public.sync_toolbox('{
  "tools":     [ { "id": "ffffffff-0000-4000-8000-000000000001", "lesson_slug": "s1-w1", "position": 11, "created_on": "2026-11-12" } ],
  "tool_uses": [ { "tool_id": "ffffffff-0000-4000-8000-000000000001", "used_on": "2026-11-12" },
                 { "tool_id": "ffffffff-0000-4000-8000-000000000001", "used_on": "2026-11-13" } ] }');
select public.sync_toolbox('{
  "tools":     [ { "id": "ffffffff-0000-4000-8000-000000000001", "lesson_slug": "s1-w1", "position": 11, "created_on": "2026-11-12" } ],
  "tool_uses": [ { "tool_id": "ffffffff-0000-4000-8000-000000000001", "used_on": "2026-11-12" },
                 { "tool_id": "ffffffff-0000-4000-8000-000000000001", "used_on": "2026-11-13" } ] }');

select is((select count(*)::int from public.student_tools), 1,
  'Syncing the toolbox twice does not duplicate tools');
select is((select count(*)::int from public.student_tool_uses), 2,
  'Syncing the toolbox twice does not duplicate practice days');

-- ---------- Prueba Dos tries to touch Prueba Uno's tool ----------
select set_config('request.jwt.claims', json_build_object(
  'sub','eeeeeeee-1111-4000-8000-000000000002', 'role','authenticated', 'app_role','student',
  'student_id','eeeeeeee-0000-4000-8000-000000000002',
  'group_id','20000000-0000-4000-8000-000000000003', 'level','secondary')::text, true);

select is(public.sync_toolbox('{
  "tools": [ { "id": "ffffffff-0000-4000-8000-000000000001", "lesson_slug": "s1-w1", "position": 11,
               "created_on": "2026-11-12", "archived_on": "2026-11-13" } ] }') -> 'rejected' -> 0 ->> 'code',
  'NOT_OWNER', 'A student cannot modify another student''s tool');

-- ---------- Prueba Tres (primary) ----------
select set_config('request.jwt.claims', json_build_object(
  'sub','eeeeeeee-1111-4000-8000-000000000003', 'role','authenticated', 'app_role','student',
  'student_id','eeeeeeee-0000-4000-8000-000000000003',
  'group_id','20000000-0000-4000-8000-000000000001', 'level','primary')::text, true);

select throws_like($$select public.submit_self_assessment('end', '{"name_emotions": 3}')$$,
  'MISSING_ITEMS%', 'A self-assessment must answer every statement');
select throws_like($$select public.set_trusted_adults('[{"kind":"mother","label":"Mamá 8888-1234"},{"kind":"father"}]')$$,
  'INVALID_LABEL%', 'Trusted adult names cannot hold phone numbers');
select is(public.request_help('teacher') ->> 'result', 'created',
  'A help request is created');
select is(public.request_help('teacher') ->> 'result', 'already_requested',
  'Tapping "I need help" again does not create a second request');

-- ---------- Teachers and PINs ----------
select set_config('request.jwt.claims', json_build_object('sub','a0000000-0000-4000-8000-000000000001',
  'role','authenticated','app_role','teacher')::text, true);
select throws_like($$select public.reset_student_pin('30000000-0000-4000-8000-000000000001', '1230')$$,
  'INVALID_PIN_FORMAT%', 'A primary PIN cannot contain 0 (9-drawing grid)');

select set_config('request.jwt.claims', json_build_object('sub','a0000000-0000-4000-8000-000000000002',
  'role','authenticated','app_role','teacher')::text, true);
select throws_ok($$select public.reset_student_pin('30000000-0000-4000-8000-000000000001')$$, '42501', null,
  'A teacher cannot reset the PIN of another teacher''s student');

-- Back to postgres: the poll counted exactly one participation for Prueba Uno
reset role;
select is((select count(*)::int from private.poll_participation
           where student_id = 'eeeeeeee-0000-4000-8000-000000000001'), 1,
  'Only one poll participation is stored per student and lesson');

select * from finish();
rollback;
