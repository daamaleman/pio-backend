begin;
select set_config('request.jwt.claims', json_build_object('sub','a0000000-0000-4000-8000-000000000004',
  'role','authenticated','app_role','counselor')::text, true);
set local role authenticated;
select s.display_name, a.details ->> 'wants' as wants, a.status
from public.alerts a join public.students s on s.id = a.student_id
where a.reason_code = 'help_request';
rollback;