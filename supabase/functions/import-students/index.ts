// supabase/functions/import-students/index.ts
// DOC-01: a teacher loads the class list (parsed from Excel in the client) and gets an initial PIN per student.
import { createClient } from "npm:@supabase/supabase-js@2";

// ---------- Keys: new format first, legacy as fallback ----------
function readKey(newVar: string, legacyVar: string): string {
  const json = Deno.env.get(newVar);
  if (json) {
    try {
      const key = JSON.parse(json)?.default;
      if (typeof key === "string" && key.length > 0) return key;
    } catch {
      // not JSON: fall through to the legacy variable
    }
  }
  const legacy = Deno.env.get(legacyVar);
  if (!legacy) throw new Error(`Missing ${newVar} and ${legacyVar}`);
  return legacy;
}

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = readKey("SUPABASE_SECRET_KEYS", "SUPABASE_SERVICE_ROLE_KEY");
const MAX_STUDENTS = 60;

const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

// ---------- HTTP helpers ----------
const corsHeaders = {
  "Access-Control-Allow-Origin": "*", // TODO: restrict to the portal domain in production
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function fail(status: number, code: string, message: string): Response {
  return json(status, { error: { code, message } });
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

type Row = { row: number; display_name: string; code: string };

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return fail(405, "METHOD_NOT_ALLOWED", "Use POST");

  try {
    // 1. Who is calling? Ask Supabase Auth to validate the session token.
    const token = req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "");
    if (!token) return fail(401, "UNAUTHORIZED", "Missing session token");

    const { data: userData, error: userError } = await admin.auth.getUser(token);
    if (userError || !userData.user) return fail(401, "UNAUTHORIZED", "Invalid session");
    const userId = userData.user.id;

    // 2. Validate the body
    let body: { group_id?: unknown; students?: unknown };
    try {
      body = await req.json();
    } catch {
      return fail(400, "INVALID_JSON", "Body must be JSON");
    }
    const groupId = body.group_id;
    const students = body.students;
    if (typeof groupId !== "string" || !UUID_RE.test(groupId) || !Array.isArray(students)) {
      return fail(400, "INVALID_INPUT", "group_id and students[] are required");
    }
    if (students.length === 0 || students.length > MAX_STUDENTS) {
      return fail(400, "INVALID_INPUT", `Between 1 and ${MAX_STUDENTS} students`);
    }

    // 3. Only the active teacher of THIS group may import into it
    const [{ data: profile }, { data: group }] = await Promise.all([
      admin.from("profiles").select("role, active").eq("id", userId).maybeSingle(),
      admin.from("groups").select("id, teacher_id, active").eq("id", groupId).maybeSingle(),
    ]);
    if (!profile?.active || profile.role !== "teacher" || !group?.active || group.teacher_id !== userId) {
      return fail(403, "FORBIDDEN", "Only the teacher of this group can import students");
    }

    // 4. One student at a time: a bad row never blocks the others
    const created: unknown[] = [];
    const errors: Row[] = [];
    const warnings: Row[] = [];
    const seen = new Set<string>();

    for (const [index, raw] of students.entries()) {
      const row = index + 1;
      const name = typeof raw?.display_name === "string" ? raw.display_name.trim().replace(/\s+/g, " ") : "";
      const pin = typeof raw?.pin === "string" ? raw.pin : null;

      if (name.length < 2 || name.length > 60) {
        errors.push({ row, display_name: name, code: "INVALID_NAME" });
        continue;
      }
      const key = name.toLocaleLowerCase("es");
      if (seen.has(key)) {
        errors.push({ row, display_name: name, code: "DUPLICATE_IN_LIST" });
        continue;
      }
      seen.add(key);

      // Team decision: first name + first surname. More words → warn (compound names exist), don't block.
      if (name.split(" ").length > 2) {
        warnings.push({ row, display_name: name, code: "MORE_THAN_TWO_WORDS" });
      }

      const { data, error } = await admin.rpc("create_student_with_pin", {
        p_group_id: groupId,
        p_display_name: name,
        p_pin: pin,
        p_actor_id: userId,
      });

      if (error) {
        const code = error.code === "23505" ? "DUPLICATE_NAME"
          : error.code === "P0001" ? error.message
          : "INTERNAL_ERROR";
        if (code === "INTERNAL_ERROR") console.error(`[import-students] row ${row}:`, error.message);
        errors.push({ row, display_name: name, code });
        continue;
      }
      created.push(data);
    }

    return json(200, { created, errors, warnings });
  } catch (e) {
    console.error("[import-students]", e instanceof Error ? e.message : String(e));
    return fail(500, "INTERNAL_ERROR", "Unexpected error");
  }
});
