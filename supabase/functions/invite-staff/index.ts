// supabase/functions/invite-staff/index.ts
// An admin or a director invites staff by email. Supabase sends the invitation;
// the profile, school link and audit row are created atomically by create_staff_member().
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
// Where the invitation link lands (portal "set password" page). Server-side only: never taken from the request.
const REDIRECT_TO = Deno.env.get("STAFF_INVITE_REDIRECT_URL") ?? undefined;

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
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const STAFF_ROLES = ["teacher", "counselor", "director", "admin"];
const DIRECTOR_CAN_INVITE = ["teacher", "counselor"];

// SQL business errors (P0001) → HTTP
const RPC_ERRORS: Record<string, number> = {
  ALREADY_IN_SCHOOL: 409,
  ROLE_MISMATCH: 409,
  SCHOOL_REQUIRED: 400,
  INVALID_ROLE: 400,
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return fail(405, "METHOD_NOT_ALLOWED", "Use POST");

  try {
    // 1. Who is calling?
    const token = req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "");
    if (!token) return fail(401, "UNAUTHORIZED", "Missing session token");

    const { data: userData, error: userError } = await admin.auth.getUser(token);
    if (userError || !userData.user) return fail(401, "UNAUTHORIZED", "Invalid session");
    const callerId = userData.user.id;

    const { data: caller } = await admin
      .from("profiles").select("role, active").eq("id", callerId).maybeSingle();
    if (!caller?.active || !["admin", "director"].includes(caller.role)) {
      return fail(403, "FORBIDDEN", "Only admin or director can invite staff");
    }

    // 2. Validate the body
    let body: Record<string, unknown>;
    try {
      body = await req.json();
    } catch {
      return fail(400, "INVALID_JSON", "Body must be JSON");
    }

    const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
    const fullName = typeof body.full_name === "string" ? body.full_name.trim().replace(/\s+/g, " ") : "";
    const role = typeof body.role === "string" ? body.role : "";
    const schoolId = typeof body.school_id === "string" ? body.school_id : null;

    if (!EMAIL_RE.test(email) || email.endsWith("@students.pio.invalid")) {
      return fail(400, "INVALID_EMAIL", "A valid staff email is required");
    }
    if (fullName.length < 3 || fullName.length > 80) {
      return fail(400, "INVALID_NAME", "full_name must have 3 to 80 characters");
    }
    if (!STAFF_ROLES.includes(role)) {
      return fail(400, "INVALID_ROLE", `role must be one of ${STAFF_ROLES.join(", ")}`);
    }
    if (role !== "admin" && (!schoolId || !UUID_RE.test(schoolId))) {
      return fail(400, "SCHOOL_REQUIRED", "school_id is required for this role");
    }

    // 3. Permission: a director invites only teachers/counselors, only into their own school
    if (caller.role === "director") {
      if (!DIRECTOR_CAN_INVITE.includes(role)) {
        return fail(403, "ROLE_NOT_ALLOWED", "A director can invite only teachers and counselors");
      }
      const { data: link } = await admin
        .from("staff_schools").select("school_id")
        .eq("profile_id", callerId).eq("school_id", schoolId).maybeSingle();
      if (!link) return fail(403, "FORBIDDEN", "You are not staff of this school");
    }

    if (schoolId) {
      const { data: school } = await admin.from("schools").select("id").eq("id", schoolId).maybeSingle();
      if (!school) return fail(404, "SCHOOL_NOT_FOUND", "School not found");
    }

    // 4. Existing account? (same helper student-login uses)
    const { data: existingId, error: lookupError } = await admin.rpc("get_auth_user_id_by_email", {
      p_email: email,
    });
    if (lookupError) throw new Error(`lookup: ${lookupError.message}`);

    let userId: string;
    let status: "invited" | "added_to_school" | "profile_completed";

    if (existingId) {
      const { data: profile } = await admin.from("profiles").select("role").eq("id", existingId).maybeSingle();
      if (profile && profile.role !== role) {
        return fail(409, "ROLE_MISMATCH", `This person already has the role ${profile.role}`);
      }
      userId = existingId as string;
      status = profile ? "added_to_school" : "profile_completed";
    } else {
      const { data: invited, error: inviteError } = await admin.auth.admin.inviteUserByEmail(email, {
        data: { full_name: fullName },
        redirectTo: REDIRECT_TO,
      });
      if (inviteError || !invited.user) {
        console.error("[invite-staff] invite:", inviteError?.message);
        return fail(502, "INVITE_FAILED", "The invitation email could not be sent");
      }
      userId = invited.user.id;
      status = "invited";
    }

    // 5. Profile + school + audit, all or nothing
    const { error: rpcError } = await admin.rpc("create_staff_member", {
      p_user_id: userId,
      p_full_name: fullName,
      p_role: role,
      p_school_id: schoolId,
      p_actor_id: callerId,
    });
    if (rpcError) {
      if (rpcError.code === "P0001" && RPC_ERRORS[rpcError.message]) {
        return fail(RPC_ERRORS[rpcError.message], rpcError.message, rpcError.message);
      }
      throw new Error(`create_staff_member: ${rpcError.message}`);
    }

    return json(200, { user_id: userId, email, full_name: fullName, role, school_id: schoolId, status });
  } catch (e) {
    console.error("[invite-staff]", e instanceof Error ? e.message : String(e));
    return fail(500, "INTERNAL_ERROR", "Unexpected error");
  }
});
