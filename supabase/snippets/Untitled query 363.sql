begin;
select set_config('request.jwt.claims', json_build_object('sub','a0000000-0000-4000-8000-000000000003',
  'role','authenticated','app_role','director')::text, true);
set local role authenticated;

select g ->> 'grade' as grade, g ->> 'section' as section, g ->> 'teacher_name' as teacher,
       g ->> 'students' as students,
       g -> 'current_assignment' ->> 'lesson_slug'   as lesson,
       g -> 'current_assignment' ->> 'completed'     as done,
       g -> 'current_assignment' ->> 'targeted'      as of,
       g -> 'current_assignment' ->> 'completed_pct' as pct,
       g -> 'climate' ->> 'hidden'                   as climate_hidden,
       g -> 'alerts'                                  as alerts
from jsonb_array_elements(public.school_overview('10000000-0000-4000-8000-000000000001') -> 'groups') g;

rollback;