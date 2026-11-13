-- 2. What does a signed-in student see? (same RLS as the API)
begin;
select set_config('request.jwt.claims', json_build_object('sub','00000000-0000-4000-8000-000000000000',
  'role','authenticated','app_role','student')::text, true);
set local role authenticated;
select name from storage.objects where bucket_id = 'lesson-media';
rollback;