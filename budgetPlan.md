# Budget Feature — Research & Integration Plan

## Table of Contents

1. [Current State — What Already Exists](#1-current-state--what-already-exists)
2. [Core Problem — Why Budget Must Be Effortless](#2-core-problem--why-budget-must-be-effortless)
3. [Every Possible Way to Enter Expenses (Easiest First)](#3-every-possible-way-to-enter-expenses-easiest-first)
4. [Receipt Photo Scanning — Deep Dive](#4-receipt-photo-scanning--deep-dive)
5. [How Budget Works with Collaborators](#5-how-budget-works-with-collaborators)
6. [Budget Views & UX Architecture](#6-budget-views--ux-architecture)
7. [Multi-Currency Strategy](#7-multi-currency-strategy)
8. [Database & Schema Assessment](#8-database--schema-assessment)
9. [Version Rollout Strategy](#9-version-rollout-strategy)
10. [Implementation Priority Matrix](#10-implementation-priority-matrix)
11. [Competitive Landscape & Differentiation](#11-competitive-landscape--differentiation)
12. [Open Questions & Decisions](#12-open-questions--decisions)

---

## 1. Current State — What Already Exists

### Database (Already Deployed in Supabase)

| Table | Status | Key Fields |
|---|---|---|
| `trip_expenses` | Deployed | trip_id, booking_id (FK), title, amount, currency, category (8 types), split_type (equal/exact/percentage/full), expense_date, payer_user_id, notes |
| `expense_splits` | Deployed | expense_id (FK), user_id, owed_amount |
| `trip_budgets` | Deployed | trip_id, user_id, category, planned_amount, spent_amount, currency |
| `trip_collaborators` | Deployed | trip_id, user_id, role (viewer/editor), status, permissions including `can_see_budget` (via app model) |

### iOS App (Prototype UI Exists)

| Component | File | Status |
|---|---|---|
| `BudgetScreenView` | `Views/Prototype/V2/Organizers/BudgetScreenView.swift` | Prototype — uses DummyData, has summary card, category breakdown, expense list, add expense form |
| `ExpenseSplittingView` | `Views/Prototype/V4/Budget/ExpenseSplittingView.swift` | Prototype — has "Who Owes Who" settlements, split expense breakdown |
| `AddExpenseSheetView` | Inside BudgetScreenView.swift | Basic form — title, amount, category picker, date. No receipt photo, no split, no currency picker |
| Budget pill | `Views/TripDetail/PillsRowView.swift` | Gated behind `.budget` feature flag (V2+), shows "Soon" label in V1 |
| `Expense` model | `Models/DemoModels.swift` | Has `receiptPhotoUrl: String?` field (unused in UI) |
| `CollaboratorPermissions` | `Models/DemoModels.swift` | Has `canSeeBudget: Bool` (already modeled) |

### Backend Infrastructure Available

- **Supabase Storage** — can store receipt photos
- **Edge Functions** — can host OCR/AI processing
- **`extract-booking` Edge Function** — existing pattern for GPT-4o vision API calls
- **Supabase Realtime** — for collaborative budget sync
- **FCM notifications** — for expense alerts

**Bottom line:** The hard infrastructure is done. What's missing is the **frictionless UX** and the **intelligence layer** that makes budget tracking feel automatic rather than like homework.

---

## 2. Core Problem — Why Budget Must Be Effortless

> **The #1 reason people stop tracking travel expenses is friction.** Every tap, every field, every moment of "I'll log it later" is a failure point.

### User Behavior Reality

- Users **do not** open a budget app proactively during a trip
- Users **forget** to log expenses within 30 minutes of spending
- Group trips multiply friction — "who paid?" becomes a conversation nobody wants to have
- Paper receipts get lost; digital receipts are scattered across email/apps/photos
- Currency conversion is mentally exhausting while traveling

### Design Philosophy

**The best expense is one the user never had to enter.**

Priority stack:
1. **Automatic** — system creates the expense with zero user input
2. **Capture** — user points camera, system does the rest
3. **Quick** — 2-3 taps maximum for manual entry
4. **Never manual form-fill** — the traditional "fill out 6 fields" form is the last resort

---

## 3. Every Possible Way to Enter Expenses (Easiest First)

### Method 1: Auto-Create from Bookings (ZERO User Input)

**Friction level: None — fully automatic**

When a booking is added to the trip (via any method), automatically create a corresponding expense entry.

| Booking Source | Auto-Created Expense |
|---|---|
| Email forwarding (AI parsed) | Flight $342, Hotel $189/night, etc. |
| Manual booking entry | Uses the price fields from the booking form |
| Screenshot-to-booking scan | Uses extracted price |
| AI Trip Generator | If price estimates included |

**How it works:**
- Booking saved → `trip_expenses` row auto-inserted with `booking_id` FK
- Category auto-mapped: flight booking → "flight" expense, hotel → "lodging", etc.
- Amount comes from booking's price field
- User sees a toast: "Expense auto-added: Flight $342"
- Can be turned off in budget settings ("Auto-track booking expenses: ON/OFF")

**Why this is #1:** User is already entering booking info. Double-entry is waste. The booking IS the expense — just link them.

**Multi-day bookings (hotels, car rentals):**
- Option A: Single expense for total amount (simpler)
- Option B: Daily expense spread across trip days (better for daily spending analysis)
- **Recommendation:** Single expense, but show per-night cost in the budget breakdown view

---

### Method 2: Receipt Photo Scan (Point & Shoot)

**Friction level: 1 tap to open camera → snap → confirm**

User takes a photo of a receipt. GPT-4o vision extracts all relevant data.

See [Section 4](#4-receipt-photo-scanning--deep-dive) for full technical deep dive.

**Entry points for receipt scan:**
- Speed Dial FAB → "Scan Receipt" (camera icon)
- Budget screen → "+" button → "Scan Receipt" option
- Share Extension → share receipt image from Photos/Files
- Notification action → "Snap a receipt" quick action

**What gets extracted:**
- Total amount (including tip if applicable)
- Merchant/vendor name → becomes expense title
- Date/time
- Currency (from symbols, text, or country detection)
- Category (auto-classified: restaurant → food, taxi → transport, etc.)
- Individual items (optional breakdown)

**Review flow (same pattern as screenshot-to-booking):**
- Parsed fields shown with confidence indicators (✅ Verified / ⚠️ Check)
- User confirms or edits
- One-tap save

---

### Method 3: Quick Add (2-3 Taps)

**Friction level: Amount → Category → Done**

A hyper-minimal expense entry that prioritizes speed over completeness.

**UX Flow:**
1. User taps "+" (from Speed Dial, Budget screen, or widget)
2. **Numpad appears first** — user types amount (e.g., "45.50")
3. **Category grid** — 6 large icon buttons (Transport, Food, Activities, Accommodation, Shopping, Other)
4. Tap a category → expense saved immediately with smart defaults

**Smart defaults applied automatically:**
- Date: today
- Currency: trip destination currency (or last-used currency)
- Title: "{Category} - {Date}" (e.g., "Food - Apr 24")
- Split: based on trip default (solo = full, group = equal)

**Optional expansion:** User can tap "More details" to add title, notes, receipt photo, or change split — but these are never required.

---

### Method 4: Share Extension (From Any App)

**Friction level: Share → Select Trip → Confirm**

Users receive digital receipts everywhere — email, WhatsApp, banking apps, Uber, DoorDash. Instead of opening TripWeave and manually entering, they share directly.

**iOS Share Extension:**
- Register TripWeave in the system share sheet for images and text
- User shares receipt image from Photos, email, or messaging app
- Extension shows: trip selector → auto-parsed preview → confirm
- Works without opening the full app

**What can be shared:**
- Receipt photos/screenshots
- Text snippets (amount + description from banking app)
- URLs (confirmation pages — parse the page content)

---

### Method 5: Smart Notifications & Reminders

**Friction level: Respond to notification → 2 taps**

Don't wait for the user to remember. Remind them at the right moments.

| Trigger | Notification | Action |
|---|---|---|
| End of each trip day (e.g., 9 PM) | "How much did you spend today in Paris?" | Tap → Quick Add with today pre-filled |
| After a booking time passes | "How was lunch at Trattoria? Log expense?" | Tap → Pre-filled with booking venue + estimated cost |
| Trip just ended | "Trip complete! Review your expenses?" | Tap → Budget summary with any gaps highlighted |
| Collaborator added expense | "Sarah added $85 dinner. You owe $42.50" | Tap → View split detail |

**Smart cadence:**
- Max 1 budget notification per day (don't nag)
- Skip if user already logged expenses today
- Disable if user turns off budget reminders

---

### Method 6: Recurring Expenses (Set and Forget)

**Friction level: Set once → auto-populates daily**

Many travel expenses repeat daily:
- Hotel: same nightly rate for duration of stay
- Car rental: daily rate
- Parking: daily rate
- Transit pass: daily cost

**How it works:**
- When adding a hotel booking (or manually), option to "Repeat daily"
- System auto-creates expense entries for each day of the trip
- Shows in budget breakdown per day
- User can edit/delete individual days

---

### Method 7: Expense Templates (Common Patterns)

**Friction level: Tap template → adjust amount → done**

After a few days, spending patterns emerge. Surface them.

| Template | Based On |
|---|---|
| "Coffee" — $4.50, Food | Logged 3 times this trip |
| "Uber" — ~$15, Transport | Logged twice |
| "Museum entry" — $20, Activities | Common at destination |

**How it works:**
- After 2+ similar expenses, offer "Quick add: Coffee again?" at top of budget screen
- Templates are per-trip, auto-generated
- Tap → pre-fills everything, user just confirms or adjusts amount

---

### Method 8: iOS Home Screen Widget (Glanceable + Quick Entry)

**Friction level: Tap widget → numpad → category → done**

WidgetKit widget for the active trip:

**Small widget (2x2):**
- Shows: Total spent / Budget remaining
- Tap → opens Quick Add

**Medium widget (4x2):**
- Shows: Total spent, today's spending, top category
- Tap → opens Budget screen

**Large widget (4x4):**
- Shows: Category breakdown bars + recent expenses
- Quick entry buttons for top 3 categories

---

### Method 9: Siri / Voice Input (Hands-Free)

**Friction level: Speak naturally**

"Hey Siri, log 45 euros for lunch in TripWeave"

**Implementation:** Siri Shortcuts (App Intents framework)
- Define intents: LogExpense(amount, category, currency)
- Siri extracts parameters from natural speech
- Confirms: "Logging €45 food expense for Italy Trip. Correct?"

**Timeline:** V5 feature (Siri Shortcuts integration is already planned as feature #145)

---

### Method 10: Apple Wallet / Bank Integration (Future)

**Friction level: Fully passive**

Detect purchases made near trip destination and offer to log them.

**Options:**
- **Plaid API** — connect bank account, auto-detect transactions at destination
- **Apple Pay receipts** — (no public API currently, may change)
- **Manual bank CSV import** — user exports from banking app, TripWeave parses

**Timeline:** V5+ (requires significant partnerships and user trust)

---

### Summary: Friction Spectrum

| Method | Friction | User Effort | Version |
|---|---|---|---|
| Auto from bookings | None | 0 taps | V2a |
| Receipt scan | Very Low | Point camera + confirm | V2a |
| Quick add | Low | 3 taps (amount + category + save) | V2a |
| Share extension | Low | Share from other app + confirm | V2b |
| Smart notifications | Low | Respond to notification | V2a |
| Recurring expenses | Low | Set once | V2a |
| Expense templates | Very Low | Tap template + adjust | V2c |
| Widget | Low | Tap widget + quick add | V5 (WidgetKit) |
| Siri voice | Very Low | Speak | V5 |
| Bank integration | None | Connect once | V5+ |

---

## 4. Receipt Photo Scanning — Deep Dive

### Architecture

Reuses the exact same pattern as Screenshot-to-Booking (Feature #98):

```
User takes photo
    ↓
Image uploaded to Supabase Storage (temp bucket)
    ↓
Edge Function called: `scan-receipt`
    ↓
GPT-4o vision API (~$0.007/scan)
    ↓
Structured JSON returned:
{
  "merchant": "Trattoria Roma",
  "total": 45.50,
  "currency": "EUR",
  "date": "2026-04-24",
  "category": "food",
  "items": [
    {"name": "Pasta Carbonara", "amount": 16.00},
    {"name": "Margherita Pizza", "amount": 14.00},
    {"name": "House Wine", "amount": 12.00},
    {"name": "Tiramisu", "amount": 8.50},
    {"name": "Service Charge", "amount": 5.00}
  ],
  "confidence": {
    "total": "verified",
    "merchant": "verified",
    "currency": "verified",
    "date": "check",
    "category": "verified"
  }
}
    ↓
Review screen (user confirms/edits)
    ↓
Expense saved + receipt photo stored permanently
```

### Edge Function: `scan-receipt`

**New Edge Function needed** (or extend `extract-booking`):
- Input: image URL (from Supabase Storage)
- Processing: GPT-4o vision with structured output
- Prompt engineering: extract total, merchant, date, currency, line items, tip
- Output: structured JSON with confidence scores
- Cost: ~$0.007 per scan (same as screenshot-to-booking)
- **Pro-only or limited free tier**: 3 scans/month free, unlimited Pro

### Multi-Receipt Batch Scan

**Scenario:** User has 5 receipts from today. Don't make them scan one by one.

**Batch mode:**
- User selects multiple photos from library
- System processes them in parallel
- Shows a list of parsed receipts
- User swipes through, confirming each
- All saved at once

### Supported Receipt Types

| Type | Source | Parsing Difficulty |
|---|---|---|
| Paper receipts (photo) | Camera | Medium — varying formats, languages, print quality |
| Digital receipts (screenshot) | Photos/Share | Easy — clean text, standard layouts |
| Email receipts (forwarded) | Email parsing pipeline | Easy — already structured HTML |
| Banking app screenshots | Photos/Share | Easy — amounts clearly shown |
| Ride-hailing (Uber/Lyft) | Screenshot/Share | Easy — standard format |
| Food delivery (DoorDash, etc.) | Screenshot/Share | Easy — standard format |

### Handling Edge Cases

| Edge Case | Solution |
|---|---|
| Receipt in foreign language | GPT-4o handles multilingual — extract amounts regardless of language |
| Tip included vs. separate | Show both "subtotal" and "total with tip" — user chooses which to track |
| Multiple currencies on one receipt | Default to the larger amount's currency |
| Blurry/damaged receipt | Low confidence score → flag fields for manual entry |
| Group receipt | Scan total → then apply split method (equal/exact) |
| Tax-inclusive vs. exclusive | Default to total (tax-inclusive); user can adjust |

---

## 5. How Budget Works with Collaborators

### The Core Question

> When a trip has 3 collaborators (Alice, Bob, Carol), how does the budget work?

### Budget Visibility Layers

```
┌─────────────────────────────────────────────┐
│              TRIP BUDGET VIEW               │
│                                             │
│  ┌───────────────────────────────────────┐  │
│  │  Trip Total Budget: $6,000            │  │
│  │  Total Spent: $3,200 (53%)            │  │
│  │  ██████████████░░░░░░░░░░░ ← progress │  │
│  └───────────────────────────────────────┘  │
│                                             │
│  ┌── View Toggle ──────────────────────┐    │
│  │ [Everyone] [My Spending] [Splits]   │    │
│  └─────────────────────────────────────┘    │
│                                             │
│  "Everyone" → All expenses by all people    │
│  "My Spending" → Only my expenses           │
│  "Splits" → Who owes who                    │
│                                             │
└─────────────────────────────────────────────┘
```

### Budget Sharing Models

**Model A: Shared Trip Budget (Recommended Default)**

One budget for the whole trip. All collaborators contribute expenses. Everyone sees the total.

- Owner sets trip budget: $6,000
- Any editor can log expenses
- Expenses are tagged with who paid (`payer_user_id`)
- Budget screen shows total spent by everyone
- Each person can filter to see "my expenses" vs. "all expenses"

**Why this is the default:** Most group trips have a shared sense of "how much are we spending?" The trip has a budget, not each person individually.

**Model B: Per-Person Budgets (Optional)**

Each collaborator sets their own budget.

- Alice's budget: $2,500
- Bob's budget: $2,000
- Carol's budget: $1,500
- Each person sees their own progress bar
- Group total is the sum

**When to use:** Useful when people have different budgets (e.g., couples with different incomes, friends with different comfort levels).

**Model C: Shared Pool (Advanced — V4)**

Collaborators contribute to a shared pot (like a group fund).

- Each person contributes $1,000 to the pool ($3,000 total)
- Shared expenses (dinners, group tours) draw from the pool
- Personal expenses (souvenirs, personal upgrades) are individual
- Pool balance shown: "$1,200 remaining in group fund"

### Expense Splitting Logic

When a collaborator adds an expense, they choose how it's split:

#### Split Types (Already in Schema)

| Split Type | How It Works | Example |
|---|---|---|
| **Equal** | Divide total by number of people | $90 dinner ÷ 3 = $30 each |
| **Exact** | Specify each person's share | Alice: $45, Bob: $30, Carol: $15 |
| **Percentage** | Each person's percentage | Alice: 50%, Bob: 30%, Carol: 20% |
| **Full** | One person covers it all (no split) | Alice pays $90, no one owes anything |

#### Smart Split UX

**Default split:** Equal among all trip collaborators (most common case).

**Quick toggles:**
- "Just me" — marks as personal (full, payer only)
- "Split equally" — divides among all collaborators
- "Custom" — opens person picker with amount/percentage fields

**Who's included?**
- By default, ALL accepted collaborators are included in splits
- User can uncheck individuals ("Carol didn't eat dinner")
- System remembers per-trip defaults

#### Settlement Calculation

The app calculates minimum settlements (graph-based debt simplification):

```
Example:
  Alice paid $200 total
  Bob paid $100 total
  Carol paid $50 total
  
  Everyone's fair share: $350 ÷ 3 = $116.67
  
  Settlement:
  ├── Carol owes Alice: $66.67
  └── Bob owes Alice: $16.67
  
  (Simplified from 3 possible debts to 2)
```

#### Settlement Actions

| Action | How |
|---|---|
| Mark as paid | Tap "Mark Settled" on a debt row |
| Request payment | Send push notification to debtor |
| Pay via Venmo | Deep link: `venmo://paycharge?txn=pay&amount=66.67&recipients=alice` |
| Pay via PayPal | Deep link: `paypal://send?amount=66.67&recipient=alice@email.com` |
| Pay via Apple Pay | If both users have Apple Pay set up |

### Permission Model for Budget

Using existing `CollaboratorPermissions.canSeeBudget`:

| Role | Can See Budget | Can Add Expenses | Can Edit Others' Expenses | Can Set Budget |
|---|---|---|---|---|
| Owner | Always | Yes | Yes | Yes |
| Editor | If `canSeeBudget = true` | Yes | No (only their own) | No |
| Viewer | If `canSeeBudget = true` | No | No | No |

**Privacy considerations:**
- Some collaborators may not want others to see their personal spending
- "Personal" expenses are only visible to the spender + owner
- "Shared" expenses are visible to all with budget permission

### Real-Time Sync

When a collaborator adds/edits an expense:
1. Supabase Realtime broadcasts the change
2. All connected collaborators see the update instantly
3. Budget totals and category breakdowns update live
4. Settlement calculations recalculate automatically
5. Activity feed shows: "Bob added $85 dinner at Trattoria Roma"
6. Optional push notification to other collaborators (batched, max 1 per 5 min)

---

## 6. Budget Views & UX Architecture

### Screen Hierarchy

```
Budget Pill (Trip Detail)
    ↓
Budget Screen (Main Hub)
├── Summary Card (total spent / budget / remaining)
├── View Toggle: [Overview] [My Spending] [Splits]
├── Category Breakdown (horizontal bars)
├── Daily Spending Chart (bar chart by day)
├── Recent Expenses List
├── [+] Add Expense → Quick Add / Scan Receipt
│
├── [Overview Tab]
│   ├── All expenses by everyone
│   ├── Category breakdown (all)
│   └── Per-day breakdown
│
├── [My Spending Tab]
│   ├── Only my expenses
│   ├── My budget vs spent
│   └── My category breakdown
│
└── [Splits Tab] (only in collaborative trips)
    ├── Who Owes Who (settlement cards)
    ├── Split expense history
    └── Settlement actions (mark paid, send request)
```

### Budget Summary Card

```
┌─────────────────────────────────────────┐
│                                         │
│           TOTAL SPENT                   │
│            $3,200                        │
│                                         │
│  ████████████████░░░░░░░░░ 53%          │
│  Budget: $6,000                         │
│                                         │
│  ┌──────────┐  ┌──────────┐             │
│  │ 24       │  │ $133     │             │
│  │ Expenses │  │ Per Day  │             │
│  └──────────┘  └──────────┘             │
│                                         │
│  Remaining: $2,800 · 7 days left        │
│  Suggested daily: $400                  │
│                                         │
└─────────────────────────────────────────┘
```

**Smart insights on the summary card:**
- "Remaining: $2,800 · 7 days left → Suggested daily: $400"
- "You're 15% under budget — on track!"
- "Warning: At this pace, you'll exceed budget by $340"
- "Food is your top category (38%)"

### Category Budget Setting

Users can optionally set per-category budgets:

```
Category Budgets (optional)
┌─────────────────────────────────────┐
│ ✈️ Flights      $1,200 / $1,200    │ ████████████████ 100%
│ 🏨 Lodging      $980  / $2,000     │ ████████░░░░░░░░ 49%
│ 🍕 Food         $620  / $800       │ ████████████░░░░ 78%
│ 🎭 Activities   $340  / $500       │ ███████████░░░░░ 68%
│ 🚕 Transport    $180  / $300       │ ██████████░░░░░░ 60%
│ 🛍️ Shopping     $80   / $200       │ ██████░░░░░░░░░░ 40%
│ 📦 Other        $0    / $0         │ (no budget set)
└─────────────────────────────────────┘
```

### Expense Card Design

```
┌─────────────────────────────────────┐
│ 🍕  Trattoria Roma                  │
│     €45.50 → $49.20                 │
│     Today · Food · Alice paid       │
│     Split: Equal (3 people)         │
│     📸 Receipt attached             │
│                                     │
│     You owe Alice: $16.40           │
└─────────────────────────────────────┘
```

---

## 7. Multi-Currency Strategy

### The Problem

A user on a European trip hits 3 currencies in one week (EUR, GBP, CHF). They need:
- To enter amounts in the local currency (what's on the receipt)
- To see their total in their home currency (what it actually costs them)
- To not think about conversion rates

### Solution: Auto-Currency with Smart Defaults

**Trip creation:**
- User sets "Home currency" in profile (USD, EUR, GBP, etc.) — set once, remembered forever
- Trip destination auto-detects local currency (Paris → EUR)
- Multi-destination trips store an array of currencies

**Expense entry:**
- Default currency = trip destination currency (not home currency)
- User can switch currency with one tap (flag icon + currency code)
- Conversion happens automatically using live rates at time of entry
- Both amounts stored: `amount` (original) + `converted_amount` (home currency)

**Display:**
- Budget screen shows totals in home currency
- Individual expenses show: "€45.50 → $49.20"
- Exchange rate shown on tap for transparency

**Rate source:**
- Free tier: Daily rates from ExchangeRate-API or Open Exchange Rates (free for 1,000 req/month)
- Cache rates for 24 hours (travel rates don't change frequently enough to matter minute-by-minute)
- Store the rate used with each expense for historical accuracy

### Schema Addition Needed

```sql
-- Add to trip_expenses (or handle in application layer)
ALTER TABLE trip_expenses ADD COLUMN original_currency text;
ALTER TABLE trip_expenses ADD COLUMN original_amount numeric;
ALTER TABLE trip_expenses ADD COLUMN exchange_rate numeric;
-- existing 'amount' and 'currency' become the converted (home currency) values
```

---

## 8. Database & Schema Assessment

### What's Already There (No Changes Needed)

| Table | Ready? | Notes |
|---|---|---|
| `trip_expenses` | Yes | All core fields present: amount, currency, category, split_type, payer_user_id, booking_id FK |
| `expense_splits` | Yes | Per-person split tracking with owed_amount |
| `trip_budgets` | Yes | Per-category planned vs. spent amounts |
| `trip_collaborators` | Yes | Roles, permissions, status — all needed for budget sharing |

### Schema Additions Needed

#### 1. Receipt storage (use existing Supabase Storage pattern)

```sql
-- Add receipt photo path to expenses
ALTER TABLE trip_expenses ADD COLUMN receipt_storage_path text;
-- No new table needed — follows same pattern as trip_booking_attachments
```

#### 2. Multi-currency support

```sql
ALTER TABLE trip_expenses ADD COLUMN original_currency text;
ALTER TABLE trip_expenses ADD COLUMN original_amount numeric;
ALTER TABLE trip_expenses ADD COLUMN exchange_rate numeric;
```

#### 3. Settlement tracking

```sql
CREATE TABLE public.expense_settlements (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  trip_id uuid NOT NULL,
  from_user_id uuid NOT NULL,
  to_user_id uuid NOT NULL,
  amount numeric NOT NULL,
  currency text NOT NULL DEFAULT 'USD',
  is_settled boolean NOT NULL DEFAULT false,
  settled_at timestamp with time zone,
  settled_via text, -- 'venmo', 'paypal', 'cash', 'apple_pay', 'manual'
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT expense_settlements_pkey PRIMARY KEY (id),
  CONSTRAINT expense_settlements_trip_id_fkey FOREIGN KEY (trip_id) REFERENCES public.trips(id),
  CONSTRAINT expense_settlements_from_user_fkey FOREIGN KEY (from_user_id) REFERENCES auth.users(id),
  CONSTRAINT expense_settlements_to_user_fkey FOREIGN KEY (to_user_id) REFERENCES auth.users(id)
);
```

#### 4. Recurring expense support

```sql
ALTER TABLE trip_expenses ADD COLUMN is_recurring boolean DEFAULT false;
ALTER TABLE trip_expenses ADD COLUMN recurring_source_id uuid REFERENCES trip_expenses(id);
-- recurring_source_id points to the "template" expense that spawned this one
```

#### 5. New Edge Function: `scan-receipt`

```
Input: { imageUrl: string, tripId: string }
Output: {
  merchant: string,
  total: number,
  currency: string,
  date: string,
  category: string,
  items: Array<{ name: string, amount: number }>,
  confidence: Record<string, 'verified' | 'check'>
}
Processing: GPT-4o vision API
Cost: ~$0.007 per scan
```

---

## 9. Version Rollout Strategy

### V2a — Personal Budget Tracking (Ship with V2a)

**Goal:** Make budget tracking work beautifully for solo trips. Set the UX foundation.

| Feature | Complexity | Priority |
|---|---|---|
| Budget screen with summary card + category breakdown | Medium | P0 |
| Quick Add expense (numpad-first, 3-tap flow) | Medium | P0 |
| Per-category budget setting | Low | P0 |
| Auto-create expense from bookings | Low | P0 |
| Receipt photo scan (camera + GPT-4o vision) | Medium | P1 |
| Smart defaults (today's date, trip currency, auto-category) | Low | P0 |
| Progress bar (spent vs. budget) | Low | P0 |
| Smart insights ("At this pace, you'll exceed by $X") | Low | P1 |
| Daily spending breakdown | Medium | P1 |
| End-of-day reminder notification | Low | P2 |
| Recurring expenses (hotel per-night) | Low | P2 |

**What's NOT in V2a:** Splitting, settlements, collaborator budget, multi-currency.

### V2c — Collaborative Budget (Ship with Collaboration)

**Goal:** Make expense splitting painless for group trips.

| Feature | Complexity | Priority |
|---|---|---|
| Split type selection on expense (equal/exact/percentage/full) | Medium | P0 |
| "Who paid" selector (collaborator picker) | Low | P0 |
| Expense splitting view (who owes who) | Medium | P0 |
| Settlement tracking (mark as paid) | Medium | P0 |
| Budget view toggle (Everyone / My Spending / Splits) | Medium | P0 |
| Real-time expense sync via Supabase Realtime | Medium | P1 |
| "Someone owes you" push notification | Low | P1 |
| Activity feed entries for expenses | Low | P1 |
| Collaborator budget visibility permissions | Low | P1 |
| Personal vs. shared expense toggle | Low | P2 |

### V3 — Commerce Integration

| Feature | Complexity | Priority |
|---|---|---|
| Share Extension for receipts | Medium | P1 |
| Multi-currency with live rates | Medium | P1 |
| Expense analytics dashboard (Pro) | Medium | P2 |
| Expense templates (auto-suggested patterns) | Low | P2 |
| Data export (expenses CSV/PDF) | Low | P2 |

### V4+ — Full Platform

| Feature | Complexity | Priority |
|---|---|---|
| Venmo/PayPal/Apple Pay deep links for settlements | Medium | P1 |
| iOS Widget for quick expense entry | Medium | P2 |
| Siri Shortcuts ("Log $45 lunch") | Medium | P2 |
| Bank integration via Plaid (passive tracking) | Very High | P3 |
| Per-person budget allocation within group | Medium | P2 |

---

## 10. Implementation Priority Matrix

### P0 — Must Have (V2a Launch)

These are the minimum features that make the budget screen useful:

1. **Budget screen hub** — summary card, category breakdown, expense list
2. **Quick Add flow** — numpad → category → done (3 taps)
3. **Auto-create from bookings** — zero effort for booking-linked expenses
4. **Budget setting** — set overall trip budget + optional per-category
5. **Progress visualization** — how much spent, how much remaining

### P1 — Should Have (V2a or V2c)

These differentiate TripWeave's budget from competitors:

1. **Receipt photo scanning** — point and shoot expense entry
2. **Expense splitting** — equal/exact/percentage for group trips
3. **Settlement tracking** — who owes who, with mark-as-paid
4. **Real-time sync** — collaborators see expenses instantly
5. **Smart insights** — pace tracking, overspend warnings

### P2 — Nice to Have

1. **Multi-currency** — auto-detect from trip destination
2. **Recurring expenses** — daily hotel/car rental charges
3. **End-of-day reminders** — "Log today's spending?"
4. **Expense templates** — quick re-entry of common items
5. **Share Extension** — add receipts from other apps

### P3 — Future Vision

1. **Widget** — home screen quick entry
2. **Siri voice** — hands-free logging
3. **Bank integration** — passive tracking
4. **Expense analytics** — trends, comparisons across trips

---

## 11. Competitive Landscape & Differentiation

### How Competitors Handle Budget

| App | Budget Approach | Weakness |
|---|---|---|
| **Splitwise** | Expense splitting only, no trip context | No trip timeline integration, no budgeting, no receipt scan |
| **Tricount** | Group expense splitting | No travel features, no budget tracking, basic UI |
| **TravelSpend** | Personal expense tracking | No collaboration, no receipt scan, no booking integration |
| **Trail Wallet** | Daily budget tracker | No splitting, no collaboration, manual-only entry |
| **Wanderlog** | Basic expense log | No receipt scan, no splitting, bolted-on feel |
| **TripIt** | No budget feature | Completely missing |
| **Google Trips** | Discontinued | — |

### TripWeave's Differentiators

1. **Budget lives INSIDE the trip timeline** — not a separate app. Your flight booking IS your flight expense. Context is automatic.

2. **Receipt scan reuses existing AI pipeline** — same GPT-4o vision infrastructure as screenshot-to-booking. Zero new backend architecture.

3. **Auto-create from bookings** — no competitor does this. When an email-parsed booking arrives, the expense is already logged.

4. **Collaborative by default** — 60-70% of trips are group trips. Budget splitting is native, not an afterthought.

5. **Smart defaults eliminate form-filling** — currency from destination, date from today, category from context. Quick Add is genuinely 3 taps.

---

## 12. Open Questions & Decisions

### UX Decisions Needed

| # | Question | Options | Recommendation |
|---|---|---|---|
| 1 | Should budget be required to use the app? | A) Optional (default off) B) Optional (default on) C) Required | **B) Optional, default on** — show the budget pill but don't force expense entry. Empty state shows "Start tracking your spending" |
| 2 | Multi-day bookings (hotel 5 nights) | A) Single expense for total B) Split into nightly expenses | **A) Single expense** with per-night display in breakdown — simpler for users |
| 3 | Default split type for group trips | A) Equal B) Full (no split) C) Ask each time | **A) Equal** among all collaborators — user can change per expense |
| 4 | Receipt scanning tier | A) Free unlimited B) Free limited + Pro unlimited C) Pro only | **B) 3 scans/month free, unlimited Pro** — matches screenshot-to-booking pattern |
| 5 | When to show splits tab | A) Always B) Only for collaborative trips C) Only when split expenses exist | **B) Only for collaborative trips** — hide complexity for solo travelers |
| 6 | Budget notifications | A) Default on B) Default off C) Ask during setup | **C) Ask during trip creation** — "Want daily spending reminders?" |
| 7 | Where to surface "Add Expense" | A) Budget screen only B) Budget + Speed Dial C) Budget + Speed Dial + Timeline | **B) Budget screen + Speed Dial FAB** — accessible but not cluttering timeline |

### Technical Decisions Needed

| # | Question | Options | Recommendation |
|---|---|---|---|
| 1 | Receipt scan processing | A) Client-side (Core ML) B) Server-side (Edge Function + GPT-4o) C) Hybrid | **B) Server-side** — consistent quality, same pattern as existing AI features, ~$0.007/scan |
| 2 | Exchange rates API | A) ExchangeRate-API (free tier) B) Open Exchange Rates C) Fixer.io | **A) ExchangeRate-API** — free for 1,500 req/month, more than enough |
| 3 | Settlement calculation | A) Client-side (Swift) B) Server-side (Edge Function) | **A) Client-side** — small data set, fast calculation, no latency |
| 4 | Expense data sync | A) Polling B) Supabase Realtime C) Push notifications | **B) Supabase Realtime** — already used for trip collaboration |

---

## Appendix A: User Flow — Complete Expense Lifecycle

### Solo Trip

```
1. User creates trip "Rome 2026" → sets budget $3,000
2. Forwards flight confirmation email → booking parsed → expense auto-created ($342, flight)
3. Adds hotel booking manually → expense auto-created ($189/night × 5 = $945, lodging)
4. At restaurant, takes photo of receipt → scanned → "Trattoria Roma, €45.50, Food" → confirms
5. Quick adds €15 taxi (numpad → transport → done)
6. End of day: sees Budget pill badge "4 expenses · $1,345 / $3,000"
7. Next day: notification "How much did you spend yesterday?" → taps → Quick Add
8. End of trip: sees full breakdown by category, per-day spending chart
```

### Group Trip (3 Friends: Alice, Bob, Carol)

```
1. Alice creates trip "Barcelona 2026" → sets group budget $9,000
2. Invites Bob and Carol as editors
3. Bob adds flight booking → auto-expense $280, tagged as "Bob paid, full (no split)"
4. All arrive. Alice pays for group dinner → adds expense $120, "split equally"
   → System: $40 each. Bob owes Alice $40, Carol owes Alice $40
5. Bob pays for museum tickets → adds expense $60, "split equally"
   → System: $20 each. Now Bob's net debt to Alice is only $20
6. Carol scans receipt for groceries → $45, split equally → $15 each
7. Budget screen "Splits" tab shows:
   - Bob owes Alice: $5 net
   - Carol owes Alice: $25 net
   - Bob owes Carol: $0
8. End of trip: Carol taps "Settle Up" → marks $25 as paid via Venmo
9. Push notification to Alice: "Carol settled $25 via Venmo"
```

### "I Forgot to Log" Recovery

```
1. User returns from trip with 20 unlogged expenses
2. Opens Budget screen → sees only auto-created booking expenses
3. Taps "+" → "Scan Receipts" → selects 8 photos from camera roll
4. System batch-processes all 8 → shows parsed list
5. User swipes through, confirming each (or editing amounts)
6. 8 expenses logged in ~60 seconds
7. Remaining 12 were small cash purchases → Quick Adds: amount → category → done
8. Total recovery: ~5 minutes for 20 expenses
```

---

## Appendix B: Edge Function Prompt Template for Receipt Scanning

```
You are a receipt/expense parser for a travel budget app.

Given a photo of a receipt, extract the following information:

1. **merchant**: The name of the business/restaurant/store
2. **total**: The final amount paid (including tip/service charge if present)
3. **subtotal**: The amount before tip/service charge (if different from total)
4. **tip**: The tip/service charge amount (if present)
5. **currency**: The currency (use ISO 4217 codes: USD, EUR, GBP, etc.)
6. **date**: The date of the transaction (ISO 8601 format)
7. **category**: One of: flight, lodging, car, food, activities, shopping, transport, other
8. **items**: Array of line items with name and amount (if readable)

For each field, provide a confidence level:
- "verified": High confidence, clearly readable
- "check": Low confidence, user should verify

If a field is not visible or readable, set it to null with confidence "check".

Return ONLY valid JSON, no markdown formatting.
```
