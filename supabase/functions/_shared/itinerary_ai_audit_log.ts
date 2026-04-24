/**
 * Structured audit logs for `itinerary-ai` (Supabase Edge logs).
 *
 * **Debug one request:** copy `trace_id` from the JSON response body or `X-Trace-Id` header,
 * then in Edge logs filter lines containing that UUID. Timeline:
 * - `phase: "start"` — parsed body + wizard fields (`plan_day`).
 * - `phase: "step"` + `where: "journey_*"` — ordered milestones (gates, DB loads, pool, LLM, quota, resolve, persist).
 * - `phase: "finish"` — HTTP outcome (`http_status`, `response_ok`, `edge_error` / `edge_detail` when present).
 *
 * Every line includes top-level `trace_id` for grep / log drains.
 */

export type ItineraryAiAuditBase = {
  trace_id: string;
  user_id: string | null;
  trip_id: string | null;
  action: string;
};

const TAG = "itinerary_ai";

function extractJsonErrorFields(
  body: unknown,
): { edge_error?: string; edge_detail?: string } {
  if (!body || typeof body !== "object") return {};
  const r = body as Record<string, unknown>;
  const err = r.error;
  const det = r.detail;
  return {
    ...(typeof err === "string" && err.length > 0
      ? { edge_error: err.slice(0, 240) }
      : {}),
    ...(typeof det === "string" && det.length > 0
      ? { edge_detail: det.slice(0, 600) }
      : {}),
  };
}

/** Log once per authenticated request after body is parsed (includes `plan_day` hints). */
export function logItineraryAiStart(
  base: ItineraryAiAuditBase,
  extra?: Record<string, unknown>,
): void {
  console.log(
    JSON.stringify({
      tag: TAG,
      phase: "start",
      trace_id: base.trace_id,
      user_id: base.user_id,
      trip_id: base.trip_id,
      action: base.action,
      ...extra,
    }),
  );
}

/**
 * Mid-request milestone (pool build, hybrid validation, quota, etc.).
 * Search logs for the same `trace_id` as start/finish.
 */
export function logItineraryAiStep(
  traceId: string,
  where: string,
  extra?: Record<string, unknown>,
  level: "log" | "warn" | "error" = "log",
): void {
  const line = JSON.stringify({
    tag: TAG,
    phase: "step",
    trace_id: traceId,
    where,
    ...extra,
  });
  if (level === "error") console.error(line);
  else if (level === "warn") console.warn(line);
  else console.log(line);
}

/** Log once per HTTP response (success → console.log, client/server error → console.error). */
export function logItineraryAiFinish(
  base: ItineraryAiAuditBase,
  http_status: number,
  extra?: Record<string, unknown>,
): void {
  const response_ok = http_status >= 200 && http_status < 400;
  const line = {
    tag: TAG,
    phase: "finish",
    trace_id: base.trace_id,
    user_id: base.user_id,
    trip_id: base.trip_id,
    action: base.action,
    http_status,
    response_ok,
    ...extra,
  };
  if (response_ok) {
    console.log(JSON.stringify(line));
  } else {
    console.error(JSON.stringify(line));
  }
}

function attachTraceToJsonBody(body: unknown, traceId: string): unknown {
  if (body !== null && typeof body === "object" && !Array.isArray(body)) {
    return { ...(body as Record<string, unknown>), trace_id: traceId };
  }
  return body;
}

/** JSON response + finish log + `trace_id` on JSON body and `X-Trace-Id` header for clients. */
export function jsonResponseWithAudit(
  base: ItineraryAiAuditBase,
  body: unknown,
  status: number,
  headers: Record<string, string>,
): Response {
  logItineraryAiFinish(base, status, extractJsonErrorFields(body));
  const payload = attachTraceToJsonBody(body, base.trace_id);
  const outHeaders = { ...headers, "X-Trace-Id": base.trace_id };
  return new Response(JSON.stringify(payload), {
    status,
    headers: outHeaders,
  });
}
