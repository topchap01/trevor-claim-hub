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
- **Addresses (Mark, 31 Oct 2026). Replaced by #16 on 1 Nov 2026.** ~~Each campaign is served on its own domain, as now (for example aegcashbackpromo.co.nz), which the builder adds to Vercel. It also gets a backup address on yourpromotion.com.au as soon as it is built, for testing, client sign-off and late DNS.~~ Still true: claim links carry the claim code and campaign, so reusing an address for a brand's next campaign does not break earlier claims.
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

**12. Returning claimants: make the way back obvious, and remember the claim on the phone.** Decided by Mark, 31 October 2026: whatever is easiest for the least confident claimant.
- *The problem:* the claim link in the email is the only way into a claim. People lose the email, come back to the promotion page and either fill in the form again or give up.
- *What the hub does:*
  - **Welcome back.** Making or opening a claim stores its link code in a cookie on that phone, one per promotion (`hub_claim_<slug>`: HttpOnly, Secure, SameSite=Lax, 180 days). The promotion page then opens with "Welcome back, Sam", one line on where the claim is up to, and an "Open my claim" button. A link that has been replaced by a newer one is ignored, so the bar simply doesn't show.
  - **No dead end on the form.** If someone claims again with the same email, lodge refuses with `code: "duplicate_email"` and the form shows "You already have a claim with sam@example.com" and one button that emails the link. No retyping.
  - **"Already claimed? Open your claim"** at the top of the claim form, jumping to the resend box. Designed pages get the resend box even if their design leaves it out.
  - **After sending a link:** the message says it can take a few minutes, to check junk or spam, gives the support address, and says only the newest link works.
  - **Same mobile, different email:** a second claim on a promotion from the same mobile (matched on the last 8 digits, so any format) is flagged for review, not refused. It is usually a mistyped email on the first claim. This follows #7.
- *Accepted risk:* on a shared phone, someone else in the household can open the claim from the bar. The bar names the claimant ("Not Sam? Make a new claim below"), the bank details are masked to the last 3 digits, and changing them needs a code emailed to the claimant. The same exposure already exists through the phone's browser history, which holds the claim link.
- *Revisit if* a client objects to the shared-phone exposure, or when the claim link moves fully into the cookie (roadmap phase 3).

**13. Electrolux claims collect the full postal address and mobile, plus everything the current Electrolux build collects.** *(Mark, 31 Oct 2026)*
- *Why (Mark):* future marketing.
- *What "the current build collects" means,* measured read-only in production on 31 Oct 2026. Like with like: the two one-off Electrolux cashbacks of 2026, not the always-on Better Living GWP.

  | Field | AU Cross Category 2026 (1,708 claims) | NZ Kitchen 2026 (259 claims) | Hub today |
  |---|---|---|---|
  | Name, email, mobile | all | all | yes |
  | Suburb | all | all | no |
  | Postcode | all | none | no |
  | State or region | all | all | no |
  | Street, street number, unit | none | none | no |
  | Store, from the retailer list | 2,175 of 2,176 receipts | 390 of 390 | no (free text only) |
  | Store suburb | 2,175 of 2,176 | 390 of 390 | no |
  | Store state | 2,175 of 2,176 | none | no |
  | Invoice date | all receipts | all receipts | yes |
  | Model, price per appliance | 4,518 and 4,523 of 4,523 | all 675 | yes |
  | PNC and serial | 3,303 and 3,306 of 4,523 | 621 of 675 | optional |
  | Terms tick | all | all | yes |
  | Electrolux data consent tick | ticked on none | ticked on none | no |

- *So the hub adds,* on Electrolux campaigns: unit, street number, street, suburb, postcode and state or region; the store picked from the retailer list, with its suburb and (AU) state. Street address is new: the current forms have not collected it.
- *Where it goes:* the fields the C4C feed (`BambooElectroluxPromotionClaimService`) already reads, so Electrolux receives it without changes to that class: `Consumer_Unit_No__c`, `Consumer_Street_Number__c`, `Consumer_Street_Stamp__c`, `Consumer_Suburb__c`, `Consumer_PostalCode_Stamp__c`, `Consumer_State_Stamp__c` on the Entry; `Retailer__c`, `Retailer_Suburb__c`, `Retailer_State__c` on the receipt. On NZ claims the mobile also goes to `Consumer_Contact_Number__c`, as the old forms do. State and region values must match `State_Mapping__mdt` (for example `NSW`, `Auckland`), or C4C receives no state or country.
- *Marketing needs consent, which the current build does not capture.* `By_continuing_you_agree_to_Electrolux_s__c` was unticked on all 4,125 Electrolux claims in the last 180 days, so C4C has been sending `dataProtectionConsent: N` on every claim. Collecting an address does not by itself allow it to be used for marketing. The opt-in wording and who it names (Electrolux, Trevor or both) stay with Mark (production-checklist.md, *Consent wording*).
- *Not decided here:* gender and age; whether PNC is compulsory; when hub claims are sent to C4C. All three stay open in roadmap.md.
- *Revisit if* Electrolux takes C4C data by API (decisions.md #1a) and its own schema asks for something else.

**16. entryform.claims is the hub's own domain. Every campaign lives at `brand.entryform.claims/campaign`.** *(Mark, 1 Nov 2026. Replaces the addresses part of #10.)*
- *What Mark decided:*
  - entryform.claims (bought 1 Nov 2026, registered and run on Trevor's Vercel team) is the main address for every campaign. All claim links in emails use it. It replaces yourpromotion.com.au as the backup address.
  - The address is the brand's subdomain plus the campaign: `aeg.entryform.claims/nz-cashback`. A brand keeps its subdomain from campaign to campaign.
  - A campaign's own domain (such as aegcashbackpromo.co.nz) is optional, for the pack and the ads, and points at the hub.
  - The sandbox runs at `test.entryform.claims`, with brands under it: `aeg.test.entryform.claims/nz-cashback`. The bare domain and brand subdomains of entryform.claims are kept for the production project.
- *Why:*
  - one domain Trevor owns: no DNS to arrange per campaign, no waiting on a client's IT, and a campaign is reachable the moment it is built (the one-hour goal in roadmap.md);
  - one wildcard certificate and one place to set security and search rules, instead of one per campaign;
  - the brand subdomain keeps each client's pages and cookies apart, which the client self-serve plan needs;
  - the name says what the page is for, which helps claimants trust the link in an email.
- *How it works:*
  - The Salesforce slug is `brand-campaign` (`aeg-nz-cashback`). The web app reads the brand from the host and rebuilds the slug, so no data changes shape. A brand's subdomain only ever serves that brand's campaigns, pages and design files; anything else is not found.
  - The full slug on its own brand (`aeg.entryform.claims/aeg-nz-cashback`) redirects to the short address. Every other host (the bare domain, the `*.vercel.app` addresses, a campaign's own domain) keeps the plain `/slug` addresses, so nothing that worked before stops working.
  - The web app's `HUB_ROOT_DOMAIN` and Salesforce's `Claim_Hub_Settings__c.Hub_Root_Domain__c` hold the root (`test.entryform.claims` in the sandbox, `entryform.claims` in production). The builder asks for the brand and sets the campaign's base URL from them.
- *Not decided here:* what the bare domain `entryform.claims` shows (nothing, as now, or a short Trevor page); the email sending domain; whether old campaign domains redirect to the hub or serve the pages themselves.
- *Revisit if* a client insists its campaign must show only its own domain in the address bar.

## Known follow-ups

- Split `ClaimHubService.lodge`, `ClaimHubTerms.build` and `ClaimHubNotifier.render` into smaller methods. Code Analyzer flags their complexity. They are fully tested, so the refactor is safe to do.
- Move email templates out of Apex into Salesforce email templates or custom metadata, so staff can edit wording.
- Instant-win and prize-draw mechanics: designed but not built (winning moments drawn and sealed in advance, awarded under a row lock).
- k6 load test script.
- Build the S3 adapter in `web/lib/files.js` (bucket in ap-southeast-2: public access blocked, encrypted, versioned, lifecycle rule for retention; Vercel OIDC role scoped to the bucket).
- Automated invoice file retention (an S3 lifecycle rule once on S3).
- A nightly reconcile job: Blob files no receipt points to (left behind when Salesforce timed out), and receipts whose file is missing.
- Claim link to httpOnly cookie, so the code leaves the address bar and hosting logs. The cookie now exists (#12); what's left is the claim page reading it instead of `?token=`.
