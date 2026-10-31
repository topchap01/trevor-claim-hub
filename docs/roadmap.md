# Roadmap

Where the claim hub is going, in order. Update it when something finishes or moves.

**Goal:** a new cashback campaign goes live within one hour of its terms being final. In the longer run, clients run their own campaigns on the hub, under their own brand, for a subscription.

**Constraint:** live campaigns keep their current claim process. The hub takes over from the next campaign onwards, after a made-up campaign has been proven in the sandbox.

## Decisions open (Mark)

- [ ] C4C: send hub claims to Electrolux on lodge, on approval, or only when staff change them (as now)?
- [ ] PNC compulsory on Electrolux campaigns?
- [ ] Collect address, gender and age? (Some weekly reports use them.)
- [ ] Invoice retention period (suggested: 12 months after payment).
- [x] Vercel Pro: Trevor has it (Mark, 31 Oct 2026).
- [x] Campaign addresses: the campaign's own domain, plus a backup address on yourpromotion.com.au (decisions.md #10).
- [x] Campaign look: the hub hosts each campaign's designed page (decisions.md #10).
- [ ] AWS account for production invoice storage.
- [ ] Self-serve model: who approves claims and who pays claimants in each tier (see phase 4).

## Phase 1: Developer handover (now)

- [x] Engine, claim pages, builder, staff console in the sandbox
- [x] 47 Apex tests, 95% coverage; static analysis clean of high findings; independent review fixes
- [x] Code on GitHub; Vercel deploys from `main`
- [ ] Replace the sandbox integration key (exposed in a working session; see runbook)
- [ ] Nas (Nettverk) reviews: GitHub invite, sandbox password reset, Vercel access
- [ ] Act on Nas's review

## Phase 2: First production campaign

- [ ] S3 adapter for invoice files, Sydney bucket with retention rule
- [ ] Production integration user, External Client App and new key pair
- [ ] Deploy `salesforce/force-app` and the legacy trigger guard to production
- [ ] Production Vercel project on Pro, custom domain, rate-limit rule, uptime monitor on `/api/health`
- [ ] Each campaign's own look and feel (decisions.md #10). Needed before the first production campaign, because that campaign must look like its brand, not like the hub.
  - [ ] Designed entry page served by the hub, claim form in place, scripts stripped; proven with AEG NZ in the sandbox
  - [ ] Staff upload a design to a campaign (console), stored in the public asset store, not Salesforce
  - [ ] Campaign logo and colour in emails
- [ ] Campaign addresses: the hub serves each campaign on its own domain and on a yourpromotion.com.au backup address; the builder adds both to Vercel (decisions.md #10). Check how yourpromotion.com.au's DNS is run, since it also carries the existing Experience site.
- [ ] Load test: 2,000 claims a day with a 10× burst
- [ ] Pick the first real campaign; one real claim end to end, through to payment
- [ ] Confirm weekly client reports show hub claims

## Phase 3: Run every cashback on the hub

- [ ] Staff console covers the day's work without Salesforce screens: approvals, queue, emails, invoice view
- [ ] Email wording editable by staff (templates out of Apex)
- [ ] Client reporting view (read-only, per client)
- [ ] Nightly reconcile of invoice files; automated retention
- [ ] Claim link moved to a secure cookie (out of the address bar and hosting logs)
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
  - each campaign's own look and feel (decisions.md #10; moved forward to Phase 2).
- [ ] **Tiers.**
  - *Self-serve:* the client approves claims.
  - *Managed:* Trevor approves claims and pays claimants.
- [ ] **Billing:** subscription plus usage, priced from Trevor's measured cost per claim.
- [ ] **Contracts:** client as data owner, Trevor as processor. Fits the Terms of Business work.
- [ ] **Pilot:** one friendly client in co-pilot mode before anything is fully self-serve.

Phase 4 brings forward the question of moving off Salesforce. Client logins and per-client data separation are cheaper on the web side than as Salesforce licences (decisions.md #1a).
