begin;
select set_config('request.jwt.claims', json_build_object(
  'sub','00000000-0000-4000-8000-000000000005', 'role','authenticated', 'app_role','student',
  'student_id','30000000-0000-4000-8000-000000000005',
  'group_id','20000000-0000-4000-8000-000000000003', 'level','secondary')::text, true);
set local role authenticated;
select jsonb_pretty(public.sync_toolbox('{
  "tools":     [ { "id": "aaaaaaaa-0000-4000-8000-000000000001", "lesson_slug": "s1-w1", "position": 11,
                   "created_on": "2026-11-12", "archived_on": "2026-11-13" } ],
  "tool_uses": [ { "tool_id": "aaaaaaaa-0000-4000-8000-000000000001", "used_on": "2026-11-13" } ],
  "goals":     [ { "id": "cccccccc-0000-4000-8000-000000000001", "created_on": "2026-11-05" },
                 { "id": "dddddddd-0000-4000-8000-000000000001", "created_on": "2026-11-06" } ]
}'));
rollback;