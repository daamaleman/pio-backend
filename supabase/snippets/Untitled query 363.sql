begin;
select set_config('request.jwt.claims', json_build_object(
  'sub', 'a0000000-0000-4000-8000-000000000003',
  'role', 'authenticated', 'app_role', 'director')::text, true);
set local role authenticated;

update public.groups set ai_chat_enabled = false
where id = '20000000-0000-4000-8000-000000000003'
returning class_code, ai_chat_enabled;
rollback;