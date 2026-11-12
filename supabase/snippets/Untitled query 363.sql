begin;
-- As postgres: a check-in for María (simulating what sync_progress will do)
insert into public.emotion_checkins (student_id, checkin_date, emotion, intensity)
values ('30000000-0000-4000-8000-000000000001', current_date, 'joy', 'quite');

-- Ana (María's teacher)
select set_config('request.jwt.claims', json_build_object(
  'sub', 'a0000000-0000-4000-8000-000000000001', 'role', 'authenticated', 'app_role', 'teacher')::text, true);
set local role authenticated;
select set_config('test.ana_sees', (select count(*)::text from public.emotion_checkins), true);

-- Luis (another school)
select set_config('request.jwt.claims', json_build_object(
  'sub', 'a0000000-0000-4000-8000-000000000002', 'role', 'authenticated', 'app_role', 'teacher')::text, true);

select current_setting('test.ana_sees') as ana_sees,
       (select count(*) from public.emotion_checkins) as luis_sees;
rollback;