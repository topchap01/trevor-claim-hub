# Roadmap

Where the claim hub is going, in order. Update it when something finishes or moves.

**Goal:** a new cashback campaign goes live within one hour of its terms being final. In the longer run, clients run their own campaigns on the hub, under their own brand, for a subscription.

**Constraint:** live campaigns keep their current claim process. The hub takes over from the next campaign onwards, after a made-up campaign has been proven in the sandbox.

## Decisions open (Mark)

- [ ] C4C: send hub claims to Electrolux on lodge, on approval, or only when staff change them (as now)?
- [ ] PNC compulsory on Electrolux campaigns?
- [x] Address on Electrolux claims: full postal address and mobile, plus everything the current Electrolux build collects (Mark, 31 Oct 2026; decisions.md #13).
- [ ] Gender and age? (Some weekly reports use them.) Address is decided for Electrolux only; other clients not yet.
- [ ] Marketing opt-in wording for Electrolux, and whose marketing it covers. Needed before the addresses can be used for marketing: the current forms send "no consent" to C4C on every claim (decisions.md #13).
- [ ] Invoice retention period (suggested: 12 months after payment).
- [x] Vercel Pro: Trevor has it (Mark, 31 Oct 2026).
- [x] Campaign addresses: every campaign at `brand.entryform.claims/campaign`; a campaign's own domain is optional and points at the hub (Mark, 1 Nov 2026; decisions.md #16, replacing #10's own domain plus yourpromotion.com.au backup).
- [ ] What the bare domain entryform.claims shows: nothing (as now) or a short Trevor page.
- [ ] Email sending domain: send claimant emails from an entryform.claims address, or keep each campaign's own sender?
- [x] Campaign look: the hub hosts each campaign's designed page (decisions.md #10).
- [x] AWS account for production invoice storage: bucket `trevor-claim-hub` in ap-southeast-2, for receipts off Salesforce (Mark, 1 Nov 2026; decisions.md #6).
- [ ] Sandbox invoices in the same bucket under `sandbox/`, with their own role and a 30-day expiry (recommended), or in a separate test bucket? Decides the sandbox role in runbook, *Invoice storage on S3*.
- [ ] Self-serve model: who approves claims and who pays claimants in each tier (see phase 4).
- [x] Next mechanics: prize draw first, then instant win (Mark, 31 Oct 2026; decisions.md #14).
- [ ] Where gift with purchase sits in that order.
- [x] Emails: automatic and standard for every campaign, no staff-written or hand-sent emails (Mark, 31 Oct 2026; decisions.md #15).
- [ ] Sandbox web address `trevor-claim-hub-test.vercel.app` is open to anyone (Vercel SSO covers only preview and per-deployment addresses). Anyone with the address can lodge test claims into Wizard and trigger paid invoice reads. Keep it open for testing and client sign-off, or protect it? (audit, 31 Oct 2026)
- [ ] Ask Trevor's paying bank whether Confirmation of Payee (account name matches account) works on batch payment uploads or by API, in NZ and AU. Decides whether the hub can check names before paying (decisions.md #11).

## Phase 1: Developer handover (now)

- [x] Engine, claim pages, builder, staff console in the sandbox
- [x] 47 Apex tests, 95% coverage; static analysis clean of high findings; independent review fixes
- [x] Code on GitHub; Vercel deploys from `main`
- [x] **Apex tests run in CI (31 Oct 2026).** `SF_SANDBOX_*` secrets set (Mark) and the CI user pre-authorised on the Claim Hub CI app in Wizard (#7). First real run, on #7: signed in to Wizard, check-only deploy, 62 of 62 tests pass (deploy ID 0Af9p00000ZhnxNCAR). CI signs in as Mark's Wizard admin user; a dedicated CI user would be tidier before Nas starts.
- [x] Apex for #3 (bank checks), #4 (returning claimants) and #6 (coverage fix) deployed to Wizard together, 62 of 62 tests passing, claim journey passing on all three campaigns (31 Oct 2026). **Wizard is now ahead of `main`.**
- [x] Merged #6, #3 and #4 to `main` (31 Oct 2026). Wizard and `main` match again.
- [ ] Replace the sandbox integration key (exposed in a working session; see runbook). Still the original key on 31 Oct 2026.
- [ ] Nas (Nettverk) reviews: GitHub invite, sandbox password reset, Vercel access
- [ ] Act on Nas's review
- [x] Bank detail checks: NZ check digits, bank and branch registers, bank name shown on the form (decisions.md #11). Merged and in Wizard (31 Oct 2026).
- [x] Bank registers loaded into Wizard (31 Oct 2026) by the **Load bank registers (Wizard)** GitHub job: 3,295 NZ branches and 17,266 AU BSBs, Salesforce's counts matching the files (run 41214896271). Monthly refresh: swap the files in `data/bank-registers/` and merge (runbook). AU bank names show as short codes until AusPayNet's *Key to Abbreviations* file is added.

## Phase 2: First production campaign

Brought forward on 31 October 2026, because a claimant who can't find their way back is a support call on every campaign: returning claimants (decisions.md #12). Built in PR #4, but its Apex is not yet in Wizard and its Apex tests have not run (audit, 31 Oct 2026). It goes to production with the rest of `salesforce/force-app`, including the new `Entry__c.Hub_Mobile_Key__c` field.

- [ ] Invoice files on S3, not Salesforce (decisions.md #6)
  - [x] Bucket `trevor-claim-hub`, ap-southeast-2 (Mark, 1 Nov 2026)
  - [x] S3 adapter in `web/lib/files.js`, signing in through Vercel OIDC, no stored AWS keys; unit tests with a stand-in S3 (1 Nov 2026)
  - [ ] AWS side (Mark, in the AWS console): Vercel as an identity provider, the sandbox role, bucket settings (runbook, *Invoice storage on S3*)
  - [ ] Sandbox switched on: four environment variables on `trevor-claim-hub-test`, smoke test passes on all three demo campaigns, an invoice opens from Salesforce
  - [ ] Production role and variables, with the production project
  - [ ] Retention lifecycle rule on `invoices/`, once the period is decided
- [ ] Production integration user, External Client App and new key pair
- [ ] Deploy `salesforce/force-app` and the legacy trigger guard to production
- [ ] Production Vercel project on Pro, custom domain, rate-limit rule, uptime monitor on `/api/health`
- [ ] Each campaign's own look and feel (decisions.md #10). Needed before the first production campaign, because that campaign must look like its brand, not like the hub.
  - [x] Designed entry page served by the hub, claim form in place, scripts stripped; proven with AEG NZ in the sandbox (31 Oct 2026, PR #2)
  - [x] Private claim page, browser tab and icon carry the campaign look (PR #2)
  - [ ] Staff upload a design to a campaign (console), stored in the public asset store, not Salesforce
  - [ ] Campaign logo and colour in emails
- [ ] Campaign addresses on entryform.claims (decisions.md #16). Brought forward on 1 Nov 2026: it replaces per-campaign DNS and the yourpromotion.com.au backup.
  - [x] Domain bought and run on Vercel's DNS; `test.entryform.claims` and `*.test.entryform.claims` on the sandbox project (1 Nov 2026)
  - [x] Web app serves `brand.<root>/campaign`; builder asks for the brand and sets the address; console shows the short address
  - [x] Wizard: `Hub_Root_Domain__c = test.entryform.claims`, the three demo campaigns on their brand addresses; deployed with #13 (deploy ID 0Af9p00000ZiN82CAF, 71 of 71 tests), claim journey passing on all three (1 Nov 2026)
  - [ ] Production project: `entryform.claims` and `*.entryform.claims`, `HUB_ROOT_DOMAIN=entryform.claims`
  - [ ] A campaign's own domain pointed at the hub, when a client wants one (optional)
- [ ] Electrolux claim fields (decisions.md #13). Needed before the first Electrolux campaign on the hub. Built as a campaign setting the builder turns on, not hard-coded to Electrolux, so another client can use it:
  - [x] postal address on the claim form (unit, street number, street, suburb, postcode, state or region), with state and region values that match `State_Mapping__mdt` (#13);
  - [x] store picked from the campaign's list, with store suburb and (AU) state (#13);
  - [x] NZ mobile also written to `Consumer_Contact_Number__c` (#13);
  - [x] Apex tests prove each field reaches the record the C4C feed reads; the smoke test sends and checks them (#13);
  - [x] deployed to Wizard from #13 (deploy ID 0Af9p00000ZhwFtCAJ, 69 of 69 tests), address and store switched on for the Electrolux cross category, Electrolux kitchen refresh and AEG NZ demo campaigns, and the smoke test passed on all three (31 Oct 2026, *Deploy to Wizard* job). Merged to `main` on 1 Nov 2026, so Wizard and `main` match again.
  - [ ] marketing opt-in tick, once Mark settles the wording.
- [ ] Load test: 2,000 claims a day with a 10× burst
- [ ] Pick the first real campaign; one real claim end to end, through to payment
- [ ] Confirm weekly client reports show hub claims
- [ ] Load the bank registers into production (needs Mark's approval), and give someone the monthly refresh

## Phase 3: Run every cashback on the hub

- [ ] Staff console covers the day's work without Salesforce screens: approvals, queue, emails, invoice view
- [ ] Email templates out of Apex into one standard set kept in this repository, with merge fields, so the builder can preview them and wording changes are reviewed once for every campaign. Never edited per campaign (decisions.md #15).
- [ ] Client reporting view (read-only, per client)
- [ ] Nightly reconcile of invoice files; automated retention
- [x] Returning claimants: "Welcome back" bar, one-tap link on a duplicate email, same-mobile flag (decisions.md #12). Merged and in Wizard; the same-mobile flag fired on every repeat smoke-test claim (31 Oct 2026).
- [ ] Claim link moved to a secure cookie (out of the address bar and hosting logs). The cookie is in place from #12; the claim page still reads `?token=`.
- [ ] Account name check before payment (Confirmation of Payee), if the paying bank offers it for batch payments
- [ ] **More mechanics, in this order (Mark, 31 Oct 2026; decisions.md #14):**
  1. **Prize draw:** entries through the promotion, winners drawn at the end. Next mechanic to build.
     - Entries, not claims: several per person where the terms allow, judged per receipt rather than per email.
     - The draw runs in the hub: secure random, a recorded and repeatable draw, reserve winners, the campaign's own time zone.
     - Winners recorded as `Entry_Win__c` against `Promotional_Campaign_Prize__c`, as today, so reports keep working.
     - Needs the permit check from the go-live gate (phase 4) at the same time, because a draw is a prize promotion.
     - Winner emails sent automatically from the standard set, one email type per prize type, no per-campaign templates and no hand sending (decisions.md #15). Ships with the standard set above and with campaign logo and colour in emails.
  2. **Instant win:** winning moments drawn and sealed at go-live, awarded under a row lock, result on screen. Reuses the entry, prize and winner records built for the draw.
  - Gift with purchase: position in this order not yet set.

## Phase 4: Client self-serve (subscription product)

The pipeline: **Quentin drafts the terms, the hub reads them and builds the campaign, the client checks and goes live under their own brand.**

- [ ] **Quentin to hub API.** Quentin submits terms and its compliance findings; the builder returns the draft campaign and issues.
- [ ] **Go-live gate.**
  - Go-live is blocked while any high-severity issue is open.
  - Prize promotions are blocked until permits are confirmed.
  - Trevor approves within an agreed time during the pilot.
- [ ] **Client portal** (web, not Salesforce licences). Each client sees only their own campaigns, numbers and claims.
- [ ] **Branding per client:**
  - their own web address (for example claims.brand.com);
  - an email domain verified for sending;
  - each campaign's own look and feel (decisions.md #10; moved forward to Phase 2).
- [ ] **Tiers.**
  - *Self-serve:* the client approves claims.
  - *Managed:* Trevor approves claims and pays claimants.
- [ ] **Billing:** subscription plus usage, priced from Trevor's measured cost per claim.
- [ ] **Contracts:** client as data owner, Trevor as processor. Fits the Terms of Business work.
- [ ] **Pilot:** one friendly client in co-pilot mode before anything is fully self-serve.

Phase 4 brings forward the question of moving off Salesforce. Client logins and per-client data separation are cheaper on the web side than as Salesforce licences (decisions.md #1a).
