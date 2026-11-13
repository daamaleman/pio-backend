-- ============================================================
-- Migration: lesson-media bucket (private, signed URLs) + validation of lesson_contents payloads
-- ============================================================

-- A. Private bucket for lesson media. 5 MB per file, only images, audio and json.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('lesson-media', 'lesson-media', false, 5242880,
        array['image/webp', 'image/png', 'image/svg+xml', 'audio/mpeg', 'audio/mp4', 'application/json'])
on conflict (id) do nothing;

-- Anyone signed in (students and staff) can read; only service_role/dashboard uploads.
create policy "lesson media readable by signed-in users"
on storage.objects for select
to authenticated
using (bucket_id = 'lesson-media');

-- B. A payload must match the lesson structure exactly
create or replace function private.validate_lesson_content()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_slug text;
  v_bad  text;
begin
  if new.schema_version <> '1' then
    raise exception 'UNSUPPORTED_SCHEMA_VERSION: %', new.schema_version;
  end if;

  if jsonb_typeof(new.payload -> 'steps') is distinct from 'array' then
    raise exception 'INVALID_PAYLOAD: steps must be an array';
  end if;

  select l.slug into v_slug from public.lessons l where l.id = new.lesson_id;
  if new.payload ->> 'lesson_slug' is distinct from v_slug then
    raise exception 'LESSON_SLUG_MISMATCH: payload says %, lesson is %', new.payload ->> 'lesson_slug', v_slug;
  end if;

  -- 1. Every step in the payload must exist in lesson_steps with the same position AND kind
  select string_agg(format('position %s (%s)', s ->> 'position', s ->> 'kind'), ', ')
    into v_bad
  from jsonb_array_elements(new.payload -> 'steps') s
  where not exists (
    select 1 from public.lesson_steps ls
    where ls.lesson_id = new.lesson_id
      and ls.position = (s ->> 'position')::int
      and ls.kind::text = s ->> 'kind');

  if v_bad is not null then
    raise exception 'STEP_MISMATCH: %', v_bad;
  end if;

  -- 2. Every structural step must have content exactly once
  select string_agg(ls.position::text, ', ' order by ls.position)
    into v_bad
  from public.lesson_steps ls
  where ls.lesson_id = new.lesson_id
    and (select count(*) from jsonb_array_elements(new.payload -> 'steps') s
         where (s ->> 'position')::int = ls.position) <> 1;

  if v_bad is not null then
    raise exception 'STEP_CONTENT_MISSING_OR_DUPLICATED: positions %', v_bad;
  end if;

  return new;
end;
$$;

create trigger lesson_contents_validate
before insert or update on public.lesson_contents
for each row execute function private.validate_lesson_content();

