# Production checklist

Nothing in this repository has been deployed to production. Production Salesforce has only been read.

## Decisions needed (Mark / Trevor)

- [ ] **C4C.** Today, hub claims reach Electrolux C4C only when staff change them, because the integration user doesn't hold `ElectroluxC4C_Basic_Auth_Access`. Should they be sent on lodge, on approval only, or as now?
- [ ] **PNC compulsory on Electrolux campaigns?** C4C only receives product details when a PNC is present.
- [x] **Address on Electrolux claims.** Full postal address and mobile, plus everything the current Electrolux build collects (Mark, 31 Oct 2026; decisions.md #13).
- [ ] **Gender and age?** Some weekly reports (*Gender Split*, *Age Report*) use them. *Valids by State* is covered on Electrolux by #13.
- [ ] **Consent wording** for the Electrolux marketing opt-in, and whose marketing it covers. Now wanted (decisions.md #13). The current forms leave `By_continuing_you_agree_to_Electrolux_s__c` unticked, so C4C receives `dataProtectionConsent: N` on every claim (all 4,125 Electrolux claims in the 180 days to 31 Oct 2026).
- [ ] **Invoice retention period** (suggested: 12 months after payment, unless client contracts say otherwise), and who may open invoice files. An S3 lifecycle rule counts from upload, not payment, so the rule is set as upload plus the longest claim-to-payment time plus the period, or the hub tags files when a claim is paid.
- [x] **AWS account** for the production invoice store: bucket `trevor-claim-hub`, ap-southeast-2 (Mark, 1 Nov 2026; decisions.md #6).
- [x] **Vercel plan.** Trevor has Vercel Pro (Mark, 31 Oct 2026).
- [x] **Campaign addresses.** Every campaign at `brand.entryform.claims/campaign` (Mark, 1 Nov 2026; decisions.md #16, replacing #10).
- [ ] **Confirmation of Payee for batch payments.** Ask Trevor's paying bank whether it is offered on payment file uploads or by API, in NZ and AU (decisions.md #11).

## Salesforce production changes

- [ ] Deploy `salesforce/force-app`. This adds fields and objects, classes, LWCs, tabs, the app and permission sets. It also adds a trigger on `Entry__c` (after update), which only acts on hub campaigns.
- [ ] Deploy `salesforce/legacy-patches/…/PromotionalCampainCreation.trigger`. This adds a null guard; without it, creating a campaign with no record type throws.
- [ ] Create the production integration user:
  - profile: *Minimum Access – API Only Integrations*;
  - permission set: `Claim_Hub_Integration`;
  - no password login.
- [ ] Create the production External Client App:
  - a new certificate, generated for production only;
  - JWT bearer enabled;
  - pre-authorised for the integration user's permission set.
- [ ] `Claim_Hub_Settings__c` org default: alert email, file base URL, debounce 10.
- [ ] Run `scripts/apex/schedule-jobs.apex`.
- [ ] Verify org-wide email addresses for each campaign sender, and check deliverability.
- [ ] Assign `Claim_Hub_Admin` to the claims team.
- [ ] Load the bank registers into `Hub_Bank_Branch__c` (decisions.md #11): `node scripts/load-bank-register.mjs --org <prod> --nz <Payments NZ .xlsx> --au BSBDirectoryFull.txt --au-key <key>.csv --approved-for-production`. Before the first load:
  - confirm Payments NZ's terms allow the Bank Branch Register to be used this way;
  - check production **data** storage has room for the rows (one per NZ branch and AU BSB; the January 2026 NZ register lists 3,296 branch numbers);
  - load before the first live claim: until a register is loaded, an unknown NZ bank code or AU BSB is neither refused nor flagged;
  - name who runs the monthly refresh (AusPayNet updates on the first NSW business day of each month).
- [ ] **File storage is at 119% in production (−9,175 MB remaining).** The hub no longer adds invoice files to Salesforce, but the overage still needs a clean-up or more storage.
- [ ] Recommended: move the Anthropic key from `Claude_Setting__mdt` to a Named Credential.
- [ ] Recommended: ask Salesforce Support for a custom index on `Entry_Product__c.Serial_Number__c`. Duplicate checks against old-form claims scan about 42,000 rows today.

## Testing gaps

- [x] **CI runs the Apex tests** in Wizard on every pull request and push to `main` (from 31 Oct 2026; secrets set by Mark, CI user pre-authorised in #7). A green Salesforce job now means the hub deployed and its tests passed in Wizard.
- [ ] **Returning claimants (#4) in Wizard, by hand in a phone browser.** Deployed and Apex-tested on 31 Oct 2026 (62 of 62), and the same-mobile flag is confirmed. Still to walk through on the sandbox address: lodge, open the promotion page again (expect "Welcome back"), claim again with the same email (expect the one-tap link), and claim with a new email and the same mobile (expect the review flag in the console).

## Legacy issues found while testing (not caused by the hub)

- `EntryCreation` trigger queries the Lead once per inserted Entry. Bulk inserts of more than about 90 Entries fail on the SOQL limit (found by `ClaimHubEntryHandlerTest`). The hub inserts one at a time, so it is unaffected. Data loads into the old objects should use small batches until it is bulkified.
- The C4C feed sends one message per Entry_Product on every save, and `InvoiceNo` is the receipt record's auto-number rather than the real invoice number. Nothing retries failures: 90 failed sends across three campaigns in 120 days.
- The `Electrolux Kitchen` NZ report folder is named `ELN0002 …` (copy-paste).

## Web production

- [ ] New Vercel project, or production environment, connected to this repository's `main` branch.
- [ ] Environment variables: `SF_LOGIN_URL` (`https://login.salesforce.com` or the My Domain), `SF_AUDIENCE=https://login.salesforce.com`, `SF_USERNAME`, `SF_CLIENT_ID`, `SF_PRIVATE_KEY` (sensitive), and for invoices `S3_BUCKET_NAME=trevor-claim-hub`, `S3_REGION=ap-southeast-2`, `AWS_ROLE_ARN` (the production role), no `S3_KEY_PREFIX`. No Blob store and no `BLOB_READ_WRITE_TOKEN` in production.
- [ ] Set `HUB_ENV=production` to remove the sandbox banner. Leave `HUB_HOME_SLUG` unset, so the bare domain shows nothing.
- [ ] Domains `entryform.claims` and `*.entryform.claims` on the production project (both already on Trevor's Vercel team; the wildcard needs Vercel's nameservers, which the domain uses). Set `HUB_ROOT_DOMAIN=entryform.claims` (decisions.md #16).
- [ ] `Claim_Hub_Settings__c.Hub_Root_Domain__c = entryform.claims` in production, so the builder gives campaigns their brand address.
- [ ] Content security policy (`web/next.config.mjs`) allows each campaign's images and fonts. Today it allows only the hub's own address.
- [ ] Live campaign pages indexable by search engines. Today every page sends `noindex`. Claim-status pages (`/c`) stay noindex.
- [ ] WAF rule: `POST /api/*`, 30 a minute per IP, deny.
- [ ] Uptime monitor on `/api/health`.
- [ ] Production AWS role `trevor-claim-hub-production`, **in the bucket's account (Future Unicorn, 838547582670)**: trusts only the production project's `production` environment, may only put, get and delete under `trevor-claim-hub/invoices/` (runbook, *Invoice storage on S3*). OIDC federation on, Team issuer, in the production project.
- [ ] One test invoice through the production smoke test, opened from production Salesforce, then deleted.
- [ ] Set the project's Node.js version to 22.x to match `web/package.json` and CI. The sandbox project says 26.x; `engines` in package.json takes precedence on Vercel, so builds use 22.x, but the two should agree.
- [ ] Load test before launch: about 2,000 claims a day, with a 10× burst (k6 script, not yet written).

## Go-live

- [ ] Smoke test passes against production with a hidden test campaign.
- [ ] One real claim end to end, approved and paid through the existing payment file.
- [ ] Weekly reports show the hub claims. They filter on `Promotional_Campaign_Stamp__c`, which the hub sets, and `Date_Validated__c`, which the existing `Entry_Automation_1` flow sets when a claim becomes Valid.
