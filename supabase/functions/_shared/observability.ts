import * as Sentry from "https://deno.land/x/sentry/index.mjs";

export type LogLevel = "debug" | "info" | "warn" | "error";

type Primitive = string | number | boolean | null;

const MAX_STRING_LENGTH = 240;
const MAX_FIELDS = 24;
const BLOCKED_KEY_FRAGMENTS = [
  "authorization",
  "body",
  "email",
  "invite",
  "jwt",
  "key",
  "llm",
  "payload",
  "prompt",
  "request",
  "response",
  "secret",
  "token",
  "url",
];

const EXPECTED_REASONS = new Set([
  "invalid_carrier_iata",
  "invalid_departure_date",
  "invalid_flight_number",
  "invalid_json",
  "method_not_allowed",
  "provider_returned_no_segments",
]);

let sentryInitialized = false;

export function initSentry(): void {
  if (sentryInitialized) return;
  sentryInitialized = true;

  const dsn = Deno.env.get("SENTRY_DSN")?.trim();
  if (!dsn) return;

  Sentry.init({
    dsn,
    environment: Deno.env.get("SENTRY_ENVIRONMENT") ?? "production",
    release: Deno.env.get("SENTRY_RELEASE") || undefined,
    defaultIntegrations: false,
    tracesSampleRate: parseSampleRate(Deno.env.get("SENTRY_TRACES_SAMPLE_RATE")),
    profilesSampleRate: 0,
    sendDefaultPii: false,
    beforeSend(event) {
      const tags = event.tags;
      if (tags && typeof tags === "object") {
        const reason = (tags as Record<string, unknown>)["wayfind.reason"];
        if (typeof reason === "string" && EXPECTED_REASONS.has(reason)) return null;
      }
      return event;
    },
  });
}

export function safeLog(
  level: LogLevel,
  fn: string,
  evt: string,
  fields: Record<string, unknown> = {},
): void {
  const line = JSON.stringify({
    service: "wayfind-edge",
    fn,
    lvl: level,
    evt,
    ts: new Date().toISOString(),
    ...sanitizeFields(fields),
  });

  if (level === "error") console.error(line);
  else if (level === "warn") console.warn(line);
  else console.log(line);
}

export async function captureException(
  error: unknown,
  context: {
    fn: string;
    reason: string;
    level?: "warning" | "error";
    fields?: Record<string, unknown>;
  },
): Promise<void> {
  initSentry();
  if (!Deno.env.get("SENTRY_DSN") || EXPECTED_REASONS.has(context.reason)) return;

  const sanitized = sanitizeFields(context.fields ?? {});
  Sentry.withScope((scope) => {
    scope.setTag("wayfind.function", context.fn);
    scope.setTag("wayfind.reason", context.reason);
    scope.setLevel(context.level ?? "error");
    if (Object.keys(sanitized).length > 0) {
      scope.setContext("wayfind", sanitized);
    }
    Sentry.captureException(error);
  });

  await Sentry.flush(2000);
}

export function sanitizeFields(fields: Record<string, unknown>): Record<string, Primitive> {
  const sanitized: Record<string, Primitive> = {};
  for (const key of Object.keys(fields).sort()) {
    if (Object.keys(sanitized).length >= MAX_FIELDS) break;
    const normalizedKey = key.toLowerCase();
    if (BLOCKED_KEY_FRAGMENTS.some((fragment) => normalizedKey.includes(fragment))) {
      continue;
    }

    const value = sanitizeValue(fields[key]);
    if (value !== undefined) sanitized[key] = value;
  }
  return sanitized;
}

export function errorCode(error: unknown): string {
  if (error instanceof Error && error.name) return truncate(error.name);
  const text = String(error);
  const [firstWord] = text.split(/\s+/);
  return truncate(firstWord || "unknown_error");
}

export function errorMessage(error: unknown): string {
  if (error instanceof Error) return truncate(error.message);
  return truncate(String(error));
}

function sanitizeValue(value: unknown): Primitive | undefined {
  if (value === null) return null;
  if (typeof value === "string") return truncate(value);
  if (typeof value === "boolean") return value;
  if (typeof value === "number" && Number.isFinite(value)) return value;
  return undefined;
}

function truncate(value: string): string {
  const trimmed = value.trim();
  if (trimmed.length <= MAX_STRING_LENGTH) return trimmed;
  return trimmed.slice(0, MAX_STRING_LENGTH);
}

function parseSampleRate(value: string | undefined): number {
  if (!value) return 0;
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return 0;
  return Math.max(0, Math.min(1, parsed));
}
