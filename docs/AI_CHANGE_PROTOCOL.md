# AI Change Protocol

Use this when asking AI to work on the project. The goal is to make AI changes easy to review, easy to remember, and hard to scatter across hidden places.

## Before Asking AI To Code

Give the agent the feature area and the owning docs:

```text
Before changing code, read docs/ARCHITECTURE.md, docs/MODULES.md, and the README for the feature folder if it exists. If Supabase is involved, also read docs/SUPABASE_BACKEND.md.
```

For UI work, name the screen and expected behavior. For backend work, name the table/function/RPC if you know it.

## Rules For AI Backend Work

Every Supabase change should include:

- Migration file path and what changed.
- Table/RPC/function/policy/trigger owner.
- Swift service/model/DTO changes, if the app reads or writes the data.
- RLS impact for owner, collaborator, unauthenticated, and service-role paths.
- Function auth mode in `supabase/config.toml` when an Edge Function changes.
- Test or smoke-check path.
- Documentation update in `docs/SUPABASE_BACKEND.md`.

If the AI cannot explain the ownership path from Swift view to table/function, pause and ask it to inspect more first.

## Rules For AI UI Work

Every meaningful SwiftUI change should include:

- Which view owns the presentation state.
- Which model/service owns the data.
- Which sheet/navigation surface is the single presenter.
- Accessibility and empty-state behavior, if user-facing.
- Feature README update when the flow becomes more complex.

For map work, make the agent read `wayfind/Views/Map/README.md` first.

## Commit-Sized Work

Prefer small changes with one reason:

- One UI flow refinement.
- One backend feature or migration group.
- One bug fix.
- One documentation cleanup.

Avoid combining schema changes, Edge Function changes, UI redesign, and unrelated cleanup in the same change unless they are inseparable.

## End-Of-Change Summary Template

Ask AI to finish with this:

```text
Changed:
- ...

State/data ownership:
- ...

Supabase impact:
- Tables:
- RPCs:
- Edge Functions:
- RLS/triggers/cron:

Docs updated:
- ...

Verified:
- ...

Known risks:
- ...
```

## Weekly Maintenance

Once a week:

- Read `docs/DECISIONS.md`.
- Add one entry for any major choice made that week.
- Update `docs/MODULES.md` if a module gained a new owner or service.
- Update `docs/SUPABASE_BACKEND.md` if migrations/functions changed.
- Delete dead code left behind by experiments.

This is the project memory. Keep it boring and current.
