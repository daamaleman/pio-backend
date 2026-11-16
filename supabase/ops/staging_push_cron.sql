-- Run in the staging SQL Editor after every `db reset --remote` (the reset wipes Vault and manual cron jobs).
-- NEVER commit a real secret: paste it over the placeholder only in the SQL Editor.
create extension if not exists pg_net;

delete from vault.secrets where name in ('project_url', 'cron_secret');
select vault.create_secret('https://uoqzwcuggirgkbyszjsy.supabase.co', 'project_url');
select vault.create_secret('<PASTE_CRON_SECRET_HERE>', 'cron_secret');

-- Every 5 minutes, call send-push with the secret from Vault (same name = replaces the job)
select cron.schedule('send-push', '*/5 * * * *', $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/send-push',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')
    ),
    body := '{}'::jsonb
  );
$$);
