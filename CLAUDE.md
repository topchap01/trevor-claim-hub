# Working on the Trevor Claim Hub

Read this first. It is the standing brief for anyone (person or AI) picking up this project. The product and technical detail are in README.md and docs/. Where we're going is in docs/roadmap.md.

## What this is

Trevor Services' claim hub has three parts:
- one set of mobile claim pages for every cashback promotion (`web/`, Next.js on Vercel);
- an engine in the Trevor Salesforce org (`salesforce/`);
- a builder that turns a promotion's terms and conditions into a running campaign.

Owner: Mark Alexander (Bamboo Marketing / Trevor Services).

## Environments

| Thing | Where |
|---|---|
| Salesforce sandbox | Wizard (`trevor-services--wizard.sandbox.my.salesforce.com`), CLI alias `wizard`. Set `SFDX_DISABLE_DNS_CHECK=true` before CLI commands. **Chats have no Wizard login: they query, run Apex and deploy through GitHub jobs. Read `.claude/skills/wizard/SKILL.md` first.** |
| Salesforce production | `trevor-services.my.salesforce.com` (AUS68). **Read-only.** Nothing is deployed or changed there without Mark's explicit approval. |
| Web app (sandbox) | Vercel project `trevor-claim-hub-test` (team `team_0oBBLrjzMK25pmA9AR8j4MNs`), root directory `web`, region syd1. Campaigns at `brand.test.entryform.claims/campaign` (decisions.md #16); `trevor-claim-hub-test.vercel.app/<slug>` still works. Vercel SSO covers preview and per-deployment addresses only: the production addresses are open to anyone (checked 31 Oct 2026). Every push to `main` deploys it. |
| Hub domain | `entryform.claims`, bought 1 Nov 2026 on Trevor's Vercel team, DNS run by Vercel. Production gets `entryform.claims` and `*.entryform.claims`; the sandbox has `test.entryform.claims` and `*.test.entryform.claims`. |
| Invoice files | S3 bucket `trevor-claim-hub`, ap-southeast-2, AWS account Future Unicorn (838547582670), signed in through Vercel OIDC, no stored keys. Sandbox under `sandbox/` (role `trevor-claim-hub-sandbox`, live 1 Nov 2026); production under `invoices/`. Older sandbox invoices stay in Vercel Blob `trevor-claim-hub-invoices`. decisions.md #6; runbook, *Invoice storage on S3*. |
| Code | github.com/topchap01/trevor-claim-hub (private) |

## Rules that always apply

1. **Production stays read-only** unless Mark approves a specific change.
2. **Test data is made up.** Use `@example.com` claimants and never real customers' details.
3. **Never print or paste credentials.** That means private keys, tokens and API keys. `.env*`, `*.key` and `*.pem` are git-ignored; keep it that way.
4. **Keep Vercel deployment protection on.** Mark decides about access himself.
5. **Before calling work done:**
   - run `scripts/run-apex-tests.sh wizard`;
   - run `npm run lint && npm test && npm run build` in `web/`;
   - for anything touching the claim journey, run `node scripts/smoke-test.mjs <url> <slug>`.
6. **Record decisions** in docs/decisions.md and open items in docs/production-checklist.md. A decision that only lives in a chat is lost.
7. **Writing for Mark and clients:**
   - no em dashes;
   - no filler or AI-voice phrases;
   - plain, direct English;
   - hard numbers with sources;
   - campaign figures compared like with like: one-off against one-off, live against live.

## How work is organised

- Each piece of work is one branch and one pull request, with CI green and a preview deployment checked.
- docs/roadmap.md is the single list of what's next. Update it when something finishes or changes priority.
- Mark makes the business decisions. Those still open are listed at the top of docs/roadmap.md.
