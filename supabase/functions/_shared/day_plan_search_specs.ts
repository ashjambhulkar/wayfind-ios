/**
 * Text Search query specs for day-plan candidate discovery (Change 6 Part 5).
 * Broad "in {city}" queries use `citySearchLabel`; local anchor uses `baseLabel`.
 */

export type DayPlanSearchScope = "walkable" | "city_wide" | "spread_out";

export type SearchSpec = { textQuery: string; includedType?: string };

/**
 * Builds Places Text Search specs: city-wide / spread-out scopes mix `city` and `base`;
 * walkable stays near `base` only.
 */
export function buildSearchSpecs(
  citySearchLabel: string,
  baseLabel: string,
  includeMeals: boolean,
  scope: DayPlanSearchScope,
): SearchSpec[] {
  const city = citySearchLabel.trim();
  const base = baseLabel.trim() || city;

  if (scope === "walkable") {
    return [
      { textQuery: `things to do near ${base}` },
      { textQuery: `attractions near ${base}` },
      { textQuery: `parks near ${base}`, includedType: "park" },
      { textQuery: `art galleries near ${base}`, includedType: "art_gallery" },
      { textQuery: `interesting places near ${base}` },
      ...(includeMeals
        ? [
            {
              textQuery: `restaurants near ${base}`,
              includedType: "restaurant",
            },
            { textQuery: `cafes near ${base}`, includedType: "cafe" },
          ]
        : []),
    ];
  }

  return [
    { textQuery: `top attractions in ${city}` },
    { textQuery: `popular things to do in ${city}` },
    { textQuery: `interesting places near ${base}` },
    { textQuery: `museums in ${city}`, includedType: "museum" },
    { textQuery: `parks and nature in ${city}`, includedType: "park" },
    { textQuery: `historic sites in ${city}` },
    ...(includeMeals
      ? [
          { textQuery: `restaurants near ${base}`, includedType: "restaurant" },
          {
            textQuery: `best restaurants in ${city}`,
            includedType: "restaurant",
          },
        ]
      : []),
  ];
}



