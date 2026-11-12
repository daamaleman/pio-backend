begin;
select set_config('request.jwt.claims', json_build_object(
  'sub', gen_random_uuid(), 'role', 'authenticated', 'app_role', 'student', 'level', 'primary',
  'student_id', '30000000-0000-4000-8000-000000000001',
  'group_id',   '20000000-0000-4000-8000-000000000001')::text, true);
set local role authenticated;

select r -> 'accepted' as accepted, r -> 'rejected' as rejected
from public.sync_progress('{
  "checkins": [
    { "date": "2026-01-01", "emotion": "joy" },
    { "date": "2026-11-12", "emotion": "calm", "intensity": "a_little" }
  ],
  "lessons": [
    { "lesson_slug": "p3-w2", "steps": [{ "position": 1, "status": "completed" }] },
    { "lesson_slug": "s1-w1", "steps": [{ "position": 1, "status": "completed" }] },
    { "lesson_slug": "p3-w1", "steps": [{ "position": 6, "status": "skipped" }] }
  ]
}'::jsonb) as r;
rollback;