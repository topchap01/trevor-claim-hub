# Decisions

Short records of the choices that shape the code, and what would change them.

**1. Headless Salesforce with a separate web app, not Experience Cloud.**
- *Why:*
  - Mobile speed.
  - No guest-user access to the org.
  - No per-login cost.
  - Independent releases.
- *Cost:* an integration user and a second deployment.
- *Revisit if* Trevor wants claimants to have accounts across campaigns.

**1a. Salesforce stays, for now, with a cheap way out.**
- Salesforce carries more than claims:
  - the claim history;
  - the weekly client reports;
  - the Electrolux C4C flow;
  - the payments process and staff screens.
- Replacing it while the claim experience is also being replaced would double the risk.
- The web app talks only to the `/claimhub/v1` API, and the rules are covered by tests, so the back end behind that API can be replaced later without touching the claim pages.
- *Revisit when:*
  1. staff work mainly in the hub console;
  2. client reports come from a reporting tool;
  3. Electrolux takes C4C data by API;
  4. licence and storage cost clearly exceed a hosted Postgres plus reporting.

**2. Vercel for the web app.**
- *Why:*
  - Next.js hosting with no servers to run.
  - Sydney region.
  - Preview deployments per pull request.
  - Private Blob storage alongside.
- *Plan:* Pro (Mark, 31 Oct 2026).
- *Alternative:* any Node host. The app uses no Vercel-only APIs apart from `@vercel/blob`, which sits behind `web/lib/files.js`.

**3. Rules live in Apex; the web app holds no state.**
- Reports, the payment file and C4C read the same records.
- A second front end (staff entry, postal claims) would reuse the API.

**4. Reuse the existing claim objects, with shared record types.**
- *Why:*
  - Existing reports, flows and the payments process keep working.
  - Shared `Claim_Hub` record types mean no metadata deploy per campaign.
- *Cost:* the hub sets the stamps the old trigger used to set.
- A campaign can still keep its own record types, if it must also run on the old forms.

**5. Claude calls stay in Apex, synchronously.**
- Salesforce does not count callout time toward the concurrent long-running request limit.
- So a 10 to 20 second invoice read does not threaten throughput, and the claimant sees the result immediately.
- *Revisit if* the per-transaction callout limit or timeouts become a problem. The read could then move to a Queueable, with the page polling.

**6. Invoice files outside Salesforce: Vercel Blob in the sandbox, Amazon S3 (Sydney) for production.**
- Production Salesforce file storage is over its limit, so invoices never go there.
- Staff open files through short-lived tickets issued by Salesforce; Salesforce stores only the file key.
- S3 for production because:
  - files stay in the Sydney region;
  - a lifecycle rule handles retention with no code;
  - access logging and Object Lock are available;
  - the files are independent of the web host.
- Vercel Blob's Hobby plan also caps storage at 1 GB and blocks access when that is exceeded.
- All file handling is in `web/lib/files.js`, so the switch is one adapter plus environment variables. Access goes through Vercel's AWS sign-in (OIDC), so no long-lived AWS keys are stored.

**7. Flag, don't refuse, where a person should judge.** Shared bank accounts, the same invoice twice and several claims from one connection all have innocent explanations (households, shared office networks), so they go to the review queue. Certain cases are refused outright:
- a duplicate email on the same promotion;
- a serial already used;
- an excluded serial prefix;
- the minimum spend not met.

**8. Bank changes need an emailed code.** SMS would be stronger against a compromised mailbox, but needs an SMS provider. *Revisit for* high-value campaigns.

**9. Emails go through an outbox object, with one dispatcher.** Every email is a record before it is sent, so nothing is lost when sending fails, staff can see what each claimant received, and changes made close together are merged into one email. The dispatcher locks the rows it sends (`FOR UPDATE`, status re-checked). A delayed job only re-queues itself when no other dispatcher is waiting, so overlapping runs never send an email twice and job chains never multiply.

**10. Each campaign has its own look and feel. Entry pages are not standardised.** (Mark, 31 Oct 2026)
- Every campaign's consumer pages carry that campaign's own design, as the current microsites do. One template with a swappable colour and logo is not enough.
- What stays common is the claim engine: rules, checks, the claim record, emails, payments.
- **How the design is delivered (Mark, 31 Oct 2026): the hub hosts it.** The studio's page (HTML, CSS, images, fonts) is attached to the campaign and served by the hub, with the standard claim form placed where the page marks it. No code deploy per campaign. No scripts are allowed in a design, because the same page takes bank details; the hub strips them.
- The claim steps (form, private claim page, serials, bank details) stay common to every campaign and take the campaign's colours, fonts and logo from its design.
- **Addresses (Mark, 31 Oct 2026).** Each campaign is served on its own domain, as now (for example aegcashbackpromo.co.nz), which the builder adds to Vercel. It also gets a backup address on yourpromotion.com.au as soon as it is built, for testing, client sign-off and late DNS. Claim links carry the claim code and campaign, so reusing a domain for a brand's next campaign does not break earlier claims.
- **Not now (Mark, 31 Oct 2026):** source tags on QR codes for counting claims by channel.
- *Found while scoping:* the hub's security policy allows images and fonts only from its own address, and every page is marked noindex. Both must change per campaign before go-live (production-checklist.md).

**11. Bank details are checked against published rules and registers: refuse only what can't be paid, flag the rest.** *(Mark, 31 Oct 2026)*
- *What happens:*
  - **NZ check digit fails** (for a bank with a published check): refused on the form, with a plain message. The claimant is there to fix it, and the number can't be right.
  - **Bank, branch or BSB not in the register:** accepted and flagged for review. A register can lag behind a new bank or branch, so a real account must not be turned away.
  - **AU BSB that takes no electronic payments:** accepted and flagged.
  - **Register found:** the form shows the bank and branch back as the claimant types, so they can see a wrong BSB or bank code before submitting.
- *Sources:*
  - NZ check digits: Inland Revenue, Payroll Calculations and Business Rules Specification, section 7. Algorithms A, B, D and F are built. E and G apply only to bank codes the Payments NZ register doesn't list, so those numbers are flagged, not checked. The suffix (account type) is outside every check.
  - NZ banks and branches: Payments NZ Bank Branch Register.
  - AU: AusPayNet BSB directory (updated on the first NSW business day of each month). Australian account numbers have no published check digit, so only the BSB is checked.
- *How it's held:* the registers sit in `Hub_Bank_Branch__c`, loaded monthly by `scripts/load-bank-register.mjs`. With no register loaded, only format and check digit are tested and nothing is flagged for being missing. The health check reports the row counts.
- *Evidence:* the check accepted all 99 published NZ account numbers in python-stdnum's test set, and caught every single wrong digit and every swap of neighbouring digits in their branch and account numbers (8,901 and 699 variants). Run on 31 Oct 2026; the numbers are not stored in this repository.
- *Not done:* checking that the account name matches the account. Confirmation of Payee does this (live in NZ banking apps since the 2024-25 rollout, in Australia since July 2025), but in online banking only. We found no evidence it covers batch payment files. Next step is to ask Trevor's paying bank (roadmap).
- *Revisit if* a bank turns up in the register without a check algorithm we've built, or flagged claims show the register is often out of date.

## Known follow-ups

- Split `ClaimHubService.lodge`, `ClaimHubTerms.build` and `ClaimHubNotifier.render` into smaller methods. Code Analyzer flags their complexity. They are fully tested, so the refactor is safe to do.
- Move email templates out of Apex into Salesforce email templates or custom metadata, so staff can edit wording.
- Instant-win and prize-draw mechanics: designed but not built (winning moments drawn and sealed in advance, awarded under a row lock).
- k6 load test script.
- Build the S3 adapter in `web/lib/files.js` (bucket in ap-southeast-2: public access blocked, encrypted, versioned, lifecycle rule for retention; Vercel OIDC role scoped to the bucket).
- Automated invoice file retention (an S3 lifecycle rule once on S3).
- A nightly reconcile job: Blob files no receipt points to (left behind when Salesforce timed out), and receipts whose file is missing.
- Claim link to httpOnly cookie, so the code leaves the address bar and hosting logs.
