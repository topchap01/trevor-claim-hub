# Security model

## Who can do what

| Actor | How they authenticate | What they can reach |
|---|---|---|
| Claimant | The 256-bit random link code in their emailed link (`Entry__c.Access_Token__c`). | Their own claim only. Codes are never derived from record Ids. `ClaimAccessToken.resolve` needs an exact, case-sensitive match of 40 to 64 characters. |
| Claimant changing bank details | The link code plus a 6-digit code emailed to them. | Codes are stored as SHA-256 hashes, expire after 10 minutes, are single use, allow 5 attempts each, and at most 10 are issued per claim per day. Every change emails the claimant, so the real owner hears about a change they didn't make. |
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
| Many claims from one connection | The IP address is hashed with the org Id and stored. The third claim in 24 hours is flagged. Above the daily limit (default 20) claims are refused. |
| Claim link enumeration | 256-bit codes. Unknown and expired links look the same. |
| Email enumeration | The link resend gives the same answer whether or not a claim exists, and sends at most 3 links a claim a day. |
| AI cost abuse | Per-claim daily limits on chat (40), invoice uploads (10) and plate scans (30). Prompts are capped at 12 messages of 600 characters. `max_tokens` is capped. |
| Large uploads | Photos are resized on the phone. The web app rejects bodies over 3 MB, Apex rejects base64 over 2.1 MB, and only JPEG, PNG, WebP, HEIC and PDF are accepted. |
| Prompt injection in chat | The assistant has no tools and can't change anything. It is told never to ask for or repeat bank details or codes. It answers only from the terms summary and the claimant's own claim. |
| Fake invoice | **Not solved.** Claude checks the retailer, name, date, models, prices and balance owing, but a convincing forgery passes. Mitigations are the duplicate-invoice flag, human approval, and (planned) retailer verification for high-value claims. |

**Still to do:** a Vercel WAF rate limit on `POST /api/*`. The firewall API isn't available on the current Vercel plan. Configure it on the production (Pro) team: 30 a minute per IP is a sensible start.

## Personal data

- **Stored in Salesforce, as the old forms already do:**
  - the claimant's name, email and mobile;
  - bank details;
  - what they bought.
- **Invoice photos** are in a **private** Vercel Blob store (`trevor-claim-hub-invoices`, Sydney region).
  - The path holds a hash of the claim link, never the link or a name.
  - Staff open a file through a 10-minute ticket. Salesforce issues it, keeping only its hash, and logs who opened it as an `Internal:` claim event.
  - **Retention is not yet automated.** Decide a period, for example 12 months after payment, and add a scheduled delete.
- **Logs:**
  - Claim link codes are redacted from web app logs.
  - Security codes are never stored or emailed in readable form: the outbox keeps `[code not stored]`.
  - API errors return only a Nebula Logger reference.
- **The health route** returns counts only.

## Secrets

| Secret | Where | Rotation |
|---|---|---|
| Integration user private key | Vercel env `SF_PRIVATE_KEY` (sensitive). The matching certificate is on the External Client App. | **The sandbox key must be replaced before anyone else is given access.** It has been exposed in an AI working session. Generate a new pair, upload the certificate to the ECA, update the env var. See the runbook. Production gets its own pair. |
| Blob read-write token | Vercel env `BLOB_READ_WRITE_TOKEN`, created by Vercel when the store was connected. | Regenerate in Vercel → Storage. |
| Anthropic API key | `Claude_Setting__mdt.Default` (existing, shared with the old invoice OCR). | **Recommended:** move it to a Named Credential with an External Credential, so Apex never handles the key. |

There are no secrets in this repository. `.gitignore` excludes `.env*`, `*.key` and `*.pem`.

## Headers

The web app sends:
- a Content-Security-Policy (`default-src 'self'`, no framing, no third-party scripts);
- HSTS (two years);
- `Referrer-Policy: no-referrer`, so claim links don't leak through referrers;
- `X-Content-Type-Options`;
- `X-Frame-Options: DENY`;
- a Permissions-Policy allowing the camera only;
- `noindex`.
