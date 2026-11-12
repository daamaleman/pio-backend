begin;
select set_config('request.jwt.claims', json_build_object('sub','a0000000-0000-4000-8000-000000000001',
  'role','authenticated','app_role','teacher')::text, true);
set local role authenticated;

select x ->> 'display_name' as student, x ->> 'status' as status, x ->> 'latest_emotion' as emotion,
       (select string_agg((i ->> 'number') || ':' || coalesce(i ->> 'result', '—'), '  ')
        from jsonb_array_elements(x -> 'indicators') i) as indicators
from jsonb_array_elements(public.assignment_progress(
       (select a.id from public.assignments a join public.lessons l on l.id = a.lesson_id where l.slug = 'p3-w2')
     ) -> 'students') as x;
rollback;