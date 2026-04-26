# Change Templates

Copy these sections into a feature README, decision entry, or PR/chat summary when a change gets big enough that future-you should not have to reverse engineer it.

## Feature README Template

```text
# Feature Name

## Purpose

What user problem this feature solves.

## Main Files

- View:
- ViewModel / Store:
- Service:
- Models:
- Tests:

## State Ownership

What owns the source of truth? What is only temporary UI draft state?

## Data Flow

View -> ViewModel/Store -> Service -> Table/RPC/Function -> Response -> UI

## Backend Touchpoints

Tables:
RPCs:
Edge Functions:
Storage buckets:
Triggers/cron:

## Invariants

Things that should always remain true.

## Verification Checklist

Manual or automated checks to run after changes.
```

## Supabase Change Template

```text
## YYYY-MM-DD - Change Title

Migration:
- supabase/migrations/<timestamp>_<name>.sql

Tables changed:
- table_name: what changed and why

RPCs changed:
- function_name(args): what changed and who calls it

Edge Functions changed:
- function-name: auth mode, caller, side effects

RLS / policies:
- owner:
- collaborator:
- service-role:
- anonymous:

Triggers / cron / queues:
- trigger or job name: hidden side effect

Swift owners:
- Service:
- Model/DTO:
- ViewModel/View:

Tests / verification:
- SQL:
- Swift:
- Manual:

Docs updated:
- docs/SUPABASE_BACKEND.md
- feature README
- docs/DECISIONS.md, if this was a tradeoff
```

## Bug Investigation Template

```text
Symptom:

Expected:

Actual:

User flow:

Likely owners:
- View:
- State owner:
- Service:
- Backend:

Evidence checked:
- Logs:
- Tables:
- Functions:
- Realtime/push:

Root cause:

Fix:

Regression check:
```
