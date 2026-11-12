begin;
-- Read ids BEFORE switching role (afterwards RLS would hide them)
select set_config('test.group_4b', (select id::text from public.groups where class_code = '4BANA27'), true);
select set_config('request.jwt.claims', json_build_object(
  'sub', (select id from auth.users where email = 'ana.lopez@demo.pio'),
  'role', 'authenticated',
  'app_role', 'teacher')::text, true);

set local role authenticated;   -- from here on, we are "Ana" from the app

select private.auth_role()                                                as my_role,
       private.is_teacher_of_group(current_setting('test.group_4b')::uuid) as teacher_of_4b,
       private.is_admin()                                                  as am_i_admin,
       (select count(*) from public.groups)                                as groups_i_can_see;
rollback;