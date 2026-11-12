   select u.email, s.auth_user_id as linked_to_student
   from auth.users u
   left join public.students s on s.auth_user_id = u.id
   where u.email like '%@students.pio.invalid';