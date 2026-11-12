-- ============================================================
-- Migration: load the MVP content catalog (real content, all environments)
--   3.º grado "Cuido mi mente y mi corazón"  ·  1.er año "Crezco, decido y me cuido"
-- Upserts by slug/code so it is safe to re-apply and to copy for future corrections.
-- ============================================================

-- ---------- Badges ----------
insert into public.badges (code, level, name) values
  ('me_calmo',             'primary',   '{"es": "Me calmo"}'),
  ('nadie_se_queda_fuera', 'primary',   '{"es": "Nadie se queda fuera"}'),
  ('soy_valioso',          'primary',   '{"es": "Soy valioso"}'),
  ('me_cuido_en_linea',    'secondary', '{"es": "Me cuido en línea"}'),
  ('digo_no_sin_pelear',   'secondary', '{"es": "Digo no sin pelear"}')
on conflict (code) do update
  set level = excluded.level,
      name  = excluded.name;

-- ---------- Lessons (4 per grade) ----------
insert into public.lessons
  (slug, level, grade, week, title, emotion, duration_min, parts_count, is_month_closure,
   family_note, home_challenge, status)
values
  ('p3-w1', 'primary', 3, 1, '{"es": "Reconozco lo que siento"}',   'joy',   20, 3, false,
   '{"es": "Escuchá sin juzgar. Evitá decir «no llorés». Bastan 5 a 10 minutos, sin presión. Si notás malestar por varios días, avisale a la maestra."}',
   '{"es": "Repetí el juego con tu familia: ¿qué gota te visitó hoy y por qué?"}',
   'published'),
  ('p3-w2', 'primary', 3, 2, '{"es": "Me calmo y me controlo"}',    'anger', 20, 3, false, null, null, 'published'),
  ('p3-w3', 'primary', 3, 3, '{"es": "Buen trato para todos"}',     'love',  20, 3, false, null, null, 'published'),
  ('p3-w4', 'primary', 3, 4, '{"es": "Soy valioso y pido ayuda"}',  'calm',  20, 3, true,  null, null, 'published'),

  ('s1-w1', 'secondary', 1, 1, '{"es": "Estoy cambiando"}',            'joy',   25, 4, false, null, null, 'published'),
  ('s1-w2', 'secondary', 1, 2, '{"es": "Mi vida en las redes"}',       'fear',  25, 4, false, null, null, 'published'),
  ('s1-w3', 'secondary', 1, 3, '{"es": "Digo no y decido"}',           'anger', 25, 4, false, null, null, 'published'),
  ('s1-w4', 'secondary', 1, 4, '{"es": "Mi proyecto y mi bienestar"}', 'calm',  25, 4, true,  null, null, 'published')
on conflict (slug) do update
  set level            = excluded.level,
      grade            = excluded.grade,
      week             = excluded.week,
      title            = excluded.title,
      emotion          = excluded.emotion,
      duration_min     = excluded.duration_min,
      parts_count      = excluded.parts_count,
      is_month_closure = excluded.is_month_closure,
      family_note      = excluded.family_note,
      home_challenge   = excluded.home_challenge,
      status           = excluded.status;


-- ---------- Minigames (catalog of the spec, §17) ----------
insert into public.minigames
  (slug, lesson_id, number_in_unit, name, template, plan_content, indicator,
   achievement_rules, teacher_evidence, badge_code)
select v.slug, l.id, v.number_in_unit, jsonb_build_object('es', v.name_es),
       v.template::public.game_template, v.plan_content, v.indicator,
       v.rules::jsonb, v.evidence, v.badge_code
from (values
  -- ===== 3.º grado =====
  ('p3-01-atrapa-gota', 'p3-w1', 1, 'Atrapa gota', 'catch',
   '1. Las emociones: alegría, tristeza, enojo y miedo. 1.2 Todas las emociones son normales',
   'Nombra al menos 4 emociones en situaciones distintas',
   '{"metric": "distinct_emotions_correct", "total": 4, "achieved_min": 4, "in_progress_min": 2}',
   'Aciertos por emoción', null),
  ('p3-02-donde-siento', 'p3-w1', 2, '¿Dónde siento mis emociones?', 'drag_to_zones',
   '1.1 ¿Dónde siento mis emociones?',
   'Relaciona al menos 3 emociones con una sensación del cuerpo',
   '{"metric": "emotions_mapped", "total": 4, "achieved_min": 3, "in_progress_min": 1}',
   'Mapa del cuerpo (solo docente)', null),
  ('p3-03-semaforo', 'p3-w2', 3, 'El semáforo de la calma', 'sequence',
   '2. Manejo de emociones. 2.1 El semáforo de la calma',
   'Ordena «paro, respiro, pienso» y elige la reacción adecuada en 2 de 3',
   '{"metric": "correct", "total": 3, "achieved_min": 2, "in_progress_min": 1}',
   'Situaciones resueltas y acción', null),
  ('p3-04-globo', 'p3-w2', 4, 'La respiración del globo', 'guided_breathing',
   '2.2 La respiración del globo',
   'Completa 3 rondas',
   '{"metric": "rounds_completed", "total": 3, "achieved_min": 3, "in_progress_min": 1}',
   'Rondas y emoción antes/después', null),
  ('p3-05-enojo-sin-lastimar', 'p3-w2', 5, 'Enojo sin lastimar', 'classify',
   '2.3 Expresar el enojo sin lastimar',
   'Clasifica al menos 6 de 8',
   '{"metric": "correct", "total": 8, "achieved_min": 6, "in_progress_min": 4}',
   'Aciertos y forma elegida', 'me_calmo'),
  ('p3-06-buen-trato', 'p3-w3', 6, '¿Buen trato o maltrato?', 'classify',
   '3.1 Buen trato y maltrato',
   'Distingue en al menos 5 de 6',
   '{"metric": "correct", "total": 6, "achieved_min": 5, "in_progress_min": 3}',
   'Aciertos y escena arreglada', null),
  ('p3-07-zapatos-de-otro', 'p3-w3', 7, 'En los zapatos de otro', 'branching_story',
   '3.2 Empatía',
   'Identifica la emoción del otro y propone una acción de ayuda',
   '{"metric": "items_completed", "total": 2, "achieved_min": 2, "in_progress_min": 1}',
   'Emociones identificadas y acción', null),
  ('p3-08-tesoro-de-todos', 'p3-w3', 8, 'El tesoro de todos', 'cooperative',
   '3.3 Nadie se queda fuera',
   'Incluye a todos y propone una forma de incluir',
   '{"metric": "items_completed", "total": 2, "achieved_min": 2, "in_progress_min": 1}',
   'Participación y propuesta', 'nadie_se_queda_fuera'),
  ('p3-09-escudo', 'p3-w4', 9, 'Mi escudo de superhéroe', 'builder',
   '4. Me valoro. 4.1 Mis cualidades. 4.2 Equivocarme también es aprender',
   'Elige 3 cualidades propias y 1 de un compañero',
   '{"metric": "items_completed", "total": 4, "achieved_min": 4, "in_progress_min": 2}',
   'Escudo terminado (lista de cotejo)', 'soy_valioso'),
  ('p3-10-adultos-confianza', 'p3-w4', 10, 'Mis adultos de confianza', 'builder',
   '4.3 Adultos de confianza. Cierre y autoevaluación',
   'Identifica al menos 2 adultos de confianza y completa la autoevaluación',
   '{"metric": "items_completed", "total": 3, "achieved_min": 3, "in_progress_min": 1}',
   'Adultos identificados, autoevaluación y resumen del mes', null),

  -- ===== 1.er año =====
  ('s1-01-mitos-verdades', 's1-w1', 1, 'Mitos y verdades de la adolescencia', 'true_myth_trivia',
   '1. La adolescencia. 1.1 Cambios del cuerpo, emociones y relaciones',
   'Responde 7 de 10 y reconoce que los cambios son normales y distintos',
   '{"metric": "correct", "total": 10, "achieved_min": 7, "in_progress_min": 5}',
   'Aciertos por tema', null),
  ('s1-02-yo-antes-ahora', 's1-w1', 2, 'Yo antes, yo ahora', 'journal',
   '1.2 Cada persona es diferente. 1.3 Aceptar y respetar',
   'Completa «Yo antes, yo ahora» y responde situaciones de respeto',
   '{"metric": "items_completed", "total": 2, "achieved_min": 2, "in_progress_min": 1}',
   'Participación (sin contenido) y preguntas anónimas en el buzón', null),
  ('s1-03-real-o-filtrado', 's1-w2', 3, '¿Real o filtrado?', 'compare_images',
   '2.2 Comparación y «vidas perfectas»',
   'Identifica trucos de edición y nombra un efecto de compararse',
   '{"metric": "correct", "total": 6, "achieved_min": 4, "in_progress_min": 2}',
   'Aciertos y participación', null),
  ('s1-04-semaforo-digital', 's1-w2', 4, 'Semáforo digital', 'classify',
   '2.3 Privacidad y contenido incómodo',
   'Clasifica 7 de 9 y nombra a quién pedir ayuda',
   '{"metric": "correct", "total": 9, "achieved_min": 7, "in_progress_min": 5}',
   'Aciertos por color', 'me_cuido_en_linea'),
  ('s1-05-reglas-pantalla', 's1-w2', 5, 'Mis 3 reglas de pantalla', 'builder',
   '2.1 Tiempo en pantalla y descanso',
   'Formula 3 reglas claras y realistas',
   '{"metric": "items_completed", "total": 3, "achieved_min": 3, "in_progress_min": 1}',
   'Reglas escritas', null),
  ('s1-06-pasivo-agresivo-asertivo', 's1-w3', 6, 'Pasivo, agresivo o asertivo', 'classify',
   '3.2 Comunicación pasiva, agresiva y asertiva',
   'Distingue los 3 estilos y escribe una respuesta asertiva',
   '{"metric": "items_completed", "total": 2, "achieved_min": 2, "in_progress_min": 1}',
   'Aciertos y respuesta creada', 'digo_no_sin_pelear'),
  ('s1-07-elige-aventura', 's1-w3', 7, 'Elige tu aventura', 'branching_story',
   '3.1 Presión de grupo',
   'Llega a un final responsable e identifica la presión de grupo',
   '{"metric": "items_completed", "total": 2, "achieved_min": 2, "in_progress_min": 1}',
   'Decisiones (resumen sin juicio)', null),
  ('s1-08-amistad-sana', 's1-w3', 8, '¿Amistad sana o no?', 'classify',
   '3.3 Amistades sanas',
   'Clasifica 8 de 10',
   '{"metric": "correct", "total": 10, "achieved_min": 8, "in_progress_min": 6}',
   'Aciertos', null),
  ('s1-09-metas-semana', 's1-w4', 9, 'Mi mapa de metas · Mi semana saludable', 'builder',
   '4.1 Mis metas. 4.2 Hábitos que cuidan mi mente',
   'Una meta con pasos y al menos 2 hábitos',
   '{"metric": "items_completed", "total": 3, "achieved_min": 3, "in_progress_min": 1}',
   'Meta y hábitos', null),
  ('s1-10-red-apoyo', 's1-w4', 10, 'Mi red de apoyo · Trivia final', 'builder',
   '4.3 A quién acudo. Cierre y autoevaluación',
   'Identifica 2 personas de apoyo y completa la autoevaluación',
   '{"metric": "items_completed", "total": 3, "achieved_min": 3, "in_progress_min": 1}',
   'Red de apoyo, trivia y autoevaluación', null)
) as v(slug, lesson_slug, number_in_unit, name_es, template, plan_content, indicator, rules, evidence, badge_code)
join public.lessons l on l.slug = v.lesson_slug
on conflict (slug) do update
  set lesson_id         = excluded.lesson_id,
      number_in_unit    = excluded.number_in_unit,
      name              = excluded.name,
      template          = excluded.template,
      plan_content      = excluded.plan_content,
      indicator         = excluded.indicator,
      achievement_rules = excluded.achievement_rules,
      teacher_evidence  = excluded.teacher_evidence,
      badge_code        = excluded.badge_code;

-- ---------- Lesson steps ----------
-- columns: lesson_slug, position, part, kind, minigame_slug, is_private, is_skippable
insert into public.lesson_steps (lesson_id, position, part, kind, minigame_id, is_private, is_skippable)
select l.id, v.position, v.part, v.kind::public.step_kind, m.id, v.is_private, v.is_skippable
from (values
  -- ===== p3-w1 · Reconozco lo que siento (2 minigames → 12 steps) =====
  ('p3-w1',  1, 1, 'story',          null::text,                 false, false),
  ('p3-w1',  2, 1, 'concept',        null,                       false, false),
  ('p3-w1',  3, 1, 'concept',        null,                       false, false),
  ('p3-w1',  4, 1, 'concept',        null,                       false, false),
  ('p3-w1',  5, 1, 'worked_example', null,                       false, false),
  ('p3-w1',  6, 2, 'minigame',       'p3-01-atrapa-gota',        false, false),
  ('p3-w1',  7, 2, 'minigame',       'p3-02-donde-siento',       false, false),
  ('p3-w1',  8, 2, 'quiz',           null,                       false, false),
  ('p3-w1',  9, 3, 'application',    null,                       true,  true),
  ('p3-w1', 10, 3, 'card',           null,                       false, false),
  ('p3-w1', 11, 3, 'home',           null,                       false, false),
  ('p3-w1', 12, 3, 'calm',           null,                       false, false),

  -- ===== p3-w2 · Me calmo y me controlo (3 minigames → 13 steps) =====
  ('p3-w2',  1, 1, 'story',          null,                       false, false),
  ('p3-w2',  2, 1, 'concept',        null,                       false, false),
  ('p3-w2',  3, 1, 'concept',        null,                       false, false),
  ('p3-w2',  4, 1, 'concept',        null,                       false, false),
  ('p3-w2',  5, 1, 'worked_example', null,                       false, false),
  ('p3-w2',  6, 2, 'minigame',       'p3-03-semaforo',           false, false),
  ('p3-w2',  7, 2, 'minigame',       'p3-04-globo',              false, false),
  ('p3-w2',  8, 2, 'minigame',       'p3-05-enojo-sin-lastimar', false, false),
  ('p3-w2',  9, 2, 'quiz',           null,                       false, false),
  ('p3-w2', 10, 3, 'application',    null,                       true,  true),
  ('p3-w2', 11, 3, 'card',           null,                       false, false),
  ('p3-w2', 12, 3, 'home',           null,                       false, false),
  ('p3-w2', 13, 3, 'calm',           null,                       false, false),

  -- ===== p3-w3 · Buen trato para todos (3 minigames → 13 steps) =====
  ('p3-w3',  1, 1, 'story',          null,                       false, false),
  ('p3-w3',  2, 1, 'concept',        null,                       false, false),
  ('p3-w3',  3, 1, 'concept',        null,                       false, false),
  ('p3-w3',  4, 1, 'concept',        null,                       false, false),
  ('p3-w3',  5, 1, 'worked_example', null,                       false, false),
  ('p3-w3',  6, 2, 'minigame',       'p3-06-buen-trato',         false, false),
  ('p3-w3',  7, 2, 'minigame',       'p3-07-zapatos-de-otro',    false, false),
  ('p3-w3',  8, 2, 'minigame',       'p3-08-tesoro-de-todos',    false, false),
  ('p3-w3',  9, 2, 'quiz',           null,                       false, false),
  ('p3-w3', 10, 3, 'application',    null,                       true,  true),
  ('p3-w3', 11, 3, 'card',           null,                       false, false),
  ('p3-w3', 12, 3, 'home',           null,                       false, false),
  ('p3-w3', 13, 3, 'calm',           null,                       false, false),

  -- ===== p3-w4 · Soy valioso y pido ayuda (2 minigames → 12 steps, month closure) =====
  ('p3-w4',  1, 1, 'story',          null,                       false, false),
  ('p3-w4',  2, 1, 'concept',        null,                       false, false),
  ('p3-w4',  3, 1, 'concept',        null,                       false, false),
  ('p3-w4',  4, 1, 'concept',        null,                       false, false),
  ('p3-w4',  5, 1, 'worked_example', null,                       false, false),
  ('p3-w4',  6, 2, 'minigame',       'p3-09-escudo',             false, false),
  ('p3-w4',  7, 2, 'minigame',       'p3-10-adultos-confianza',  false, false),
  ('p3-w4',  8, 2, 'quiz',           null,                       false, false),
  ('p3-w4',  9, 3, 'application',    null,                       true,  true),
  ('p3-w4', 10, 3, 'card',           null,                       false, false),
  ('p3-w4', 11, 3, 'home',           null,                       false, false),
  ('p3-w4', 12, 3, 'calm',           null,                       false, false),

  -- ===== s1-w1 · Estoy cambiando (2 minigames + practice → 13 steps) =====
  ('s1-w1',  1, 1, 'poll',           null,                       false, false),
  ('s1-w1',  2, 1, 'concept',        null,                       false, false),
  ('s1-w1',  3, 1, 'concept',        null,                       false, false),
  ('s1-w1',  4, 1, 'concept',        null,                       false, false),
  ('s1-w1',  5, 2, 'concept',        null,                       false, false),
  ('s1-w1',  6, 2, 'worked_example', null,                       false, false),
  ('s1-w1',  7, 2, 'quiz',           null,                       false, false),
  ('s1-w1',  8, 3, 'minigame',       's1-01-mitos-verdades',     false, false),
  ('s1-w1',  9, 3, 'minigame',       's1-02-yo-antes-ahora',     true,  false),
  ('s1-w1', 10, 3, 'practice',       null,                       false, false),
  ('s1-w1', 11, 4, 'plan',           null,                       true,  false),
  ('s1-w1', 12, 4, 'home',           null,                       false, false),
  ('s1-w1', 13, 4, 'summary',        null,                       false, false),

  -- ===== s1-w2 · Mi vida en las redes (3 minigames → 13 steps) =====
  ('s1-w2',  1, 1, 'poll',           null,                       false, false),
  ('s1-w2',  2, 1, 'concept',        null,                       false, false),
  ('s1-w2',  3, 1, 'concept',        null,                       false, false),
  ('s1-w2',  4, 1, 'concept',        null,                       false, false),
  ('s1-w2',  5, 2, 'concept',        null,                       false, false),
  ('s1-w2',  6, 2, 'worked_example', null,                       false, false),
  ('s1-w2',  7, 2, 'quiz',           null,                       false, false),
  ('s1-w2',  8, 3, 'minigame',       's1-03-real-o-filtrado',    false, false),
  ('s1-w2',  9, 3, 'minigame',       's1-04-semaforo-digital',   false, false),
  ('s1-w2', 10, 3, 'minigame',       's1-05-reglas-pantalla',    false, false),
  ('s1-w2', 11, 4, 'plan',           null,                       true,  false),
  ('s1-w2', 12, 4, 'home',           null,                       false, false),
  ('s1-w2', 13, 4, 'summary',        null,                       false, false),

  -- ===== s1-w3 · Digo no y decido (3 minigames → 13 steps) =====
  ('s1-w3',  1, 1, 'poll',           null,                       false, false),
  ('s1-w3',  2, 1, 'concept',        null,                       false, false),
  ('s1-w3',  3, 1, 'concept',        null,                       false, false),
  ('s1-w3',  4, 1, 'concept',        null,                       false, false),
  ('s1-w3',  5, 2, 'concept',        null,                       false, false),
  ('s1-w3',  6, 2, 'worked_example', null,                       false, false),
  ('s1-w3',  7, 2, 'quiz',           null,                       false, false),
  ('s1-w3',  8, 3, 'minigame',       's1-06-pasivo-agresivo-asertivo', false, false),
  ('s1-w3',  9, 3, 'minigame',       's1-07-elige-aventura',     false, false),
  ('s1-w3', 10, 3, 'minigame',       's1-08-amistad-sana',       false, false),
  ('s1-w3', 11, 4, 'plan',           null,                       true,  false),
  ('s1-w3', 12, 4, 'home',           null,                       false, false),
  ('s1-w3', 13, 4, 'summary',        null,                       false, false),

  -- ===== s1-w4 · Mi proyecto y mi bienestar (2 minigames + practice → 13 steps, month closure) =====
  ('s1-w4',  1, 1, 'poll',           null,                       false, false),
  ('s1-w4',  2, 1, 'concept',        null,                       false, false),
  ('s1-w4',  3, 1, 'concept',        null,                       false, false),
  ('s1-w4',  4, 1, 'concept',        null,                       false, false),
  ('s1-w4',  5, 2, 'concept',        null,                       false, false),
  ('s1-w4',  6, 2, 'worked_example', null,                       false, false),
  ('s1-w4',  7, 2, 'quiz',           null,                       false, false),
  ('s1-w4',  8, 3, 'minigame',       's1-09-metas-semana',       false, false),
  ('s1-w4',  9, 3, 'minigame',       's1-10-red-apoyo',          false, false),
  ('s1-w4', 10, 3, 'practice',       null,                       false, false),
  ('s1-w4', 11, 4, 'plan',           null,                       true,  false),
  ('s1-w4', 12, 4, 'home',           null,                       false, false),
  ('s1-w4', 13, 4, 'summary',        null,                       false, false)
) as v(lesson_slug, position, part, kind, minigame_slug, is_private, is_skippable)
join public.lessons l on l.slug = v.lesson_slug
left join public.minigames m on m.slug = v.minigame_slug
on conflict (lesson_id, position) do update
  set part         = excluded.part,
      kind         = excluded.kind,
      minigame_id  = excluded.minigame_id,
      is_private   = excluded.is_private,
      is_skippable = excluded.is_skippable;

-- ---------- Collectible cards (primary, one per lesson — provisional names) ----------
insert into public.cards (code, lesson_id, name)
select v.code, l.id, jsonb_build_object('es', v.name_es)
from (values
  ('mis_gotas',     'p3-w1', 'Mis gotas de emociones'),
  ('mi_semaforo',   'p3-w2', 'Mi semáforo de la calma'),
  ('buen_trato',    'p3-w3', 'El buen trato'),
  ('mis_adultos',   'p3-w4', 'Mis adultos de confianza')
) as v(code, lesson_slug, name_es)
join public.lessons l on l.slug = v.lesson_slug
on conflict (code) do update
  set lesson_id = excluded.lesson_id,
      name      = excluded.name;

