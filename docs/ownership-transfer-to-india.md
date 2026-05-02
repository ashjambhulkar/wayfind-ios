# Ownership Transfer to India — Tax/Legal Minimum Checklist

> Personal notes. Not legal or tax advice. Confirm everything with a US immigration attorney, a US CPA who handles foreign entity ownership, and an Indian CA before acting.

## Goal

Transfer only what is required so that, from a tax/legal/financial standpoint, the app belongs to and is paid to my sister in India, who will run it as an Indian sole proprietor business.

## What tax authorities actually care about

Both the US (IRS) and India (Income Tax + GST) only look at:

1. Who is contracted with the payer (Apple).
2. Whose name and bank account receives the money.
3. Who signs the tax forms (W-8BEN, GST returns, ITR).
4. Whose business legally exists with the right registrations.

Everything else (GitHub, Supabase, domains, API keys, code, branding) is operational and not tax-relevant.

## Minimum transfers required for tax purposes

### 1. Apple Developer Account / App ownership

The single most important transfer — Apple is the payer.

- Sister enrolls in the Apple Developer Program in her name (Individual or Organization).
- Initiate App Transfer in App Store Connect → her account.
- After transfer, **she** completes:
  - Paid Apps Agreement.
  - Banking info (her current account in India).
  - W-8BEN (or W-8BEN-E if entity) declaring India tax residency.
  - Tax forms for every region Apple sells in.

After this step, Apple pays her, reports to her PAN/tax ID, and my name is no longer on the payee side.

### 2. Indian business registrations (so she has a legal vehicle to declare income)

- PAN (already has).
- GST registration (required because Apple = export of services).
- Current account in her name (sole prop) at an Indian bank.
- IEC code (free, one-time, from DGFT) — bank will ask for it on foreign currency.
- Optional but useful: Udyam/MSME registration (free).
- Optional: D-U-N-S number (only if Apple enrolled as Organization).

### 3. RevenueCat billing owner

Only relevant because RevenueCat charges a fee:

- Add her as Owner on the RevenueCat project.
- Move payment method to her card.
- Remove mine.

### 4. Other paid services billed in my name

Move billing/payment methods on these to her card so the expenses are hers and deductible against her business income in India:

- Apple Developer Program fee ($99/yr) — moves with the account when she enrolls.
- RevenueCat (above).
- Supabase (if I am paying).
- Domain registrar.
- RapidAPI / AeroDataBox.
- Sentry / analytics, etc.

## What I do NOT need to transfer for tax purposes

- GitHub repo ownership.
- Supabase project ownership (only billing matters).
- API keys, technical admin access, code, infra, DNS.
- App branding, marketing accounts, social handles.

These don’t appear on any tax form.

## Cleanest minimum sequence

1. She gets PAN + GST + Current Account + IEC (≈ 2–3 weeks in India).
2. She enrolls in Apple Developer Program in her name.
3. App Transfer in App Store Connect → her account.
4. She signs Paid Apps Agreement + banking + W-8BEN + tax in App Store Connect.
5. Move billing/payment methods of paid app services (RevenueCat, Supabase, domain, APIs) to her card.
6. She files GST returns (monthly/quarterly) and annual ITR in India through her CA.

## "I never received money on my name in the US — do I have any US obligation?"

This is the most important point to be honest about. **Not receiving money in your name in the US does NOT, by itself, end your US tax/immigration exposure.** Two separate issues are often confused:

### A) US tax exposure

The IRS does NOT only tax money that hits a US bank account in your name. It taxes:

1. **Worldwide income of US tax residents.** If you meet the Substantial Presence Test (≈ 183 weighted days in the US), you are a US tax resident and must report worldwide income — even income earned and received outside the US.
2. **Effectively connected income (ECI).** Income earned from work physically performed in the US is generally US-source and US-taxable, regardless of where it is paid or to whom.
3. **Assignment-of-income / nominee doctrines.** If the IRS concludes someone else is named on paper but you are the actual earner (you do the work, you control the asset, you benefit), they can re-attribute the income to you. Money never has to touch your account.
4. **Beneficial ownership rules.** If you are a beneficial owner of a foreign business, additional disclosures may apply (FBAR, FATCA Form 8938, Form 5471 for controlled foreign corp, Form 8865, etc.).

So:
- If sister truly runs and owns it and I do not work on it from the US → low/no US tax exposure on the app revenue, because it is genuinely her income.
- If I am still building/operating it from the US → IRS can treat that work as US-source income to me regardless of whose account got paid.

The phrase "I never received any money on my name in the US" is **not a defense** if the IRS examines it. They look at substance, not just bank statements.

### B) US immigration (H-1B) exposure

Completely separate from tax:

- H-1B restricts unauthorized work in the US.
- Building, shipping, supporting, configuring infra for someone else’s business while in the US = unauthorized work, even unpaid, even for family.
- Money flow is not what USCIS examines; activity is.
- Putting the app in sister’s name does not, by itself, fix this.

To be clean on H-1B I must actually stop doing operational work from the US (code, releases, support, infra admin), or change immigration status, or do that work only when outside the US.

### Practical conclusion

- The transfers above clean up the **money/paper** problem with Apple, India tax, and US tax-on-revenue.
- They do NOT clean up the **work-being-done-in-the-US** problem under H-1B.
- They do NOT guarantee the IRS will accept the income as not mine — that depends on whether the operational story (who actually runs it) holds up.

## Action plan for me

- Do not assume "no US bank deposit = no US obligation." Confirm with a US CPA.
- Get 30 minutes with a US immigration attorney before launch.
- Pick a clear role: fully out, or unpaid advisor with no operational work.
- Keep no admin/owner access to Apple, RevenueCat (billing), banking, or anything that signs contracts.
- Document nothing in writing that contradicts the operational story.

## Open items / TODO

- [ ] Sister obtains PAN (verify), GST, Udyam, IEC, D-U-N-S, current account.
- [ ] Sister enrolls in Apple Developer Program.
- [ ] Initiate App Transfer in App Store Connect.
- [ ] Sister signs Paid Apps Agreement, banking, W-8BEN, tax forms.
- [ ] Move billing of RevenueCat, Supabase, domain, API services to her card.
- [ ] Sister engages a CA in India for GST + ITR filings.
- [ ] Book consult with US immigration attorney (H-1B founder specialist).
- [ ] Book consult with US CPA (foreign entity / nominee / Form 5471 expertise).
- [ ] Decide my own role going forward (fully out / advisor / wait for status change).
