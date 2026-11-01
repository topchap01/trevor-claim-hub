# Trevor Claim Hub

One set of claim pages for every cashback promotion Trevor Services runs. Salesforce stays the system of record. A small Next.js app on Vercel is the only thing the public touches.

- **Claimants** lodge on their phone in about two minutes. They get a private link by email, with no account or password. They add the invoice, serial numbers and bank details whenever they have them, and can see what is still missing and by when.
- **The Trevor team** loads a campaign by pasting its terms and conditions. Claude reads the terms and lists the problems it finds. A person checks the result, then the builder creates the campaign, cashback tiers and product list. Day to day, staff work from one console screen per campaign: claims ready to approve, claims needing a person, and email status.
- **Clients' existing reports and feeds keep working.** Hub claims are ordinary `Entry__c` records carrying the same stamps the old forms set.

Status: running end to end in the **Wizard sandbox**. Not yet in production. See [docs/production-checklist.md](docs/production-checklist.md).

## What is in this repository

| Path | What it is |
|---|---|
| `salesforce/force-app` | The hub engine. Apex REST API, status engine, email outbox, reminders, health monitor, terms-to-campaign builder, staff console (LWC), custom objects and fields, permission sets, tests. |
| `salesforce/legacy-patches` | Changes to existing org components. A null guard in the `PromotionalCampainCreation` trigger, plus the earlier claim-link fix's backfill job and its test, which exercise old-form classes not in this repository. Review these separately: they touch code the old claim forms use. |
| `salesforce/integration` | The External Client App the web app signs in with (OAuth JWT bearer, certificate only, no secret). Org-specific. |
| `web` | The Next.js 16 claim pages and their server routes. These are the only callers of the Salesforce API. |
| `scripts` | Test runner, end-to-end smoke test, job scheduling. |
| `docs` | Architecture, API, security, runbook, production checklist, decisions. |

## Start here

1. **Read** [docs/architecture.md](docs/architecture.md), then [docs/security.md](docs/security.md). Where the project is going: [docs/roadmap.md](docs/roadmap.md). Standing rules for anyone working on it: [CLAUDE.md](CLAUDE.md).
2. **See it in the sandbox.** Log in to the Wizard sandbox (`test.salesforce.com`). Open the **Claim Hub** app from the App Launcher. Pick *AEG NZ Harvey Norman Cashback Summer 2026 (sandbox)* in the console, or use **Campaign from Terms** to build one. The claimant side is at `https://aeg.test.entryform.claims/nz-cashback` (decisions.md #16). That address is open; preview deployments are behind Vercel SSO, so ask Mark for access to those.
3. **Run the tests:**

```bash
# Salesforce: deploy, then run every hub test with coverage
sf org login web --instance-url https://test.salesforce.com --alias wizard
cd salesforce && sf project deploy start -o wizard -d force-app --wait 20 && cd ..
scripts/run-apex-tests.sh wizard          # all hub tests, about 95% coverage of hub classes

# Web: lint, unit tests, production build
cd web && npm ci && npm run lint && npm test && npm run build

# End to end against a running app (creates made-up @example.com claims)
node scripts/smoke-test.mjs http://127.0.0.1:3100 aeg-nz-cashback
```

4. **Run the web app locally.** Copy `web/.env.example` to `web/.env.local` and fill it in (see the file). Then run `npm run dev`. Without `BLOB_READ_WRITE_TOKEN`, invoices are stored in Salesforce Files instead of Vercel Blob.

## Quality gates

- **Apex:** 47 tests, all passing, 95% line coverage across hub classes. That includes tests through the REST layer for the security-code limit, link rotation and file ownership. Callouts to Claude are faked by `ClaimHubTestFactory.Claude`, so tests never call the real API. Bulk tests prove the status handler, reminders and outbox stay inside governor limits.
- **Static analysis:** `sf code-analyzer run --workspace force-app --rule-selector Recommended --config-file code-analyzer.yml`. No critical or high findings.
  - CRUD/FLS findings are suppressed on purpose, with the reason written in each class. The API runs in system mode as a minimum-access integration user. See security.md.
  - Complexity findings remain on `lodge`, `ClaimHubTerms.build` and `ClaimHubNotifier.render`. These are listed as follow-ups in [docs/decisions.md](docs/decisions.md).
- **Web:** ESLint (`eslint-config-next`) is clean. `node --test` covers the cashback maths the claim form shows as people type.
- **CI:** `.github/workflows/ci.yml` runs all of the above on every push. The Salesforce job needs the secrets listed in the workflow.

## Dependencies already in the org

The hub reuses these rather than duplicating them:

- **Nebula Logger**, for error logging.
- **`Claude_Setting__mdt.Default`**, the Anthropic API key, read through the existing `ClaudeInvoiceExtractionBatch.getApiKey()`.
- **The existing claims objects:** `Promotional_Campaign__c`, `Entry__c`, `Entry_Product__c`, `Entry_Receipt__c`, `Cashback_Range__c`, `Campaign_Product__c`, `Promotional_Product__c` and `Lead`.
- **The `Access_Token__c` claim link field** and `ClaimAccessToken`. These came from the earlier claim-link security fix.
