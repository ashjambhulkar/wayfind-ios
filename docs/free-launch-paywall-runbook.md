# Free Launch Paywall Runbook

This documents how to turn paid plans back on after the free launch period.

Companion files:

* `wayfind/AppConfig.swift`
* `wayfind/Services/EntitlementService.swift`
* `wayfind/Services/PaywallPresenter.swift`
* `wayfind/Views/Profile/ProSubscriptionSection.swift`
* `supabase/migrations/20260604160000_free_launch_ai_access.sql`

## Current Launch State

The app currently grants premium feature access to every signed-in user without
marking them as paid Pro.

Client-side switch:

```swift
static let grantFreeLaunchPremiumAccess: Bool = true
```

Backend AI quota switch:

```sql
v_free_launch_premium_access constant boolean := true;
```

This means:

* Feature gates use `EntitlementService.hasPremiumAccess`.
* Real billing state still uses `EntitlementService.isPaidPro`.
* Profile shows "Free during launch" for non-paying launch users.
* RevenueCat still configures, binds users, restores purchases, and receives
  webhook/reconcile updates.
* AI planner calls bypass the free monthly cap but still respect the daily
  safety cap.

## Re-enable Paid Plans

1. Confirm RevenueCat is production-ready:
   * Products are approved in App Store Connect.
   * RevenueCat offerings and placements are active.
   * `Wayfind Pro` entitlement is attached to the right products.
   * Webhook delivery and reconcile cron are healthy.

2. Flip the iOS launch switch in `wayfind/AppConfig.swift`:

   ```swift
   static let grantFreeLaunchPremiumAccess: Bool = false
   ```

3. Add a new Supabase migration that replaces `public.claim_ai_usage` with
   `v_free_launch_premium_access constant boolean := false`.

   Do not edit the old migration. Add a new timestamped migration so production
   history stays reproducible.

4. Build and test with two accounts:
   * Non-subscriber: sees paywalls and free AI monthly quota behavior.
   * Subscriber/restored user: keeps premium access and sees Manage Subscription.

5. Ship the app update and apply the Supabase migration in the same release
   window. Prefer backend first by a short margin so older clients do not promise
   unlimited AI while the backend has already reverted.

## Validation Checklist

* Profile no longer shows "Free during launch" for non-subscribers.
* Profile shows the upgrade card and Restore Purchases.
* Paywall opens from Settings, CSV export, multi-currency, documents, AI quota,
  and flight tracking.
* `pro_gate_attempted` analytics records real paid state separately from access
  metadata.
* AI planner returns `free_limit_reached` after the free monthly quota for a
  non-subscriber.
* Paid subscribers bypass the monthly AI cap but still hit
  `daily_safety_cap_reached` after the abuse ceiling.
* RevenueCat restore updates `isPaidPro` and unlocks `hasPremiumAccess`.

## Rollback

If re-enabling paid plans causes launch-critical issues:

1. Set `grantFreeLaunchPremiumAccess` back to `true` in a hotfix build.
2. Add another Supabase migration that sets
   `v_free_launch_premium_access constant boolean := true`.
3. Keep RevenueCat configured; do not remove products, offerings, webhooks, or
   entitlement code during rollback.

## Important Notes

Do not replace `isPaidPro` with `hasPremiumAccess` in billing UI or analytics.
`isPaidPro` answers "did this user pay or restore a subscription?" while
`hasPremiumAccess` answers "should this feature unlock right now?"

When the free launch ends, keep that separation. It prevents future launch,
promo, trial, or admin-granted access from corrupting paid subscriber metrics.
