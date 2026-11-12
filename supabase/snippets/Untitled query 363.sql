begin;
select set_config('request.jwt.claims', json_build_object(
  'sub', gen_random_uuid(), 'role', 'authenticated',
  'app_role', 'student', 'level', 'primary',
  'student_id', '30000000-0000-4000-8000-000000000001',
  'group_id',   '20000000-0000-4000-8000-000000000001')::text, true);
set local role authenticated;

select (select count(*) from public.lessons)      as lessons_i_see,
       (select string_agg(distinct level::text, ',') from public.lessons) as levels,
       (select count(*) from public.minigames)    as minigames_i_see,
       (select count(*) from public.lesson_steps) as steps_i_see;
rollback;