select (select count(*) from public.groups)   as groups_total,
       (select count(*) from public.students) as students_total,
       (select string_agg(display_name, ', ' order by display_name) from public.students) as names;