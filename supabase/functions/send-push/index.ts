// supabase/functions/send-push/index.ts
// Called by a cron every few minutes. Sends queued notifications through Expo Push.
// Texts never include names, emotions or reasons: a family phone is seen by anyone.
import { createClient } from "npm:@supabase/supabase-js@2";

// ---------- Keys: new format first; legacy as fallback ----------
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
const CRON_SECRET = Deno.env.get("CRON_SECRET");
const EXPO_ACCESS_TOKEN = Deno.env.get("EXPO_ACCESS_TOKEN"); // optional (enhanced push security in Expo)
const EXPO_PUSH_URL = "https://exp.host/--/api/v2/push/send";
const CHUNK_SIZE = 100; // Expo accepts up to 100 messages per request

const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

// ---------- Texts per kind and language (es as fallback) ----------
type Text = { title: string; body: string };
const TEXTS: Record<string, Record<string, Text>> = {
  new_lesson: {
    es: { title: "¡Nueva lección!", body: "Pío te preparó una lección nueva. ¡Vamos a verla!" },
    en: { title: "New lesson!", body: "Pío has a new lesson for you. Let's take a look!" },
  },
  due_reminder: {
    es: { title: "Mañana es la clase", body: "Si te falta terminar tu lección, todavía estás a tiempo." },
    en: { title: "Class is tomorrow", body: "If your lesson isn't finished yet, there's still time." },
  },
  new_alert: {
    es: { title: "Pío · Apoyo", body: "Hay una nueva alerta de apoyo en tu grupo." },
    en: { title: "Pío · Support", body: "There is a new support alert in your group." },
  },
  help_request: {
    es: { title: "Alguien quiere hablar", body: "Un estudiante pidió hablar. Abrí Pío para ver la solicitud." },
    en: { title: "Someone wants to talk", body: "A student asked to talk. Open Pío to see the request." },
  },
  risk_alert: {
    es: { title: "Pío · Atención", body: "Hay una alerta que requiere la atención de orientación." },
    en: { title: "Pío · Attention", body: "There is an alert that needs counseling's attention." },
  },
};

function textFor(kind: string, language: string): Text {
  const byLang = TEXTS[kind];
  return byLang?.[language] ?? byLang?.es ?? { title: "Pío", body: "Tenés una novedad en Pío." };
}

type Claimed = { id: number; kind: string; data: Record<string, unknown>; language: string; tokens: string[] };
type Outgoing = { id: number; token: string; message: Record<string, unknown> };

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { error: { code: "METHOD_NOT_ALLOWED" } });
  if (!CRON_SECRET) {
    console.error("[send-push] CRON_SECRET is not set");
    return json(500, { error: { code: "NOT_CONFIGURED" } });
  }
  if (req.headers.get("x-cron-secret") !== CRON_SECRET) {
    return json(401, { error: { code: "UNAUTHORIZED" } });
  }

  try {
    // 1. Take a batch
    const { data, error } = await admin.rpc("claim_notifications", { p_limit: 200 });
    if (error) throw new Error(`claim: ${error.message}`);
    const batch = (data ?? []) as Claimed[];

    // 2. One message per (notification, device). A phone shared by siblings gets each kind once,
    //    and the notifications that ride along share the fate of the message that was actually sent.
    const outgoing: Outgoing[] = [];
    const riders = new Map<string, number[]>();   // "token|kind" → notification ids riding on that message

    for (const n of batch) {
      if (n.tokens.length === 0) continue; // already marked 'skipped' by claim_notifications
      const text = textFor(n.kind, n.language);
      for (const token of n.tokens) {
        const key = `${token}|${n.kind}`;
        if (riders.has(key)) {
          riders.get(key)!.push(n.id);          // same phone, same kind: ride along
          continue;
        }
        riders.set(key, [n.id]);
        outgoing.push({
          id: n.id,
          token,
          message: { to: token, title: text.title, body: text.body, sound: "default", priority: "high",
                     data: { kind: n.kind, ...n.data } },   // ids only, for navigation inside the app
        });
      }
    }

    // 3. Send in chunks and read Expo's ticket for each message
    const ok = new Set<number>();
    const errors = new Map<number, string>();
    const deadTokens = new Set<string>();

    for (let i = 0; i < outgoing.length; i += CHUNK_SIZE) {
      const chunk = outgoing.slice(i, i + CHUNK_SIZE);
      const res = await fetch(EXPO_PUSH_URL, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          ...(EXPO_ACCESS_TOKEN ? { Authorization: `Bearer ${EXPO_ACCESS_TOKEN}` } : {}),
        },
        body: JSON.stringify(chunk.map((o) => o.message)),
      });

      if (!res.ok) {
        const reason = `EXPO_HTTP_${res.status}`;
        console.error("[send-push]", reason, await res.text());
        for (const o of chunk) {
          const key = `${o.token}|${(o.message.data as { kind: string }).kind}`;
          for (const id of riders.get(key) ?? [o.id]) if (!ok.has(id)) errors.set(id, reason);
        }
        continue;
      }

      const { data: tickets } = await res.json();
      (tickets as Array<{ status: string; message?: string; details?: { error?: string } }>).forEach((t, idx) => {
        const o = chunk[idx];
        const key = `${o.token}|${(o.message.data as { kind: string }).kind}`;
        const ids = riders.get(key) ?? [o.id];
        if (t.status === "ok") {
          for (const id of ids) { ok.add(id); errors.delete(id); }
        } else {
          const code = t.details?.error ?? "EXPO_ERROR";
          if (code === "DeviceNotRegistered") deadTokens.add(o.token); // app uninstalled / token expired
          for (const id of ids) if (!ok.has(id)) errors.set(id, code);
        }
      });
    }

    // 4. Report back
    const failed = [...errors.entries()].filter(([id]) => !ok.has(id)).map(([id, error]) => ({ id, error }));
    const { data: summary, error: finishError } = await admin.rpc("finish_notifications", {
      p_sent: [...ok],
      p_failed: failed,
      p_invalid_tokens: [...deadTokens],
    });
    if (finishError) throw new Error(`finish: ${finishError.message}`);

    return json(200, { claimed: batch.length, messages: outgoing.length, ...summary });
  } catch (e) {
    console.error("[send-push]", e instanceof Error ? e.message : String(e));
    return json(500, { error: { code: "INTERNAL_ERROR" } });
  }
});
