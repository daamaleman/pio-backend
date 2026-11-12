insert into public.students (group_id, display_name)
select id, 'Carlos Martínez' from public.groups where class_code = '4BANA27';