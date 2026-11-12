// Student login: class code + name + PIN → Supabase session for the student's shadow user.
import { createClient } from "npm:@supabase/supabase-js@2";

// ---------- Environment (injected automatically by Supabase) ----------
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

// ---------- Tunable limits ----------
const RESOLVE_LIMIT = { max: 20, windowSeconds: 600 }; // class-code lookups per IP / 10 min
const VERIFY_LIMIT = { max: 30, windowSeconds: 600 };  // PIN attempts per IP / 10 min (all students)
const SHADOW_EMAIL_DOMAIN = "students.pio.invalid";    // never routable, never used to send email

// Admin client: bypasses RLS. Lives ONLY here, never in the apps.
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

function fail(status: number, code: string, message: string, extra: Record<string, unknown> = {}): Response {
  return json(status, { error: { code, message, ...extra } });
}

function clientIp(req: Request): string {
  return req.headers.get("x-forwarded-for")?.split(",")[0].trim() ?? "unknown";
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const isUuid = (v: unknown): v is string => typeof v === "string" && UUID_RE.test(v);

async function withinLimit(key: string, limit: { max: number; windowSeconds: number }): Promise<boolean> {
  const { data, error } = await admin.rpc("check_rate_limit", {
    p_key: key,
    p_max: limit.max,
    p_window_seconds: limit.windowSeconds,
  });
  if (error) throw error;
  return data === true;
}

// ---------- POST /resolve-class ----------
async function resolveClass(req: Request, body: Record<string, unknown>): Promise<Response> {
  const classCode = typeof body.class_code === "string" ? body.class_code : "";
  if (classCode.replace(/[^a-z0-9]/gi, "").length < 6) {
    return fail(400, "INVALID_INPUT", "class_code is required");
  }

  if (!(await withinLimit(`resolve:${clientIp(req)}`, RESOLVE_LIMIT))) {
    return fail(429, "RATE_LIMITED", "Too many class code attempts");
  }

  const { data, error } = await admin.rpc("resolve_class_code", { p_class_code: classCode });
  if (error) throw error;
  if (!data) return fail(404, "CLASS_NOT_FOUND", "Class code not found");

  return json(200, data);
}

// ---------- Shadow auth user ----------
// Created lazily on the first successful login if the student doesn't have one yet.
async function ensureShadowUser(studentId: string, authUserId: string | null): Promise<string> {
  if (authUserId) return authUserId;

  const { data, error } = await admin.auth.admin.createUser({
    email: `${studentId}@${SHADOW_EMAIL_DOMAIN}`,
    email_confirm: true,
    app_metadata: { kind: "student_shadow" },
  });
  if (error) throw error;

  const { error: linkError } = await admin
    .from("students")
    .update({ auth_user_id: data.user.id })
    .eq("id", studentId);
  if (linkError) throw linkError;

  return data.user.id;
}

// ---------- Issue a real Supabase session for the shadow user ----------
// 1) generateLink creates a one-time magic-link token (NO email is sent)
// 2) verifyOtp exchanges it server-side for access_token + refresh_token
async function issueSession(authUserId: string) {
  const { data: userData, error: userError } = await admin.auth.admin.getUserById(authUserId);
  if (userError || !userData.user?.email) throw userError ?? new Error("Shadow user has no email");

  const { data: link, error: linkError } = await admin.auth.admin.generateLink({
    type: "magiclink",
    email: userData.user.email,
  });
  if (linkError) throw linkError;

  const publicClient = createClient(SUPABASE_URL, ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: otp, error: otpError } = await publicClient.auth.verifyOtp({
    type: "email",
    token_hash: link.properties.hashed_token,
  });
  if (otpError || !otp.session) throw otpError ?? new Error("Could not create session");

  return otp.session;
}

// ---------- POST /verify ----------
const PIN_ERROR_STATUS: Record<string, number> = {
  STUDENT_NOT_FOUND: 404,
  INVALID_PIN_FORMAT: 400,
  PIN_NOT_SET: 409,
  INVALID_PIN: 401,
  PIN_LOCKED: 423,
};

async function verify(req: Request, body: Record<string, unknown>): Promise<Response> {
  const { group_id, student_id, pin } = body;
  if (!isUuid(group_id) || !isUuid(student_id) || typeof pin !== "string") {
    return fail(400, "INVALID_INPUT", "group_id, student_id and pin are required");
  }

  if (!(await withinLimit(`verify:${clientIp(req)}`, VERIFY_LIMIT))) {
    return fail(429, "RATE_LIMITED", "Too many PIN attempts");
  }

  const { data, error } = await admin.rpc("verify_student_pin", {
    p_group_id: group_id,
    p_student_id: student_id,
    p_pin: pin,
  });
  if (error) throw error;

  if (!data.ok) {
    const { ok: _ok, code, ...extra } = data;
    return fail(PIN_ERROR_STATUS[code] ?? 400, code, "PIN verification failed", extra);
  }

  const authUserId = await ensureShadowUser(data.student_id, data.auth_user_id);
  const session = await issueSession(authUserId);

  return json(200, {
    access_token: session.access_token,
    refresh_token: session.refresh_token,
    expires_in: session.expires_in,
    expires_at: session.expires_at,
    token_type: "bearer",
    student: { id: data.student_id, level: data.level },
  });
}

// ---------- Router ----------
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return fail(405, "METHOD_NOT_ALLOWED", "Use POST");

  const action = new URL(req.url).pathname.split("/").filter(Boolean).pop();

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return fail(400, "INVALID_JSON", "Body must be JSON");
  }

  try {
    switch (action) {
      case "resolve-class":
        return await resolveClass(req, body);
      case "verify":
        return await verify(req, body);
      default:
        return fail(404, "NOT_FOUND", "Unknown action");
    }
  } catch (e) {
    // Log only the technical message: never PINs, names or tokens (privacy)
    console.error(`[student-login:${action}]`, e instanceof Error ? e.message : String(e));
    return fail(500, "INTERNAL_ERROR", "Unexpected error");
  }
});
