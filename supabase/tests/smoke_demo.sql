-- ============================================================
-- Smoke test for the demo (run in the SQL Editor right after `db reset --remote`)
-- Every row must show ✅. Update the expected numbers when migrations or seed change.
-- ============================================================
with checks (area, check_name, op, expected, actual) as (
  values
  -- Schema
  ('1 Esquema',  'Migraciones aplicadas',             '=',  19, (select count(*) from supabase_migrations.schema_migrations)),
  ('1 Esquema',  'Hook del JWT existe',                '=',  1,  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                                                                   where n.nspname = 'public' and p.proname = 'custom_access_token_hook')),
  ('1 Esquema',  'Cron de alertas activo',             '=',  1,  (select count(*) from cron.job where jobname = 'detect-support-alerts' and active)),
  ('1 Esquema',  'Bucket lesson-media (privado)',      '=',  1,  (select count(*) from storage.buckets where id = 'lesson-media' and not public)),
  -- Catalog
  ('2 Catálogo', 'Lecciones',                          '=',  8,  (select count(*) from public.lessons)),
  ('2 Catálogo', 'Mini-juegos',                        '=',  20, (select count(*) from public.minigames)),
  ('2 Catálogo', 'Pasos de lecciones',                 '=',  102,(select count(*) from public.lesson_steps)),
  ('2 Catálogo', 'Sellos',                             '=',  5,  (select count(*) from public.badges)),
  ('2 Catálogo', 'Tarjetas',                           '=',  4,  (select count(*) from public.cards)),
  ('2 Catálogo', 'Contenido p3-w1 (es)',               '>=', 1,  (select count(*) from public.lesson_contents lc join public.lessons l on l.id = lc.lesson_id
                                                                   where l.slug = 'p3-w1' and lc.language = 'es')),
  -- Demo organization
  ('3 Demo',     'Escuelas',                           '=',  2,  (select count(*) from public.schools)),
  ('3 Demo',     'Personal (perfiles)',                '=',  5,  (select count(*) from public.profiles)),
  ('3 Demo',     'Grupos',                             '=',  4,  (select count(*) from public.groups)),
  ('3 Demo',     'Código 3BAN27 existe',               '=',  1,  (select count(*) from public.groups where class_code = '3BAN27')),
  ('3 Demo',     'Estudiantes',                        '=',  15, (select count(*) from public.students)),
  ('3 Demo',     'Estudiantes con PIN',                '=',  15, (select count(*) from private.student_credentials)),
  ('3 Demo',     'Nadie bloqueado',                    '=',  0,  (select count(*) from private.student_credentials where locked_until > now())),
  -- Demo week story
  ('4 Semana',   'Asignaciones',                       '=',  3,  (select count(*) from public.assignments)),
  ('4 Semana',   'p3-w1 completada (de 12)',           '=',  10, (select count(*) from public.lesson_progress lp join public.lessons l on l.id = lp.lesson_id
                                                                   where l.slug = 'p3-w1' and lp.status = 'completed')),
  ('4 Semana',   'p3-w2 completada (de 12)',           '=',  5,  (select count(*) from public.lesson_progress lp join public.lessons l on l.id = lp.lesson_id
                                                                   where l.slug = 'p3-w2' and lp.status = 'completed')),
  ('4 Semana',   'Flores en jardines',                 '=',  15, (select count(*) from public.garden_items)),
  ('4 Semana',   'Sellos ganados',                     '=',  6,  (select count(*) from public.student_badges)),
  ('4 Semana',   'Check-ins cargados',                 '>=', 1,  (select count(*) from public.emotion_checkins)),
  ('4 Semana',   'Alertas activas (Carlos)',           '=',  1,  (select count(*) from public.alerts where status <> 'closed'))
)
select area, check_name,
       op || ' ' || expected as expected,
       actual,
       case when (op = '='  and actual =  expected)
              or (op = '>=' and actual >= expected) then '✅' else '❌' end as ok
from checks
order by area, check_name;

pm.test("resolve-class 200", () => pm.response.to.have.status(200));
const body = pm.response.json();
pm.test("3BAN27 has 12 students", () => pm.expect(body.students.length).to.eql(12));
pm.environment.set("group_id", body.group_id);

pm.test("verify 200", () => pm.response.to.have.status(200));
const body = pm.response.json();
pm.environment.set("student_token", body.access_token);
// Decode the JWT payload to check the hook added our claims
const claims = JSON.parse(atob(body.access_token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/")));
pm.test("hook: app_role = student", () => pm.expect(claims.app_role).to.eql("student"));
pm.test("hook: student_id present", () => pm.expect(claims.student_id).to.eql(pm.environment.get("maria_id")));

pm.test("my_week 200", () => pm.response.to.have.status(200));
const body = pm.response.json();
pm.test("María has a current lesson", () => pm.expect(body.current).to.not.be.null);
pm.test("teacher is Ana", () => pm.expect(body.teacher_name).to.include("Ana"));

pm.test("lesson content 200", () => pm.response.to.have.status(200));
pm.test("p3-w1 has 12 steps", () => pm.expect(pm.response.json()[0].payload.steps.length).to.eql(12));

pm.test("login Ana 200", () => pm.response.to.have.status(200));
pm.environment.set("teacher_token", pm.response.json().access_token);

pm.test("group_overview 200", () => pm.response.to.have.status(200));
const body = pm.response.json();
pm.test("12 students", () => pm.expect(body.students).to.eql(12));
pm.test("6 badges earned", () => pm.expect(body.badges_earned).to.eql(6));
pm.test("climate visible", () => pm.expect(body.climate.hidden).to.eql(false));