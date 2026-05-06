/**
 * IATA airport code validation and normalisation.
 *
 * An IATA airport code is exactly three uppercase ASCII letters.
 * Examples: JFK, LAX, LHR, PHX
 */

const IATA_RE = /^[A-Z]{3}$/;

/**
 * Returns the canonical (trimmed, uppercased) IATA code if `raw` is valid,
 * or `null` otherwise.
 */
export function normaliseIATA(raw: string | null | undefined): string | null {
  const candidate = (raw ?? "").trim().toUpperCase();
  return IATA_RE.test(candidate) ? candidate : null;
}

/** Returns `true` when `raw` is a syntactically valid IATA code. */
export function isValidIATA(raw: string | null | undefined): boolean {
  return normaliseIATA(raw) !== null;
}
