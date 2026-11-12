update private.student_credentials set locked_until = null, failed_pin_attempts = 0
where student_id = (select id from public.students where display_name = 'María José Rivera');