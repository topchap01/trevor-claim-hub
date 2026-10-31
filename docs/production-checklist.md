# Production checklist

Nothing in this repository has been deployed to production. Production Salesforce has only been read.

## Decisions needed (Mark / Trevor)

- [ ] **C4C.** Today, hub claims reach Electrolux C4C only when staff change them, because the integration user doesn't hold `ElectroluxC4C_Basic_Auth_Access`. Should they be sent on lodge, on approval only, or as now?
- [ ] **PNC compulsory on Electrolux campaigns?** C4C only receives product details when a PNC is present.
- [ ] **Collect address, gender and age?** The old forms did, and some weekly reports (*Valids by State*, *Gender Split*, *Age Report*) use them.
- [ ] **Consent wording** for Electrolux marketing opt-in, if wanted.
- [ ] **Invoice retention period** (suggested: 12 months after payment, unless client contracts say otherwise), and who may open invoice files.
- [ ] **AWS account** for the production invoice store (S3, Sydney). Agreed in principle on 30 Oct 2026; see decisions.md #6.
- [x] **Vercel plan.** Trevor has Vercel Pro (Mark, 31 Oct 2026).
- [x] **Campaign addresses.** Own domain per campaign, plus a backup on yourpromotion.com.au (decisions.md #10).

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
- [ ] **File storage is at 119% in production (−9,175 MB remaining).** The hub no longer adds invoice files to Salesforce, but the overage still needs a clean-up or more storage.
- [ ] Recommended: move the Anthropic key from `Claude_Setting__mdt` to a Named Credential.
- [ ] Recommended: ask Salesforce Support for a custom index on `Entry_Product__c.Serial_Number__c`. Duplicate checks against old-form claims scan about 42,000 rows today.

## Legacy issues found while testing (not caused by the hub)

- `EntryCreation` trigger queries the Lead once per inserted Entry. Bulk inserts of more than about 90 Entries fail on the SOQL limit (found by `ClaimHubEntryHandlerTest`). The hub inserts one at a time, so it is unaffected. Data loads into the old objects should use small batches until it is bulkified.
- The C4C feed sends one message per Entry_Product on every save, and `InvoiceNo` is the receipt record's auto-number rather than the real invoice number. Nothing retries failures: 90 failed sends across three campaigns in 120 days.
- The `Electrolux Kitchen` NZ report folder is named `ELN0002 …` (copy-paste).

## Web production

- [ ] New Vercel project, or production environment, connected to this repository's `main` branch.
- [ ] Environment variables: `SF_LOGIN_URL` (`https://login.salesforce.com` or the My Domain), `SF_AUDIENCE=https://login.salesforce.com`, `SF_USERNAME`, `SF_CLIENT_ID`, `SF_PRIVATE_KEY` (sensitive), and `BLOB_READ_WRITE_TOKEN` (from connecting a production Blob store).
- [ ] Set `HUB_ENV=production` to remove the sandbox banner. Leave `HUB_HOME_SLUG` unset, so the bare domain shows nothing.
- [ ] Custom domain and HTTPS.
- [ ] Content security policy (`web/next.config.mjs`) allows each campaign's images and fonts. Today it allows only the hub's own address.
- [ ] Live campaign pages indexable by search engines. Today every page sends `noindex`. Claim-status pages (`/c`) stay noindex.
- [ ] WAF rule: `POST /api/*`, 30 a minute per IP, deny.
- [ ] Uptime monitor on `/api/health`.
- [ ] Add `BLOB_READ_WRITE_TOKEN` as a *sensitive* variable. In the sandbox project it is stored readable, and Vercel flags it (`readable-secret`).
- [ ] Set the project's Node.js version to 22.x to match `web/package.json` and CI. The sandbox project says 26.x; `engines` in package.json takes precedence on Vercel, so builds use 22.x, but the two should agree.
- [ ] Load test before launch: about 2,000 claims a day, with a 10× burst (k6 script, not yet written).

## Go-live

- [ ] Smoke test passes against production with a hidden test campaign.
- [ ] One real claim end to end, approved and paid through the existing payment file.
- [ ] Weekly reports show the hub claims. They filter on `Promotional_Campaign_Stamp__c`, which the hub sets, and `Date_Validated__c`, which the existing `Entry_Automation_1` flow sets when a claim becomes Valid.
