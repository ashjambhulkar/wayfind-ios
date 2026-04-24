const UPSTASH_REST_URL = Deno.env.get("UPSTASH_REDIS_REST_URL") ?? "";
const UPSTASH_REST_TOKEN = Deno.env.get("UPSTASH_REDIS_REST_TOKEN") ?? "";
const REDIS_ENABLED =
  (Deno.env.get("REDIS_CACHE_ENABLED") ?? "true").toLowerCase() !== "false";

const CIRCUIT_BREAKER_THRESHOLD = 3;
const CIRCUIT_BREAKER_WINDOW_MS = 60_000;
const CIRCUIT_BREAKER_COOLDOWN_MS = 30_000;

let failureCount = 0;
let firstFailureAt = 0;
let circuitOpenUntil = 0;

function isCircuitOpen(): boolean {
  if (Date.now() < circuitOpenUntil) return true;
  if (circuitOpenUntil > 0 && Date.now() >= circuitOpenUntil) {
    failureCount = 0;
    firstFailureAt = 0;
    circuitOpenUntil = 0;
  }
  return false;
}

function recordFailure(): void {
  const now = Date.now();
  if (now - firstFailureAt > CIRCUIT_BREAKER_WINDOW_MS) {
    failureCount = 1;
    firstFailureAt = now;
    return;
  }
  failureCount++;
  if (failureCount >= CIRCUIT_BREAKER_THRESHOLD) {
    circuitOpenUntil = now + CIRCUIT_BREAKER_COOLDOWN_MS;
    console.warn(
      `[redis_cache] circuit breaker OPEN — bypassing Redis for ${CIRCUIT_BREAKER_COOLDOWN_MS}ms`,
    );
  }
}

function isConfigured(): boolean {
  return REDIS_ENABLED && UPSTASH_REST_URL.length > 0 && UPSTASH_REST_TOKEN.length > 0;
}

async function upstashCommand(
  command: string[],
): Promise<{ result: unknown } | null> {
  if (!isConfigured() || isCircuitOpen()) return null;
  try {
    const res = await fetch(`${UPSTASH_REST_URL}`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${UPSTASH_REST_TOKEN}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(command),
    });
    if (!res.ok) {
      recordFailure();
      return null;
    }
    return (await res.json()) as { result: unknown };
  } catch (e) {
    recordFailure();
    console.error("[redis_cache] command failed:", e);
    return null;
  }
}

export async function redisGet(key: string): Promise<string | null> {
  const resp = await upstashCommand(["GET", key]);
  if (!resp || resp.result == null) return null;
  return String(resp.result);
}

export async function redisSet(
  key: string,
  value: string,
  ttlSeconds: number,
): Promise<void> {
  // Fire-and-forget: don't await the response in the caller's hot path
  upstashCommand(["SET", key, value, "EX", String(ttlSeconds)]).catch((e) =>
    console.error("[redis_cache] set failed:", e),
  );
}

export async function redisPipelineGet(
  keys: string[],
): Promise<(string | null)[]> {
  if (!isConfigured() || isCircuitOpen() || keys.length === 0) {
    return keys.map(() => null);
  }
  try {
    const pipeline = keys.map((k) => ["GET", k]);
    const res = await fetch(`${UPSTASH_REST_URL}/pipeline`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${UPSTASH_REST_TOKEN}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(pipeline),
    });
    if (!res.ok) {
      recordFailure();
      return keys.map(() => null);
    }
    const data = (await res.json()) as { result: unknown }[];
    return data.map((d) => (d.result != null ? String(d.result) : null));
  } catch (e) {
    recordFailure();
    console.error("[redis_cache] pipeline failed:", e);
    return keys.map(() => null);
  }
}

export function redisCacheEnabled(): boolean {
  return isConfigured() && !isCircuitOpen();
}



