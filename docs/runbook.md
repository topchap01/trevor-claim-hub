# Runbook

## Knowing it works

| Signal | Where | Healthy |
|---|---|---|
| Uptime | `GET https://<hub>/api/health`. Point an uptime monitor (Better Stack, UptimeRobot or Checkly) at it every minute and alert after 2 failures. | 200 with `"ok": true` |
| Hourly self-check | `ClaimHubMonitor` emails `Claim_Hub_Settings__c.Alert_Email__c`. | No email |
| Errors | Nebula Logger → *Logs* tab. Hub API errors carry the `ref` the claimant was shown. | No new ERROR entries |
| Work queue | Claim Hub app → console → *Needs a person*. | Cleared daily |
| Daily smoke test (recommended) | `node scripts/smoke-test.mjs <hub> <slug>` against a test campaign, from CI on a schedule. | All PASS |

The health route reports these counts:
- `emailsOverdue`: queued more than 30 minutes ago;
- `emailsFailedLastHour`;
- `invoicesRead24h` and `invoicesNotRead24h`;
- `claims24h`;
- `flaggedForReview24h`;
- `bankRegisterRows`: rows per country in the bank registers. 0 means bank details are checked by format and check digit only (Salesforce API response; the web route returns counts of problems only).

## Common situations

**Health shows emails overdue.**
1. Check *Setup → Apex Jobs* for a failed `ClaimHubDispatchJob`.
2. Check *Setup → Deliverability*. A refreshed sandbox resets this to "System email only".
3. Check the org-wide email address for the campaign's sender is verified.
4. The hourly monitor resends anything queued. To send now, run `ClaimHubNotifier.dispatchDue();` in Anonymous Apex.

**Emails failed.** Open the `Claim_Notification__c` record. `Last_Error__c` holds Salesforce's reason. Fix the cause, set `Status__c` back to `Queued`, and the next sweep sends it.

**Invoices "Not read".**
- Claude is down, or the API key is wrong.
- Claims still go through: each one lands in the console queue for a person to check.
- Check Nebula Logger for `Claude returned …` warnings, and status.anthropic.com.

**Claimant says their link doesn't work.** Ask them to use *Email me my link* on the promotion page. It sends a fresh link (at most 3 a day). Links never expire on their own.

**Claimant wants to change bank details while a payment is being made.**
- The hub refuses this. The org's `Cant_update_bank_details_after_EFT` rule allows changes only while EFT status is Pending.
- If the payment fails, the claimant is emailed and can change the details. The hub resets the status to Pending, saves the details, then sets *EFT Updated* for the payments team.

**Bank details not confirmed (flagged).** The registers don't list the claimant's bank and branch or BSB, or the BSB takes no electronic payments. The claim was accepted. Check the details against the claimant's invoice or ask them; a brand-new branch can be missing until the next monthly load. A wrong NZ number never gets this far: the form refuses it.

**Claimant says the form refuses their NZ account number.** The number failed its bank's check digit, so a digit is wrong or two are swapped. Ask them to copy it from their banking app. If they're sure, send the number (not the name) to the developer: it means a bank has changed its numbering and `ClaimHubBank` needs updating.

**Duplicate or second-quality serial flagged.** Shown in the console with the other claim's number. Decide, then approve or reject the claim with a reason.

**The web app can't reach Salesforce.**
1. Check `/api/health` and the Vercel runtime logs.
2. Common causes: the integration user is frozen, its password policy expired the user, the certificate expired (the sandbox cert runs to Oct 2028), or the ECA policy changed.

## Routine tasks

**Load a campaign.**
1. Open Claim Hub → *Campaign from Terms*.
2. Paste the terms or attach the PDF.
3. Check what was read and every issue raised.
4. Set the dates and web address name. Optionally compare products with a past campaign.
   - *Ask for the claimant's postal address* and *Ask which store they bought from* are on for Electrolux and AEG terms (decisions.md #13). Check the list of stores to offer: spell each one as reports should show it (for example `Harvey Norman`, `The Good Guys`). Other is added for you.
   - These can also be changed later on the campaign record: *Claim Hub Collect Address*, *Claim Hub Collect Store*, *Claim Hub Stores*.
5. Create the campaign. Open the claim page and run one test claim.

**Refresh the bank registers** monthly, after AusPayNet's update on the first NSW business day, and after a sandbox refresh:
1. Download:
   - the Payments NZ Bank Branch Register, as CSV, from paymentsnz.co.nz (Resources, Industry registers, Bank Branch Register);
   - the AusPayNet BSB directory, full version, as CSV, from auspaynet.com.au/BSBLinks;
   - optionally, AusPayNet's *Key to Abbreviations* CSV from the same page. Without it the form shows the bank's short code (CBA) instead of its name.
2. Replace the files in `data/bank-registers/` (names in that folder's README) on a branch, open a pull request and merge it.
3. The merge runs the **Load bank registers (Wizard)** GitHub job. It checks the files, signs in to Wizard, upserts every row, deletes rows the registers no longer list, then checks Salesforce holds exactly the rows in the files. The row counts appear on the job's summary page. To reload without new files (after a sandbox refresh), run the job by hand from the Actions tab.
4. The job stops without changing anything if a file has suspiciously few rows. It loads Wizard only; production needs Mark's approval and `--approved-for-production` (production-checklist.md).

**Query or run Apex in Wizard from a chat.** Chats have no Salesforce login. `node scripts/wizard.mjs query|tooling-query|apex|describe ...` starts the **Wizard console** GitHub job, which signs in with the `SF_SANDBOX_*` secrets, checks the org is a sandbox, runs the request and returns the result. Each call takes 1 to 2 minutes. How chats use it, and the rules: `.claude/skills/wizard/SKILL.md`. People can run the same job from the Actions tab.

**Schedule background jobs** after a deploy or sandbox refresh:

```bash
sf apex run -o <org> -f scripts/apex/schedule-jobs.apex
```

**Settings.** *Setup → Custom Settings → Claim Hub Settings → Manage*, org default. Every field has a safe default, so a blank setting still works. In production, set:
- `Alert_Email__c`;
- `File_Base_URL__c` (the production hub address);
- `Debounce_Minutes__c` = 10.

**Rotate the integration user's key.**

```bash
openssl req -x509 -newkey rsa:2048 -nodes -days 730 -subj "/CN=trevor-claim-hub" -keyout hub.key -out hub.crt
```

1. Upload `hub.crt` to the External Client App: *Setup → External Client App Manager → Trevor Claim Hub → OAuth settings*.
2. Set `SF_PRIVATE_KEY` in Vercel to the contents of `hub.key`, as a sensitive variable.
3. Redeploy and check `/api/health`.
4. Delete `hub.key` from your machine.

**Invoice storage on S3** (decisions.md #6). The bucket is `trevor-claim-hub` in `ap-southeast-2`. The web app holds no AWS keys: Vercel gives each function a signed OIDC token, and AWS swaps it for one-hour credentials for a role that trusts only the named Vercel project and environments. Done once per environment, in the AWS console as an administrator.

Values:
- Vercel team slug `mark-alexanders-projects-58606fac`;
- sandbox project `trevor-claim-hub-test`; production project not yet created;
- AWS account **Future Unicorn, `838547582670`**, which holds the bucket. Every step below is done signed in to that account. A role in any other account (the organisation's management account, for one) signs in but S3 refuses every save.

1. **Bucket settings** (*S3 → trevor-claim-hub*). Check, or set:
   - *Block all public access*: on.
   - *Object Ownership*: bucket owner enforced (ACLs off).
   - *Default encryption*: SSE-S3 (on by default for new buckets).
   - *Bucket Versioning*: on, so an overwrite or delete can be undone.
   - No CORS rule. Files go through the web app, never straight from the phone.
   - Bucket policy refusing anything not over HTTPS:
     ```json
     {"Version":"2012-10-17","Statement":[{"Sid":"HttpsOnly","Effect":"Deny","Principal":"*","Action":"s3:*",
       "Resource":["arn:aws:s3:::trevor-claim-hub","arn:aws:s3:::trevor-claim-hub/*"],
       "Condition":{"Bool":{"aws:SecureTransport":"false"}}}]}
     ```
   - *Lifecycle rule* `sandbox-expiry`: prefix `sandbox/`, expire current versions after 30 days, delete noncurrent versions after 1 day. Made-up test files only; nothing real is kept under `sandbox/`.
   - The production rule on `invoices/` waits for the retention decision (production-checklist.md).
2. **Vercel as an identity provider** (*IAM → Identity providers → Add provider → OpenID Connect*), once for the AWS account:
   - Provider URL: `https://oidc.vercel.com/mark-alexanders-projects-58606fac`
   - Audience: `https://vercel.com/mark-alexanders-projects-58606fac`
3. **Sandbox role** (*IAM → Roles → Create role → Custom trust policy*), named `trevor-claim-hub-sandbox`. Done 1 Nov 2026.
   - Trust policy (only the sandbox project's preview and production deployments; never local development):
     ```json
     {"Version":"2012-10-17","Statement":[{"Effect":"Allow",
       "Principal":{"Federated":"arn:aws:iam::838547582670:oidc-provider/oidc.vercel.com/mark-alexanders-projects-58606fac"},
       "Action":"sts:AssumeRoleWithWebIdentity",
       "Condition":{"StringEquals":{
         "oidc.vercel.com/mark-alexanders-projects-58606fac:aud":"https://vercel.com/mark-alexanders-projects-58606fac",
         "oidc.vercel.com/mark-alexanders-projects-58606fac:sub":[
           "owner:mark-alexanders-projects-58606fac:project:trevor-claim-hub-test:environment:preview",
           "owner:mark-alexanders-projects-58606fac:project:trevor-claim-hub-test:environment:production"]}}}]}
     ```
   - Permissions, as an inline policy `invoice-files` (put, open and delete under `sandbox/invoices/` only; no listing):
     ```json
     {"Version":"2012-10-17","Statement":[{"Effect":"Allow",
       "Action":["s3:PutObject","s3:GetObject","s3:DeleteObject"],
       "Resource":"arn:aws:s3:::trevor-claim-hub/sandbox/invoices/*"}]}
     ```
   - The production role, `trevor-claim-hub-production`, is the same with the production project's name and `environment:production` only in the trust policy, and `arn:aws:s3:::trevor-claim-hub/invoices/*` in the permissions.
4. **Vercel** (*project → Settings → Security → Secure backend access with OIDC federation*): enabled, issuer mode *Team*.
5. **Environment variables** on the project, for Production and Preview: `S3_BUCKET_NAME=trevor-claim-hub`, `S3_REGION=ap-southeast-2`, `AWS_ROLE_ARN=arn:aws:iam::838547582670:role/trevor-claim-hub-sandbox`, `S3_KEY_PREFIX=sandbox/`. None is a secret. Keep `BLOB_READ_WRITE_TOKEN` in the sandbox, so invoices uploaded before the switch still open.
6. **Redeploy and check:**
   - `node scripts/smoke-test.mjs https://<brand>.test.entryform.claims <slug>` on each demo campaign. The invoice step must pass.
   - In Wizard, open that claim's invoice from the receipt. It should show, and its *Hub File Key* should end in a long id like `3f2a…-….jpg`.
   - In S3, the file is under `sandbox/invoices/`.
   - If invoice uploads now fail with "We couldn't save your invoice", the Vercel runtime log names the AWS error. `AccessDenied` on `AssumeRoleWithWebIdentity` means the trust policy's names don't match; on `PutObject`, the permissions policy or the prefix.
   - To switch back, set `AWS_ROLE_ARN`'s environments to Development only (keeps the value) and redeploy. Uploads return to Blob; files already in S3 still need the role to open.

## Deploying

- **Salesforce:**
  1. `sf project deploy start -d salesforce/force-app --test-level RunSpecifiedTests` with every `*Test` class. CI does this.
  - **To Wizard without a CLI sign-in:** push the commit to the `deploy/wizard` branch (`git push origin HEAD:deploy/wizard --force`), or run *Deploy to Wizard* from the Actions tab. The job signs in with the CI sandbox secrets, stops if the org is not a sandbox, deploys with the hub tests, runs `scripts/apex/wizard-setup.apex` (demo campaign settings) and smoke-tests the three demo campaigns on the sandbox address. Deploy and smoke results appear on the check.
  2. Deploy `salesforce/legacy-patches` separately, with the legacy test classes.
- **Web:** pushing to `main` deploys to production through Vercel's Git integration. Pull requests get preview deployments.
- **Rollback:**
  - Web: Vercel → Deployments → *Promote* the previous deployment.
  - Salesforce: redeploy the previous commit.
  - Hub field additions are additive, so rolling back code never needs data changes.
