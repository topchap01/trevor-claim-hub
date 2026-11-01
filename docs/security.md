# Security model

## Who can do what

| Actor | How they authenticate | What they can reach |
|---|---|---|
| Claimant | The 256-bit random link code in their emailed link (`Entry__c.Access_Token__c`). | Their own claim only. Codes are never derived from record Ids. `ClaimAccessToken.resolve` needs an exact, case-sensitive match of 40 to 64 characters. |
| Claimant changing bank details | The link code plus a 6-digit code emailed to them. | Codes are stored as SHA-256 hashes, expire after 10 minutes, are single use, allow 5 attempts each, and at most 10 are issued per claim per day. Every change emails the claimant, so the real owner hears about a change they didn't make. A wrong guess is counted *after* the API rolls the request back (`ClaimHubApi.countFailedCode`), so the limit holds. `ClaimHubApiTest` checks this through the API. |
| Web app | OAuth 2.0 JWT bearer as `claimhub.integration@…`. Certificate only, no client secret. | The *Minimum Access – API Only Integrations* profile plus the `Claim_Hub_Integration` permission set, which grants API access, `ClaimHubApi` class access and the three Claim Hub record types. Nothing else. |
| Trevor staff | Salesforce login. | The `Claim_Hub_Admin` permission set grants the app, tabs, console and builder classes, and hub field access. The console runs in user mode. |
| Developers | Salesforce login to the sandbox. | System Administrator in the sandbox only. |

## Why the API runs in system mode

`ClaimHubApi` and the classes behind it are `without sharing` and skip object and field checks. This is deliberate.
- The integration user's profile grants no object access at all.
- What it may do is defined entirely by the code path `ClaimHubApi` exposes.
- Granting the integration user broad object permissions so user-mode checks would pass would widen what a stolen token could do through the standard REST API.
- In this design, a stolen integration token can only call the hub endpoints. Those endpoints only act on a claim when given its link code.

The PMD `ApexCRUDViolation` findings are suppressed on these classes for that reason, with the reason written in each class.

## Abuse controls

| Threat | Control |
|---|---|
| Two claims from one person | A unique key on campaign plus email, enforced by the database. |
| Serial reuse | A serial is checked against every claim, old forms included. `Hub_Serial_Key__c` is unique across hub claims, so two requests at once can't both save it. A duplicate is refused and flagged naming the other claim. |
| Second-quality (T2) stock | Excluded prefixes are refused and flagged. |
| One invoice on several claims | Retailer plus invoice number is indexed. A match is flagged and listed on the invoice check. |
| One bank account on several claims | Flagged for review. |
| Mistyped bank details | NZ numbers that fail their bank's check digit are refused on the form. Banks, branches and BSBs the registers don't list are flagged. The bank lookup route takes only the six bank-and-branch digits, never an account number, and returns public register data. |
| Many claims from one connection | The IP address is hashed with the org Id and stored. The third claim in 24 hours is flagged. Above the daily limit (default 20) claims are refused. |
| Claim link enumeration or a leaked link | 256-bit codes. Unknown and expired links look the same. *Email me my link* issues a new code and the old link stops working. |
| Email enumeration | The link resend gives the same answer whether or not a claim exists, and sends at most 3 links a claim a day. |
| AI cost abuse | Per-claim daily limits on chat (40), invoice uploads (10) and plate scans (30). On the promotion page, before a claim exists, chat is limited to 20 questions per connection per day. Prompts are capped at 12 messages of 600 characters, and `max_tokens` is capped. Promotion details are cached for 60 seconds per server instance, which saves API calls. |
| Large or hostile uploads | Photos are resized on the phone. The web app rejects bodies over 3 MB, Apex rejects base64 over 2.1 MB, and both accept only JPEG, PNG, WebP and PDF. The web app passes on only the fields each action expects, so the browser can't set a storage key. Apex also checks that the key is in that claim's folder. Staff view files under a `sandbox` CSP, so an uploaded file can never run as a page. |
| Terms acceptance | The API refuses a claim unless `acceptedTerms` is true. It is not only a tick box in the browser. |
| Prompt injection in chat | The assistant has no tools and can't change anything. It is told never to ask for or repeat bank details or codes. It answers only from the terms summary and the claimant's own claim. |
| Fake invoice | **Not solved.** Claude checks the retailer, name, date, models, prices and balance owing, but a convincing forgery passes. Mitigations are the duplicate-invoice flag, human approval, and (planned) retailer verification for high-value claims. |

**Still to do:** a Vercel WAF rate limit on `POST /api/*`. The firewall API isn't available on the current Vercel plan. Configure it on the production (Pro) team: 30 a minute per IP is a sensible start.

## Personal data

- **Stored in Salesforce, as the old forms already do:**
  - the claimant's name, email and mobile;
  - bank details;
  - what they bought.
- **Invoice photos** are in the **private** S3 bucket `trevor-claim-hub` (Sydney), production under `invoices/` and the sandbox under `sandbox/invoices/` from 1 Nov 2026, each through its own role (decisions.md #6). Sandbox invoices uploaded before then stay in the private Vercel Blob store `trevor-claim-hub-invoices` (Sydney).
  - The path holds a hash of the claim link, never the link or a name.
  - Staff open a file through a 10-minute ticket. Salesforce issues it, keeping only its hash, and logs who opened it as an `Internal:` claim event.
  - This is the only everyday way in. Nobody on the team has S3 access; AWS access is Mark's alone (decisions.md #17).
  - Each S3 file carries one tag, its campaign slug. No personal data in names or tags.
  - **Retention** is applied by the nightly storage check once `Invoice_Retention_Months__c` is set (decisions.md #17). Not yet set: every file is kept. Files no claim points to are deleted after 7 days.
- **Logs:**
  - Claim link codes are redacted from web app logs.
  - Security codes are never stored or emailed in readable form: the outbox keeps `[code not stored]`.
  - API errors return only a Nebula Logger reference.
- **The health route** returns only ok, whether Salesforce was reachable, the response time and the number of problems. The counts stay in Salesforce.
- **Hosting logs.** Claim links are in URLs (`/c?token=`, `/api/claim/{token}`), so Vercel's request logs contain them. Limit log access to the people who run the hub. A planned change is to exchange the code for an httpOnly cookie on first visit and remove it from the address bar.

## Secrets

| Secret | Where | Rotation |
|---|---|---|
| Integration user private key | Vercel env `SF_PRIVATE_KEY` (sensitive). The matching certificate is on the External Client App. | **The sandbox key must be replaced before anyone else is given access.** It has been exposed in an AI working session. Generate a new pair, upload the certificate to the ECA, update the env var. See the runbook. Production gets its own pair. |
| Blob read-write token | Vercel env `BLOB_READ_WRITE_TOKEN`, created by Vercel when the store was connected. Sandbox only. | Regenerate in Vercel → Storage. |
| Nightly job secret | Vercel env `CRON_SECRET` (sensitive). Vercel Cron sends it; `/api/cron/storage` refuses any request without it. | Replace in Vercel and redeploy. |
| AWS access to the invoice bucket | **None stored.** Each function exchanges Vercel's OIDC token for one-hour AWS credentials for a role that trusts only the named project and environments. `AWS_ROLE_ARN` is not a secret. | Nothing to rotate. To cut access, edit the role's trust policy. |
| Anthropic API key | `Claude_Setting__mdt.Default` (existing, shared with the old invoice OCR). | **Recommended:** move it to a Named Credential with an External Credential, so Apex never handles the key. |

There are no secrets in this repository. `.gitignore` excludes `.env*`, `*.key` and `*.pem`.

## Headers

The web app sends:
- a Content-Security-Policy (`default-src 'self'`, no framing, no third-party scripts);
  - Inline scripts are allowed because Next.js inlines its bootstrap. A nonce-based CSP via middleware is a follow-up.
- HSTS (two years);
- `Referrer-Policy: no-referrer`, so claim links don't leak through referrers;
- `X-Content-Type-Options`;
- `X-Frame-Options: DENY`;
- a Permissions-Policy allowing the camera only;
- `noindex`.
