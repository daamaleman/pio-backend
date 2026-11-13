-- ============================================================
-- Migration: content of lesson p3-w1 "Reconozco lo que siento" (es, version 1)
-- DRAFT: texts to be validated by Margie (content) before the pilot.
-- ============================================================

delete from public.lesson_contents
where lesson_id = (select id from public.lessons where slug = 'p3-w1')
  and language = 'es' and version = 1;

insert into public.lesson_contents (lesson_id, language, version, schema_version, payload)
select l.id, 'es', 1, '1', $json$
{
  "lesson_slug": "p3-w1",
  "title": "Reconozco lo que siento",
  "parts": [
    { "part": 1, "title": "Aprendo",  "done_message": "¡Terminaste la parte 1! Mañana jugamos con las gotas." },
    { "part": 2, "title": "Practico", "done_message": "¡Qué bien jugaste! Mañana usamos lo aprendido." },
    { "part": 3, "title": "Lo uso",   "done_message": "¡Terminaste la lección! Tu flor ya está en tu jardín." }
  ],
  "steps": [
    {
      "position": 1, "kind": "story", "title": "El día de las gotas",
      "pages": [
        { "text": "Una mañana, Pío se despertó y vio cuatro gotas en su ventana. ¡Cada una tenía una carita diferente!",
          "image": "p3-w1/img/cuento-1.webp", "audio": "p3-w1/es/cuento-1.mp3", "pio_pose": "wave" },
        { "text": "La primera gota saltaba de felicidad: «¡Soy Alegría! Llego cuando te pasa algo bonito».",
          "image": "p3-w1/img/cuento-2.webp", "audio": "p3-w1/es/cuento-2.mp3", "pio_pose": "happy" },
        { "text": "La segunda gota hablaba bajito: «Soy Tristeza. Llego cuando extrañás a alguien o algo no sale como querías».",
          "image": "p3-w1/img/cuento-3.webp", "audio": "p3-w1/es/cuento-3.mp3", "pio_pose": "listening" },
        { "text": "La tercera gota resoplaba: «¡Soy Enojo! Llego cuando algo te parece injusto».",
          "image": "p3-w1/img/cuento-4.webp", "audio": "p3-w1/es/cuento-4.mp3", "pio_pose": "thinking" },
        { "text": "La cuarta gota temblaba un poquito: «Soy Miedo. Llego para cuidarte cuando algo parece peligroso».",
          "image": "p3-w1/img/cuento-5.webp", "audio": "p3-w1/es/cuento-5.mp3", "pio_pose": "encourage" },
        { "text": "Pío sonrió: «¡Todas vienen a contarme algo! Hoy vamos a aprender a reconocerlas».",
          "image": "p3-w1/img/cuento-6.webp", "audio": "p3-w1/es/cuento-6.mp3", "pio_pose": "celebrate" }
      ]
    },
    {
      "position": 2, "kind": "concept", "title": "Las cuatro gotas",
      "pio": { "pose": "happy", "text": "Cada gota tiene su carita. ¡Mirá!", "audio": "p3-w1/es/aprendo-1.mp3" },
      "body": "Las emociones son lo que sentimos por dentro. Hoy conocemos cuatro.",
      "items": [
        { "emotion": "joy",     "name": "Alegría",  "face": "Sonrisa grande y ojos brillantes", "example": "Cuando jugás con tus amigos" },
        { "emotion": "sadness", "name": "Tristeza", "face": "Boca hacia abajo y ojos llorosos", "example": "Cuando extrañás a alguien" },
        { "emotion": "anger",   "name": "Enojo",    "face": "Cejas juntas y dientes apretados", "example": "Cuando alguien rompe algo tuyo" },
        { "emotion": "fear",    "name": "Miedo",    "face": "Ojos muy abiertos",                "example": "Cuando escuchás un ruido fuerte de noche" }
      ],
      "key_message": "Alegría, Tristeza, Enojo y Miedo: ¡ya las conocés!"
    },
    {
      "position": 3, "kind": "concept", "title": "Mi cuerpo también siente",
      "pio": { "pose": "thinking", "text": "¿Sabías que las emociones también se sienten en el cuerpo?", "audio": "p3-w1/es/aprendo-2.mp3" },
      "body": "Cuando una gota nos visita, el cuerpo nos da pistas.",
      "items": [
        { "emotion": "joy",     "name": "Alegría",  "body_hint": "Cosquillas en la panza y ganas de saltar" },
        { "emotion": "sadness", "name": "Tristeza", "body_hint": "El pecho pesado y ganas de llorar" },
        { "emotion": "anger",   "name": "Enojo",    "body_hint": "Calor en la cara y las manos apretadas" },
        { "emotion": "fear",    "name": "Miedo",    "body_hint": "El corazón rápido y las piernas temblorosas" }
      ],
      "key_message": "Escuchar a tu cuerpo te ayuda a saber qué sentís."
    },
    {
      "position": 4, "kind": "concept", "title": "Todas son normales",
      "pio": { "pose": "encourage", "text": "Te cuento un secreto…", "audio": "p3-w1/es/aprendo-3.mp3" },
      "body": "No hay emociones buenas ni malas. Todas las personas sienten alegría, tristeza, enojo y miedo: los niños, las niñas y también las personas grandes.",
      "items": [
        { "text": "Está bien sentir tristeza." },
        { "text": "Está bien sentir enojo, sin lastimar a nadie." },
        { "text": "Está bien sentir miedo y pedir ayuda." }
      ],
      "key_message": "Todas las emociones son normales. Lo importante es lo que hacemos con ellas."
    },
    {
      "position": 5, "kind": "worked_example", "title": "Ayudemos a Tito",
      "pio": { "pose": "thinking", "text": "Vamos a descubrir juntos qué gota visitó a Tito.", "audio": "p3-w1/es/ejemplo.mp3" },
      "situation": "Tito llegó a la escuela y su mejor amigo le había guardado un asiento a su lado.",
      "image": "p3-w1/img/ejemplo-tito.webp",
      "steps": [
        { "label": "1. Mirá su carita", "text": "Tito está sonriendo y tiene los ojos brillantes." },
        { "label": "2. Pensá qué pasó", "text": "Su amigo se acordó de él y lo esperó." },
        { "label": "3. Nombrá la gota", "text": "¡Es Alegría!" }
      ],
      "conclusion": "Mirar la carita y pensar qué pasó nos ayuda a reconocer las emociones."
    },
    {
      "position": 6, "kind": "minigame", "title": "Atrapa gota",
      "template": "catch",
      "pio": { "pose": "celebrate", "text": "¡A jugar! Atrapá la gota que corresponde.", "audio": "p3-w1/es/juego1-intro.mp3" },
      "instructions": "Escuchá la situación y atrapá la gota que siente esa persona.",
      "learn": {
        "this_is":  { "prompt": "Esta es {emotion}", "emotions": ["joy", "sadness", "anger", "fear"] },
        "show_me":  { "prompt": "Mostrame la gota de {emotion}" },
        "which_is": { "prompt": "¿Cuál es esta gota?" }
      },
      "play": {
        "rounds": 3, "speed": "slow",
        "targets": ["joy", "sadness", "anger", "fear"],
        "situations": [
          { "id": "s1", "text": "Te regalaron un helado.",                          "answer": "joy",     "audio": "p3-w1/es/sit-1.mp3" },
          { "id": "s2", "text": "Tu abuela vino a visitarte.",                      "answer": "joy",     "audio": "p3-w1/es/sit-2.mp3" },
          { "id": "s3", "text": "Tu perrito se escondió y no lo encontrás.",        "answer": "sadness", "audio": "p3-w1/es/sit-3.mp3" },
          { "id": "s4", "text": "Tu mejor amiga se cambió de escuela.",             "answer": "sadness", "audio": "p3-w1/es/sit-4.mp3" },
          { "id": "s5", "text": "Alguien rompió tu dibujo sin pedir permiso.",      "answer": "anger",   "audio": "p3-w1/es/sit-5.mp3" },
          { "id": "s6", "text": "No te dejaron jugar aunque era tu turno.",         "answer": "anger",   "audio": "p3-w1/es/sit-6.mp3" },
          { "id": "s7", "text": "Escuchás un trueno muy fuerte en la noche.",       "answer": "fear",    "audio": "p3-w1/es/sit-7.mp3" },
          { "id": "s8", "text": "Por un momento no ves a tu mamá en el mercado.",   "answer": "fear",    "audio": "p3-w1/es/sit-8.mp3" }
        ]
      },
      "feedback": {
        "correct": ["¡Bien! La atrapaste.", "¡Eso es!", "¡Qué buen ojo!"],
        "error_hint": "Mirá la carita de Pío. ¿Cómo se siente?"
      }
    },
    {
      "position": 7, "kind": "minigame", "title": "¿Dónde siento mis emociones?",
      "template": "drag_to_zones",
      "pio": { "pose": "listening", "text": "Llevá cada gota al lugar del cuerpo donde la sentís.", "audio": "p3-w1/es/juego2-intro.mp3" },
      "instructions": "Arrastrá la gota a tu cabeza, tu pecho, tu panza o tus manos. No hay respuestas incorrectas.",
      "no_wrong_answer": true,
      "zones": [
        { "id": "head",  "label": "Cabeza" },
        { "id": "chest", "label": "Pecho" },
        { "id": "belly", "label": "Panza" },
        { "id": "hands", "label": "Manos" }
      ],
      "prompts": [
        { "emotion": "joy",     "text": "¿Dónde sentís la Alegría?" },
        { "emotion": "sadness", "text": "¿Dónde sentís la Tristeza?" },
        { "emotion": "anger",   "text": "¿Dónde sentís el Enojo?" },
        { "emotion": "fear",    "text": "¿Dónde sentís el Miedo?" }
      ],
      "feedback": { "after_each": "¡Gracias por contarme! Cada cuerpo siente a su manera." }
    },
    {
      "position": 8, "kind": "quiz", "title": "¿Qué gota es?",
      "pio": { "pose": "thinking", "text": "Tres preguntas cortitas. ¡Vos podés!", "audio": "p3-w1/es/quiz-intro.mp3" },
      "questions": [
        { "id": "q1", "prompt": "Lucía recibió una carta de su papá, que trabaja lejos. Sonríe y salta. ¿Qué gota la visitó?",
          "options": [ { "id": "joy", "text": "Alegría" }, { "id": "sadness", "text": "Tristeza" }, { "id": "fear", "text": "Miedo" } ],
          "answer_id": "joy", "explanation": "Lucía sonríe y salta: ¡es Alegría!" },
        { "id": "q2", "prompt": "Mario no encuentra su cuaderno favorito y tiene los ojos llorosos. ¿Qué gota lo visitó?",
          "options": [ { "id": "anger", "text": "Enojo" }, { "id": "sadness", "text": "Tristeza" }, { "id": "joy", "text": "Alegría" } ],
          "answer_id": "sadness", "explanation": "Los ojos llorosos nos dan una pista: es Tristeza." },
        { "id": "q3", "prompt": "¿Cuál de estas frases es verdadera?",
          "options": [ { "id": "a", "text": "Hay emociones malas que no debemos sentir." },
                       { "id": "b", "text": "Todas las emociones son normales." },
                       { "id": "c", "text": "Solo los niños sienten miedo." } ],
          "answer_id": "b", "explanation": "Todas las emociones son normales. Lo importante es lo que hacemos con ellas." }
      ],
      "feedback": { "correct": "¡Muy bien!", "retry": "Casi. Leé otra vez y probá de nuevo." }
    },
    {
      "position": 9, "kind": "application", "title": "Lo uso en mi vida",
      "pio": { "pose": "listening", "text": "Ahora pensá en vos.", "audio": "p3-w1/es/aplico.mp3" },
      "prompt": "¿Cuándo te visitó hoy alguna de estas gotas? Contámelo con tu voz o con un dibujo.",
      "response_modes": ["voice", "drawing"],
      "privacy_note": "Esto es solo para vos. No se envía a nadie."
    },
    {
      "position": 10, "kind": "card", "title": "Mi tarjeta",
      "card_key": "mis_gotas",
      "front": { "title": "Mis gotas", "text": "Alegría, Tristeza, Enojo y Miedo. Todas son normales.", "image": "p3-w1/img/tarjeta.webp" },
      "back":  { "text": "Cuando no sé qué siento, miro mi carita y escucho a mi cuerpo." }
    },
    {
      "position": 11, "kind": "home", "title": "Reto en casa",
      "pio": { "pose": "wave", "text": "¡Un reto para hacer en familia!", "audio": "p3-w1/es/casa.mp3" },
      "challenge": "Hoy en la cena, cada persona cuenta qué gota la visitó y por qué.",
      "family_note": "Para la familia: escuchen sin corregir ni regañar. Todas las emociones son válidas."
    },
    {
      "position": 12, "kind": "calm", "title": "Calma y flor",
      "pio": { "pose": "calm", "text": "Antes de terminar, respiremos juntos.", "audio": "p3-w1/es/calma.mp3" },
      "breathing": { "rounds": 3, "inhale_s": 4, "hold_s": 2, "exhale_s": 4 },
      "closing": "¡Muy bien! Sembraste tu flor de Alegría en tu jardín.",
      "reward": { "flower": "joy" }
    }
  ]
}
$json$::jsonb
from public.lessons l
where l.slug = 'p3-w1';