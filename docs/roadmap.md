# Roadmap

Where the claim hub is going, in order. Update it when something finishes or moves.

**Goal:** a new cashback campaign goes live within one hour of its terms being final. In the longer run, clients run their own campaigns on the hub, under their own brand, for a subscription.

**Constraint:** live campaigns keep their current claim process. The hub takes over from the next campaign onwards, after a made-up campaign has been proven in the sandbox.

## Decisions open (Mark)

- [ ] C4C: send hub claims to Electrolux on lodge, on approval, or only when staff change them (as now)?
- [ ] PNC compulsory on Electrolux campaigns?
- [ ] Collect address, gender and age? (Some weekly reports use them.)
- [ ] Invoice retention period (suggested: 12 months after payment).
- [ ] Vercel Pro (needed for commercial use, team members, rate limiting, a custom domain).
- [ ] AWS account for production invoice storage.
- [ ] Self-serve model: who approves claims and who pays claimants in each tier (see phase 4).
- [ ] Ask Trevor's paying bank whether Confirmation of Payee (account name matches account) works on batch payment uploads or by API, in NZ and AU. Decides whether the hub can check names before paying (decisions.md #10).

## Phase 1: Developer handover (now)

- [x] Engine, claim pages, builder, staff console in the sandbox
- [x] 47 Apex tests, 95% coverage; static analysis clean of high findings; independent review fixes
- [x] Code on GitHub; Vercel deploys from `main`
- [ ] Replace the sandbox integration key (exposed in a working session; see runbook)
- [ ] Nas (Nettverk) reviews: GitHub invite, sandbox password reset, Vercel access
- [ ] Act on Nas's review
- [ ] Bank detail checks: NZ check digits, bank and branch registers, bank name shown on the form (decisions.md #10). Built; merge once the Apex tests pass in Wizard, then load the registers into Wizard.

## Phase 2: First production campaign

- [ ] S3 adapter for invoice files, Sydney bucket with retention rule
- [ ] Production integration user, External Client App and new key pair
- [ ] Deploy `salesforce/force-app` and the legacy trigger guard to production
- [ ] Production Vercel project on Pro, custom domain, rate-limit rule, uptime monitor on `/api/health`
- [ ] Load test: 2,000 claims a day with a 10× burst
- [ ] Pick the first real campaign; one real claim end to end, through to payment
- [ ] Confirm weekly client reports show hub claims
- [ ] Load the bank registers into production (needs Mark's approval), and give someone the monthly refresh

## Phase 3: Run every cashback on the hub

- [ ] Staff console covers the day's work without Salesforce screens: approvals, queue, emails, invoice view
- [ ] Email wording editable by staff (templates out of Apex)
- [ ] Client reporting view (read-only, per client)
- [ ] Nightly reconcile of invoice files; automated retention
- [ ] Claim link moved to a secure cookie (out of the address bar and hosting logs)
- [ ] Account name check before payment (Confirmation of Payee), if the paying bank offers it for batch payments
- [ ] More mechanics: gift with purchase, then instant win and prize draws (designed, not built)

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
  - theme.
- [ ] **Tiers.**
  - *Self-serve:* the client approves claims.
  - *Managed:* Trevor approves claims and pays claimants.
- [ ] **Billing:** subscription plus usage, priced from Trevor's measured cost per claim.
- [ ] **Contracts:** client as data owner, Trevor as processor. Fits the Terms of Business work.
- [ ] **Pilot:** one friendly client in co-pilot mode before anything is fully self-serve.

Phase 4 brings forward the question of moving off Salesforce. Client logins and per-client data separation are cheaper on the web side than as Salesforce licences (decisions.md #1a).
