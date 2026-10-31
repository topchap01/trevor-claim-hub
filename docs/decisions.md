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

**10. Returning claimants: make the way back obvious, and remember the claim on the phone.** Decided by Mark, 31 October 2026: whatever is easiest for the least confident claimant.
- *The problem:* the claim link in the email is the only way into a claim. People lose the email, come back to the promotion page and either fill in the form again or give up.
- *What the hub does:*
  - **Welcome back.** Making or opening a claim stores its link code in a cookie on that phone, one per promotion (`hub_claim_<slug>`: HttpOnly, Secure, SameSite=Lax, 180 days). The promotion page then opens with "Welcome back, Sam", one line on where the claim is up to, and an "Open my claim" button. A link that has been replaced by a newer one is ignored, so the bar simply doesn't show.
  - **No dead end on the form.** If someone claims again with the same email, lodge refuses with `code: "duplicate_email"` and the form shows "You already have a claim with sam@example.com" and one button that emails the link. No retyping.
  - **"Already claimed? Open your claim"** at the top of the claim form, jumping to the resend box. Designed pages get the resend box even if their design leaves it out.
  - **After sending a link:** the message says it can take a few minutes, to check junk or spam, gives the support address, and says only the newest link works.
  - **Same mobile, different email:** a second claim on a promotion from the same mobile (matched on the last 8 digits, so any format) is flagged for review, not refused. It is usually a mistyped email on the first claim. This follows #7.
- *Accepted risk:* on a shared phone, someone else in the household can open the claim from the bar. The bar names the claimant ("Not Sam? Make a new claim below"), the bank details are masked to the last 3 digits, and changing them needs a code emailed to the claimant. The same exposure already exists through the phone's browser history, which holds the claim link.
- *Revisit if* a client objects to the shared-phone exposure, or when the claim link moves fully into the cookie (roadmap phase 3).

## Known follow-ups

- Split `ClaimHubService.lodge`, `ClaimHubTerms.build` and `ClaimHubNotifier.render` into smaller methods. Code Analyzer flags their complexity. They are fully tested, so the refactor is safe to do.
- Move email templates out of Apex into Salesforce email templates or custom metadata, so staff can edit wording.
- Instant-win and prize-draw mechanics: designed but not built (winning moments drawn and sealed in advance, awarded under a row lock).
- k6 load test script.
- Build the S3 adapter in `web/lib/files.js` (bucket in ap-southeast-2: public access blocked, encrypted, versioned, lifecycle rule for retention; Vercel OIDC role scoped to the bucket).
- Automated invoice file retention (an S3 lifecycle rule once on S3).
- A nightly reconcile job: Blob files no receipt points to (left behind when Salesforce timed out), and receipts whose file is missing.
- Claim link to httpOnly cookie, so the code leaves the address bar and hosting logs. The cookie now exists (#10); what's left is the claim page reading it instead of `?token=`.
