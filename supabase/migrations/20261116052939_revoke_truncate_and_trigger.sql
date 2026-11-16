-- Supabase grants every privilege on public tables to anon/authenticated by default.
-- TRUNCATE ignores RLS and TRIGGER is never needed by app users: remove both, now and for future tables.
revoke truncate, trigger on all tables in schema public from anon, authenticated;
alter default privileges in schema public revoke truncate, trigger on tables from anon, authenticated;