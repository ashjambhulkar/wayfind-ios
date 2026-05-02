# validate-subscription

Validates in-app purchases and updates `public.user_subscriptions`.

## Environment

| Variable | Required | Purpose |
|----------|----------|---------|
| `SUPABASE_URL` | Yes | Injected by Supabase |
| `SUPABASE_ANON_KEY` | Yes | JWT validation |
| `SUPABASE_SERVICE_ROLE_KEY` | Yes | Upsert `user_subscriptions` |
| `APPLE_SHARED_SECRET` | Yes for iOS | App Store shared secret (App Store Connect → App → App Information → App-Specific Shared Secret) |

## Request

`POST` with `Authorization: Bearer <user JWT>`.

```json
{
  "receipt": "<base64 App Store receipt or transaction payload per client SDK>",
  "product_id": "wayfind_pro_annual",
  "platform": "ios"
}
```

- **iOS:** Uses Apple [verifyReceipt](https://developer.apple.com/documentation/appstorereceipts/verifyreceipt) (production, then sandbox on `21007`). Parses `latest_receipt_info` for latest `expires_date_ms`.
- **Android:** Returns `501` until Play Developer API + service account are wired (Stage 1+).

## Lifecycle (renewals / refunds)

Server-to-server notifications are **not** implemented in this function. See:

`.cursor/plans/V2b_Stage1_subscription_lifecycle.md`

Recommended next steps: Apple App Store Server Notifications v2, Google RTDN, periodic reconciliation job.
