begin;
select set_config('request.jwt.claims', json_build_object('sub','a0000000-0000-4000-8000-000000000001',
  'role','authenticated','app_role','teacher')::text, true);
set local role authenticated;

select jsonb_pretty(public.group_overview('20000000-0000-4000-8000-000000000001') - 'climate');
rollback;