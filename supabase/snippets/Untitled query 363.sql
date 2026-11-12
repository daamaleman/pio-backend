begin;
insert into public.lessons (id, slug, level, grade, week, title, parts_count)
values ('40000000-0000-4000-8000-0000000000aa', 'test-a', 'primary', 3, 1, '{"es":"A"}', 3);

insert into public.lesson_steps (lesson_id, position, part, kind)
values ('40000000-0000-4000-8000-0000000000aa', 6, 2, 'minigame');
rollback;