-- ============================================================
-- Migration: AI chat alerts are NEVER visible to teachers (read or write).
-- Restrictive: ANDed with every existing policy on alerts.
-- ============================================================
create policy "chat alerts hidden from teachers" on public.alerts
  as restrictive
  for all to authenticated
  using      (not (origin::text = 'chat' and private.auth_role()::text = 'teacher'))
  with check (not (origin::text = 'chat' and private.auth_role()::text = 'teacher'));