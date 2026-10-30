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

**2. Vercel for the web app.**
- *Why:*
  - Next.js hosting with no servers to run.
  - Sydney region.
  - Preview deployments per pull request.
  - Private Blob storage alongside.
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

**6. Invoice files in private Vercel Blob storage.** Production Salesforce file storage is over its limit. Staff open files through short-lived tickets issued by Salesforce.

**7. Flag, don't refuse, where a person should judge.** Shared bank accounts, the same invoice twice and several claims from one connection all have innocent explanations (households, shared office networks), so they go to the review queue. Certain cases are refused outright:
- a duplicate email on the same promotion;
- a serial already used;
- an excluded serial prefix;
- the minimum spend not met.

**8. Bank changes need an emailed code.** SMS would be stronger against a compromised mailbox, but needs an SMS provider. *Revisit for* high-value campaigns.

**9. Emails go through an outbox object.** Every email is a record before it is sent, so nothing is lost when sending fails, staff can see what each claimant received, and changes made close together are merged into one email.

## Known follow-ups

- Split `ClaimHubService.lodge`, `ClaimHubTerms.build` and `ClaimHubNotifier.render` into smaller methods. Code Analyzer flags their complexity. They are fully tested, so the refactor is safe to do.
- Move email templates out of Apex into Salesforce email templates or custom metadata, so staff can edit wording.
- Instant-win and prize-draw mechanics: designed but not built (winning moments drawn and sealed in advance, awarded under a row lock).
- k6 load test script.
- Automated invoice file retention.
