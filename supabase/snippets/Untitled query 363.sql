-- Temporarily rename Ana to test accents (no lasting change)
begin;
update public.profiles set full_name = 'Ñoño Pérez'
where id = (select id from auth.users where email = 'ana.lopez@demo.pio');

select private.generate_class_code(4::smallint, 'C', id) as code_with_accent
from auth.users where email = 'ana.lopez@demo.pio';

update public.profiles set full_name = 'Al Ruiz'
where id = (select id from auth.users where email = 'ana.lopez@demo.pio');

select private.generate_class_code(4::smallint, 'C', id) as code_short_name
from auth.users where email = 'ana.lopez@demo.pio';
rollback;