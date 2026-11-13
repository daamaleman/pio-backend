select actor_role, action, target_table, at from private.audit_log
where action = 'invite_staff' order by id;