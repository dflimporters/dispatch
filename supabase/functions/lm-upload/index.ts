// lm-upload: the driver app's photo upload (OMS last mile). Deployed 2026-10-22 with verify_jwt = false.
//
// Drivers have no accounts, so there is no user JWT: deploy with verify_jwt = false.
// The phone sends one image per call:
//
//   POST /functions/v1/lm-upload
//     x-lm-token: the load token the phone got from lm_claim (64 hex characters)
//     x-lm-file:  the file's id, already registered by a 'file' event in lm_sync
//     content-type: image/jpeg (png and webp are accepted too)
//     body: the image bytes, at most 10 MB
//
// The token is checked in the database (lm_file_authorize), which also says where the
// file belongs in the private lm-pod bucket. The function then writes the bytes with
// the service role and marks the file uploaded (lm_file_uploaded). Uploading the same
// file again is safe (it overwrites). The bucket has no public or anon policy.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const MAX_BYTES = 10 * 1024 * 1024;
const TYPES = ["image/jpeg", "image/png", "image/webp"];
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TOKEN_RE = /^[0-9a-f]{64}$/i;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type, x-lm-token, x-lm-file, apikey, authorization, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Max-Age": "86400",
};
const json = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

// The first bytes must match the type the phone says it is sending.
function looksLike(type: string, b: Uint8Array): boolean {
  if (type === "image/jpeg") return b.length > 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff;
  if (type === "image/png") return b.length > 8 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47;
  if (type === "image/webp") {
    const s = (i: number, n: number) => String.fromCharCode(...b.slice(i, i + n));
    return b.length > 12 && s(0, 4) === "RIFF" && s(8, 4) === "WEBP";
  }
  return false;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return json(405, { ok: false, error: "POST only" });

  const token = req.headers.get("x-lm-token") ?? "";
  const file = req.headers.get("x-lm-file") ?? "";
  const type = (req.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase();
  if (!TOKEN_RE.test(token) || !UUID_RE.test(file)) return json(400, { ok: false, error: "Bad request" });
  if (!TYPES.includes(type)) return json(415, { ok: false, error: "Images only" });
  if (Number(req.headers.get("content-length") ?? 0) > MAX_BYTES) return json(413, { ok: false, error: "Image too large" });

  const body = new Uint8Array(await req.arrayBuffer());
  if (!body.length) return json(400, { ok: false, error: "Empty image" });
  if (body.length > MAX_BYTES) return json(413, { ok: false, error: "Image too large" });
  if (!looksLike(type, body)) return json(415, { ok: false, error: "That is not a valid image" });

  const sb = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });

  const { data: path, error: authErr } = await sb.rpc("lm_file_authorize", { p_token: token, p_file: file });
  if (authErr || !path) {
    // LM001: the load was taken off this phone. LM404: no such file on this load.
    const gone = authErr?.code === "LM001";
    return json(gone ? 401 : 404, { ok: false, error: gone ? "Load no longer on this phone" : "Unknown file", code: authErr?.code });
  }

  const up = await sb.storage.from("lm-pod").upload(String(path), body, { contentType: type, upsert: true });
  if (up.error) return json(500, { ok: false, error: "Could not save the image" });

  const { error: markErr } = await sb.rpc("lm_file_uploaded", { p_file: file, p_bytes: body.length, p_mime: type });
  if (markErr) return json(500, { ok: false, error: "Saved, but could not be recorded. Try again." });

  return json(200, { ok: true, bytes: body.length });
});
