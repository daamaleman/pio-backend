begin;
select set_config('request.jwt.claims', json_build_object(
  'sub','00000000-0000-4000-8000-000000000001', 'role','authenticated', 'app_role','student',
  'student_id','30000000-0000-4000-8000-000000000001',
  'group_id','20000000-0000-4000-8000-000000000001', 'level','primary')::text, true);
set local role authenticated;
select public.submit_family_sheet('p3-w3', 'yes', 'interest');
rollback;