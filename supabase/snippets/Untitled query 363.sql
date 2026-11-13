begin;
-- two more answers as postgres, for Carlos and Sofía, inside a transaction that is undone
insert into public.self_assessments (student_id, group_id, month, period, answers) values
  ('30000000-0000-4000-8000-000000000002', '20000000-0000-4000-8000-000000000001',
   date_trunc('month', now() at time zone 'America/Managua')::date, 'start',
   '{"name_emotions": 2, "calm_down": 1, "treat_well": 3, "ask_for_help": 2}'),
  ('30000000-0000-4000-8000-000000000003', '20000000-0000-4000-8000-000000000001',
   date_trunc('month', now() at time zone 'America/Managua')::date, 'start',
   '{"name_emotions": 3, "calm_down": 3, "treat_well": 2, "ask_for_help": 3}');

select set_config('request.jwt.claims', json_build_object('sub','a0000000-0000-4000-8000-000000000001',
  'role','authenticated','app_role','teacher')::text, true);
set local role authenticated;
select jsonb_pretty(public.self_assessment_summary('20000000-0000-4000-8000-000000000001') -> 'start');
rollback;