begin;
select set_config('request.jwt.claims', json_build_object(
  'sub', 'a0000000-0000-4000-8000-000000000001',
  'role', 'authenticated', 'app_role', 'teacher')::text, true);
set local role authenticated;

-- 1) Ana assigns p3-w2 to 3.° B, only for specific students
insert into public.assignments (group_id, lesson_id, class_date, due_date, message, targets_all)
select g.id, l.id, current_date, current_date + 7, 'Carlos, esta es para vos', false
from public.groups g, public.lessons l
where g.class_code = '3BAN27' and l.slug = 'p3-w2';

-- 2) Only Carlos
insert into public.assignment_students (assignment_id, student_id)
select a.id, '30000000-0000-4000-8000-000000000002'
from public.assignments a
join public.lessons l on l.id = a.lesson_id
where l.slug = 'p3-w2';

-- 3) Now we are MARÍA
select set_config('request.jwt.claims', json_build_object(
  'sub', gen_random_uuid(), 'role', 'authenticated', 'app_role', 'student', 'level', 'primary',
  'student_id', '30000000-0000-4000-8000-000000000001',
  'group_id',   '20000000-0000-4000-8000-000000000001')::text, true);

select public.my_week() -> 'current' ->> 'lesson_slug' as maria_current,
       jsonb_path_query_array(public.my_week() -> 'lessons', '$[*] ? (@.unlocked == true).slug') as maria_unlocked;
rollback;