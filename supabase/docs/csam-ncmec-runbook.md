# CSAM Detection & NCMEC Reporting Runbook

This runbook is **regulatory**. Deviating from it on a confirmed CSAM
detection puts the company in violation of US 18 USC § 2258A and the EU
DSA. If you are reading this for the first time during an active
incident, stop, page the security incident lead, and follow the *exact*
steps in Section 3.

## 1. Architecture (where the scanning lives)

1. iOS uploads a freshly-picked photo via background `URLSession` to the
   private `place-photos-quarantine` Supabase Storage bucket. RLS pins
   the path to `<auth.uid()>/<photo_id>.jpg`.
2. iOS inserts a `place_user_photos` row with `status='pending_moderation'`
   and triggers the `moderate-place-photo` Edge Function (Phase F.3).
3. `moderate-place-photo` calls `_shared/csam_scan.ts::scanForCsam()`
   with a signed URL into the quarantine bucket.
   - Tier 1: Cloudflare CSAM Scanning Tool (free for hosts).
   - Tier 2: PhotoDNA-compatible cross-check (Microsoft) — defence in
     depth.
4. On a confirmed match: hard-quarantine the row, lock the uploader
   account, and emit a structured `csam_match` audit event. NCMEC
   reporting is the **manual** Section 3 workflow below — we do NOT
   auto-file because over-reporting harms NCMEC's ability to act.

## 2. Configuration

Required environment variables (set in Supabase function secrets):

- `CLOUDFLARE_CSAM_ENDPOINT` — endpoint URL Cloudflare provisions when
  you enable CSAM Scanning Tool on the protected hostname.
- `CLOUDFLARE_CSAM_TOKEN` — bearer token (rotate quarterly).
- `PHOTODNA_ENDPOINT` — Microsoft PhotoDNA Cloud Service endpoint.
- `PHOTODNA_TOKEN` — `Ocp-Apim-Subscription-Key` value.

If both endpoints are unconfigured, `scanForCsam` returns
`unavailable=true` and the moderation function fails *closed*
(`status='pending_review'`). We never approve unscanned content.

## 3. Incident response on a confirmed match

The moderation function will already have:

- flipped the photo row to `status='rejected'`,
- set `reject_reason='csam'`,
- emitted a `csam_match` event into the structured log stream,
- locked the uploader's account (`auth.users.banned_until` future
  timestamp via the security RPC).

The on-call security lead must, within **2 business days**:

1. **Preserve evidence.** Do NOT delete the quarantine bucket object yet.
   18 USC § 2258A requires us to preserve content and associated
   metadata for at least 90 days.
2. **File the CyberTipline report** at <https://report.cybertip.org>:
   - Reporter info: company legal entity, this runbook URL.
   - Image: provide via NCMEC's secure upload (NEVER attach to email).
   - Metadata to include:
     - `photo_id`, `uploader_user_id`, `city_place_id`
     - upload timestamp (UTC)
     - source IP if available
     - storage URL (sign a fresh URL valid 7 days for NCMEC)
   - Metadata to **withhold**: any other user's PII, the device push
     token, anything not strictly needed for law enforcement.
3. **Document the report.** File the NCMEC confirmation number into the
   sealed `csam_audit_events` table referenced by the audit log entry.
4. **Notify counsel.** Same-day email summary, no image attachments.
5. After 90 days (and only after counsel sign-off), delete the bucket
   object via service-role action. Keep the audit row indefinitely.

## 4. What NEVER to do

- Never email or Slack the image bytes, base64 payload, or hash digest.
- Never run a second AI vision call against confirmed-match content.
- Never tell the uploader why their photo was rejected if the reason is
  CSAM (use generic "violates community guidelines"). Tipping them off
  obstructs law enforcement.
- Never deploy a new build that disables `scanForCsam` "temporarily" to
  unblock a release. The pipeline is fail-closed by design.

## 5. Routine ops

- Quarterly: rotate `CLOUDFLARE_CSAM_TOKEN` and `PHOTODNA_TOKEN`.
- Quarterly: tabletop the workflow with security + legal + on-call.
- Annually: review NCMEC reporter information, update entity name &
  contacts as needed.

## 6. References

- NCMEC reporting portal: <https://report.cybertip.org>
- 18 USC § 2258A (mandatory reporting): <https://www.law.cornell.edu/uscode/text/18/2258A>
- EU DSA notice-and-action obligations: Articles 16–18 of Regulation
  (EU) 2022/2065.
- Cloudflare CSAM Scanning Tool docs:
  <https://developers.cloudflare.com/cache/reference/csam-scanning/>
