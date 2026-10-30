# Sandbox guide (Wizard)

Org: `https://trevor-services--wizard.sandbox.my.salesforce.com`. Log in through test.salesforce.com.

Your user has the `Claim_Hub_Admin` and `Claim_Link_Admin` permission sets.

## Campaigns on the hub

| Campaign | Web address | What it shows |
|---|---|---|
| AEG NZ Harvey Norman Cashback Summer 2026 (sandbox) | `/aeg-nz-cashback` | Built by the builder from AEG's real NZ terms, with new dates. Has spend bands (NZ$5,000+), a Harvey Norman-only rule, a single transaction, T2 serial prefixes A, B and C excluded, and NZ bank accounts. |
| Electrolux AU Cross Category Cashback (sandbox copy) | `/electrolux-cross-category` | Built from production ELN0002's terms. Pays 15% of spend for 2 appliances and 20% for 3 or more. Has 93 products and AU bank details. |
| Electrolux Kitchen Refresh Cashback 2027 | `/electrolux-kitchen-refresh` | The first made-up demo: fixed amounts by quantity. |

The web app runs at `https://trevor-claim-hub-test.vercel.app` and is protected by Vercel SSO.

## Claims to look at (AEG NZ)

| Claim | Stage | Look for |
|---|---|---|
| ENT-261030-211710 | Approved | The full journey: invoice read automatically, serial scanned from a photo, a T2 serial refused and flagged, then approved. |
| ENT-261030-211711 | Paid | Smoke-test claim. Flagged because its bank account is on another claim. |
| ENT-261030-211714 | Awaiting (serials still to add) | Lodged through the live site on 30 Oct. The invoice passed every automatic check. The file is in private Blob storage, not Salesforce. Try *View invoice*. |
| ENT-261030-211700 | Payment failed | Open its claim page to see the claimant's "update bank details" path. |
| ENT-261030-211701 | Not approved | Shows the rejection reason and email. |
| ENT-261030-211708 / 211709 | Awaiting | Duplicate-serial and excluded-serial flags in the console's *Needs a person* list. |

Every claim has:
- an activity list (`Claim_Event__c`);
- the exact emails sent (`Claim_Notification__c`): open one and read `Body__c`.

The claimant's link code is in `Access_Token__c`, readable with `Claim_Link_Admin`. Open `/c?token=<code>` to see their page.

## Things to try

1. **Build a campaign from terms.** Claim Hub → *Campaign from Terms*. The terms used are in `scripts/fixtures/terms/`. Reading takes about 70 seconds.
2. **Lodge a claim and break it.** On the claim page:
   - try an AU BSB on the NZ campaign;
   - try a spend under NZ$5,000;
   - try a serial starting with A.
3. **Upload an invoice**, then check the staff side: console → *View invoice* opens it from private storage through a 10-minute link.
4. **Health:** `/api/health`.
5. **Tests:** `scripts/run-apex-tests.sh wizard`.

Test claims use made-up people at `@example.com`. One early claim (ENT-261030-211703) uses Mark's own email.
