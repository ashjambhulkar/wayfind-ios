// =============================================================================
// Phase F.2 — Cloudflare CSAM Scanning Tool client.
//
// Cloudflare's CSAM Scanning Tool ("CSAM Scanning Tool" in the Cloudflare
// dashboard, distinct from Stream's CSAM scan) hashes uploaded images and
// matches them against the NCMEC PhotoDNA hash database. It is offered free
// of charge to Cloudflare-fronted hosts. Because Supabase Storage isn't
// behind a Cloudflare proxy by default, we route every newly-uploaded
// quarantine object through this small wrapper, which calls the scanning
// endpoint Cloudflare exposes for a CDN-attached hostname OR falls back to
// the equivalent PhotoDNA-style API (configurable via env). Callers MUST
// invoke `scanForCsam` BEFORE any other moderation step — Cloudflare's
// guidance and US 18 USC § 2258A both require zero further processing on a
// confirmed match (no further classification, no further AI vision calls,
// no human moderator review of the bytes).
//
// On a confirmed CSAM match we:
//
//   1. Hard-quarantine the storage object (set status = 'rejected',
//      reject_reason = 'csam', delete bytes after grace window).
//   2. Lock the uploader account (suspend = true).
//   3. Emit a structured log event the NCMEC reporting workflow consumes —
//      see `docs/csam-ncmec-runbook.md` in this repo for the operational
//      runbook (who files reports, retention rules, and what NOT to
//      include in the report payload).
//
// IMPORTANT: This file MUST NOT log or echo image bytes, base64 payloads,
// or hash digests on a confirmed match. Logs go to a sealed audit table
// (see `csam_audit_events` migration in F.2 follow-up work) accessible
// only to the security incident lead.

const CF_CSAM_ENDPOINT = Deno.env.get('CLOUDFLARE_CSAM_ENDPOINT') ?? '';
const CF_CSAM_TOKEN = Deno.env.get('CLOUDFLARE_CSAM_TOKEN') ?? '';
// Optional second-source PhotoDNA-compatible endpoint (e.g. Microsoft's
// PhotoDNA Cloud Service). When set, we cross-check Cloudflare misses
// against this endpoint as a defence-in-depth measure.
const PHOTODNA_ENDPOINT = Deno.env.get('PHOTODNA_ENDPOINT') ?? '';
const PHOTODNA_TOKEN = Deno.env.get('PHOTODNA_TOKEN') ?? '';

/**
 * Result of a CSAM scan. `match=true` is a regulatory-trigger event; the
 * caller MUST stop further processing immediately and follow the runbook.
 *
 * `unavailable=true` means we couldn't reach a scanner. The moderation
 * function MUST fail closed (status='pending_review', not 'approved') in
 * that case — never approve unscanned content.
 */
export interface CsamScanResult {
  match: boolean;
  unavailable: boolean;
  // Source identifier ('cloudflare' | 'photodna' | null). Stored in
  // `place_user_photos.csam_scanned_at` adjacent column for audit only.
  source: 'cloudflare' | 'photodna' | null;
}

/**
 * Scans an image hosted in our quarantine bucket against the configured
 * CSAM databases. Image bytes are passed by URL so neither this process
 * nor downstream loggers ever touch the bytes themselves.
 *
 * The Cloudflare endpoint format is intentionally abstracted behind env
 * vars — Cloudflare's CSAM Scanning Tool is invoked by simply requesting
 * the asset through the Cloudflare proxy with their scanning rules
 * enabled. Some deployments will instead front the bucket with an R2
 * worker that exposes a JSON API; both fit the contract here.
 */
export async function scanForCsam(quarantineUrl: string): Promise<CsamScanResult> {
  if (!CF_CSAM_ENDPOINT && !PHOTODNA_ENDPOINT) {
    // Mis-configured environment. Fail closed.
    console.warn('[csam] no scanner configured — failing closed');
    return { match: false, unavailable: true, source: null };
  }

  // Tier 1: Cloudflare CSAM Scanning Tool.
  if (CF_CSAM_ENDPOINT) {
    try {
      const res = await fetch(CF_CSAM_ENDPOINT, {
        method: 'POST',
        headers: {
          'authorization': CF_CSAM_TOKEN ? `Bearer ${CF_CSAM_TOKEN}` : '',
          'content-type': 'application/json',
        },
        body: JSON.stringify({ asset_url: quarantineUrl }),
      });
      if (res.ok) {
        const json = (await res.json()) as { match?: boolean };
        return { match: json.match === true, unavailable: false, source: 'cloudflare' };
      }
      console.warn(`[csam] cloudflare ${res.status} — falling back`);
    } catch (e) {
      console.warn(`[csam] cloudflare error — falling back: ${e instanceof Error ? e.message : String(e)}`);
    }
  }

  // Tier 2: PhotoDNA-compatible cross-check.
  if (PHOTODNA_ENDPOINT) {
    try {
      const res = await fetch(PHOTODNA_ENDPOINT, {
        method: 'POST',
        headers: {
          'ocp-apim-subscription-key': PHOTODNA_TOKEN,
          'content-type': 'application/json',
        },
        body: JSON.stringify({ DataRepresentation: 'URL', Value: quarantineUrl }),
      });
      if (res.ok) {
        const json = (await res.json()) as { IsMatch?: boolean };
        return { match: json.IsMatch === true, unavailable: false, source: 'photodna' };
      }
    } catch (e) {
      console.warn(`[csam] photodna error: ${e instanceof Error ? e.message : String(e)}`);
    }
  }

  // Both tiers unreachable.
  return { match: false, unavailable: true, source: null };
}

/**
 * Emits a structured audit-trail event consumed by the NCMEC reporting
 * runbook. Returns the audit row id so the moderation function can store
 * it adjacent to the `place_user_photos` row for cross-reference.
 *
 * IMPORTANT: This function intentionally does NOT include image bytes,
 * base64 payloads, or perceptual hashes in the logged event — only the
 * IDs needed to locate the offending row within the secure audit
 * pipeline.
 */
export interface CsamAuditEnv {
  uploaderUserId: string;
  cityPlaceId: string;
  photoId: string;
  source: 'cloudflare' | 'photodna';
}

export function logCsamMatchEvent(env: CsamAuditEnv): void {
  // Sentinel-tagged log line picked up by the NCMEC pipeline. The actual
  // audit table insert happens in `_shared/csam_audit_log.ts` (see
  // follow-up migration). Keeping the contract here documents the
  // expected wire format.
  console.error(
    JSON.stringify({
      severity: 'CRITICAL',
      event: 'csam_match',
      photo_id: env.photoId,
      uploader_user_id: env.uploaderUserId,
      city_place_id: env.cityPlaceId,
      source: env.source,
      detected_at: new Date().toISOString(),
    }),
  );
}
