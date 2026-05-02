# Flight Tracking — Push Payload Schema (V5 / ActivityKit)

This document freezes the wire contract between the
`poll-flight-status` Edge Function (Wave 3.2) and the iOS client. The
client UI ships in Wave 3.3 (static badge) and a future V5 ships the
ActivityKit Live Activity surface — but the schema is finalised **now**
so neither side has to guess.

> If you change anything here, you must bump `schema_version` and ship
> server + client together.

---

## Overview

When the polling worker detects a *user-visible* change on a tracked
flight (status, ETA shift > 5 min, gate, baggage claim) it does two
things:

1. Updates `public.flight_statuses` (Realtime fan-out — drives the
   in-app badge).
2. Sends an APNs push via the existing `fcm_tokens` infrastructure
   (drives lock-screen notifications + ActivityKit content state
   refreshes).

The APNs payload below is also the structure consumed by ActivityKit
`ContentState`. Every field that's optional is explicitly marked.

## APNs payload

```json
{
  "aps": {
    "alert": {
      "title": "AA 100 delayed 25 min",
      "body": "New estimated departure 7:55 PM (was 7:30 PM). Gate B14."
    },
    "sound": "default",
    "interruption-level": "time-sensitive",
    "relevance-score": 1.0,
    "content-state": {
      "schema_version": 1,
      "booking_id": "1d3f8e90-...",
      "flight_id": "AA100-2026-04-25",
      "carrier_iata": "AA",
      "flight_number": "100",
      "status": "scheduled",
      "scheduled_departure_utc": "2026-04-25T23:30:00Z",
      "estimated_departure_utc": "2026-04-25T23:55:00Z",
      "actual_departure_utc": null,
      "scheduled_arrival_utc": "2026-04-26T11:55:00Z",
      "estimated_arrival_utc": "2026-04-26T12:20:00Z",
      "actual_arrival_utc": null,
      "origin_airport_iata": "JFK",
      "destination_airport_iata": "LHR",
      "gate_origin": "B14",
      "gate_destination": null,
      "terminal_origin": "8",
      "terminal_destination": "2",
      "baggage_claim": null,
      "delay_minutes": 25,
      "last_change_summary": "ETA pushed 25 minutes",
      "polled_at": "2026-04-25T22:05:00Z",
      "is_stale": false
    },
    "stale-date": 1745623500,
    "dismissal-date": 1745631000
  },
  "wf": {
    "type": "flight_status_update",
    "trip_id": "9b7c2a3e-...",
    "user_id": "f0e1d2c3-..."
  }
}
```

### Field reference

| Field | Type | Notes |
|---|---|---|
| `schema_version` | int | Bump when any field is renamed/removed. Client tolerates higher. |
| `booking_id` | uuid | FK → `public.trip_bookings.id`. |
| `flight_id` | string | `<carrier><number>-<scheduled_departure_date_utc>`. Stable across polls. |
| `status` | enum | `scheduled \| active \| landed \| cancelled \| diverted \| unknown`. |
| `scheduled_*` | iso8601 | Always present. From the original booking. |
| `estimated_*` | iso8601 \| null | Provider's current best guess. Null until known. |
| `actual_*` | iso8601 \| null | Wheels-up / wheels-down once observed. |
| `origin_airport_iata` | string \| null | Three-letter IATA. |
| `destination_airport_iata` | string \| null | Three-letter IATA. |
| `gate_*`, `terminal_*` | string \| null | Right-trim whitespace; uppercase letters preserved. |
| `baggage_claim` | string \| null | Often arrives ~10 min before landing. |
| `delay_minutes` | int \| null | Positive = late vs. scheduled. Negative = early. |
| `last_change_summary` | string | Human-readable diff for the notification body. ≤ 80 chars. |
| `polled_at` | iso8601 | When the worker last fetched this snapshot. |
| `is_stale` | bool | True if `polled_at` is older than the tier-appropriate freshness window. UI shows the amber badge. |

### Top-level `wf` envelope

The `wf` namespace lives outside `aps` so the SDK doesn't dispatch it
to the system UI. We use it for routing inside the app delegate:

| Field | Type | Notes |
|---|---|---|
| `type` | string | `flight_status_update` for this surface. |
| `trip_id` | uuid | For badge invalidation / deep-link routing. |
| `user_id` | uuid | Sanity check the push didn't get re-routed mid-flight. |

## Stale / dismissal lifecycle

ActivityKit needs an explicit `stale-date` (when the OS dims the
activity) and `dismissal-date` (when the OS removes it). The worker
sets:

* `stale-date` = `max(polled_at + tier_freshness, scheduled_departure - 30 min)`
* `dismissal-date` = `max(scheduled_arrival, actual_arrival) + 60 min`

This way:

* Pre-flight, the badge stays bright until ~30 min before the
  scheduled departure even if no fresh snapshot exists.
* Post-landing, the activity hangs around for an hour so the user can
  still glance at the gate / baggage claim.

## Pollin-cadence reference (for cross-referencing with the badge)

| Window relative to scheduled departure | Cadence |
|---|---|
| > 24h before | every 60 min |
| 24h → 4h before | every 15 min |
| 4h before → landing | every 5 min |
| Post-landing → +60 min | every 10 min |

Anything outside the last bucket is removed from the polling set
entirely.
