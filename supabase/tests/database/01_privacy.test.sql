-- ============================================================
-- Privacy rules that must never break. Runs on the seed data, inside a transaction that is undone.
-- ============================================================
begin;
create extension if not exists pgtap with schema extensions;
select plan(12);

-- ---------- Test data (as postgres), only if it does not exist yet ----------
insert into public.alerts (student_id, group_id, origin, level, reason_code, details)
select '30000000-0000-4000-8000-000000000004', '20000000-0000-4000-8000-000000000003',
       'chat', 'risk_high', 'chat_risk', '{"category": "self_harm"}'
where not exists (select 1 from public.alerts
                  where student_id = '30000000-0000-4000-8000-000000000004'
                    and reason_code = 'chat_risk' and status::text <> 'closed');

insert into public.alerts (student_id, group_id, origin, level, reason_code, details)
select '30000000-0000-4000-8000-000000000003', '20000000-0000-4000-8000-000000000001',
       'help_request', 'support', 'help_request', '{"wants": "counselor"}'
where not exists (select 1 from public.alerts
                  where student_id = '30000000-0000-4000-8000-000000000003'
                    and reason_code = 'help_request' and status::text <> 'closed');

insert into public.family_sheets (student_id, lesson_id, challenge_done, how_responded)
select '30000000-0000-4000-8000-000000000001', id, 'yes', 'interest'
from public.lessons where slug = 'p3-w1'
on conflict (student_id, lesson_id) do nothing;

-- the QR token of 3.° B, kept for the anon test
select set_config('tests.qr', (select family_qr_token::text from public.groups where class_code = '3BAN27'), true);

-- ---------- Ana, teacher of 3.° B and 1.° A ----------
select set_config('request.jwt.claims', json_build_object('sub','a0000000-0000-4000-8000-000000000001',
  'role','authenticated','app_role','teacher')::text, true);
set local role authenticated;

select is((select count(*)::int from public.alerts where origin::text = 'chat'), 0,
  'A teacher never sees AI chat alerts');
select is((select count(*)::int from public.alerts
           where origin::text = 'help_request' and details ->> 'wants' = 'counselor'), 0,
  'A teacher never sees help requests addressed to counseling');
select ok((select count(*) from public.family_sheets) >= 1,
  'A teacher sees the family sheets of her students');
select throws_ok($$select public.school_overview('10000000-0000-4000-8000-000000000001')$$, '42501', null,
  'A teacher cannot open the school panel');
select throws_ok($$select public.claim_notifications(10)$$, '42501', null,
  'A teacher cannot read the notification queue');

-- ---------- Luis, teacher of another school ----------
select set_config('request.jwt.claims', json_build_object('sub','a0000000-0000-4000-8000-000000000002',
  'role','authenticated','app_role','teacher')::text, true);

select is((select count(*)::int from public.family_sheets), 0,
  'A teacher does not see family sheets of other groups');

-- ---------- Marta, counselor ----------
select set_config('request.jwt.claims', json_build_object('sub','a0000000-0000-4000-8000-000000000004',
  'role','authenticated','app_role','counselor')::text, true);

select ok((select count(*) from public.alerts where origin::text = 'chat') >= 1,
  'Counseling sees AI chat alerts of its school');
select throws_ok($$select * from private.ai_messages$$, '42501', null,
  'Nobody on staff can read AI chat messages');

-- ---------- Rosa, director ----------
select set_config('request.jwt.claims', json_build_object('sub','a0000000-0000-4000-8000-000000000003',
  'role','authenticated','app_role','director')::text, true);

select lives_ok($$select public.school_overview('10000000-0000-4000-8000-000000000001')$$,
  'A director opens the panel of her school');
select throws_ok($$select public.school_overview('10000000-0000-4000-8000-000000000002')$$, '42501', null,
  'A director cannot open the panel of another school');

-- ---------- María, student ----------
select set_config('request.jwt.claims', json_build_object(
  'sub','00000000-0000-0000-0000-000000000001', 'role','authenticated', 'app_role','student',
  'student_id','30000000-0000-4000-8000-000000000001',
  'group_id','20000000-0000-4000-8000-000000000001', 'level','primary')::text, true);

select is((select count(*)::int from public.alerts), 0,
  'A student never sees alerts, not even her own');

-- ---------- No session (QR page) ----------
reset role;
set local role anon;

select ok(public.family_week(current_setting('tests.qr'))::text !~ '(Rivera|Martínez|López|display_name)',
  'The public QR page never contains student names');

select * from finish();
rollback;
