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
5. Create the campaign. Open the claim page and run one test claim.

**Refresh the bank registers** monthly, after AusPayNet's update on the first NSW business day, and after a sandbox refresh:
1. Download:
   - the Payments NZ Bank Branch Register, as CSV, from paymentsnz.co.nz (Resources, Industry registers, Bank Branch Register);
   - the AusPayNet BSB directory, full version, as CSV, from auspaynet.com.au/BSBLinks;
   - optionally, AusPayNet's *Key to Abbreviations* CSV from the same page. Without it the form shows the bank's short code (CBA) instead of its name.
2. Replace the files in `data/bank-registers/` (names in that folder's README) on a branch, open a pull request and merge it.
3. The merge runs the **Load bank registers (Wizard)** GitHub job. It checks the files, signs in to Wizard, upserts every row, deletes rows the registers no longer list, then checks Salesforce holds exactly the rows in the files. The row counts appear on the job's summary page. To reload without new files (after a sandbox refresh), run the job by hand from the Actions tab.
4. The job stops without changing anything if a file has suspiciously few rows. It loads Wizard only; production needs Mark's approval and `--approved-for-production` (production-checklist.md).

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

## Deploying

- **Salesforce:**
  1. `sf project deploy start -d salesforce/force-app --test-level RunSpecifiedTests` with every `*Test` class. CI does this.
  2. Deploy `salesforce/legacy-patches` separately, with the legacy test classes.
- **Web:** pushing to `main` deploys to production through Vercel's Git integration. Pull requests get preview deployments.
- **Rollback:**
  - Web: Vercel → Deployments → *Promote* the previous deployment.
  - Salesforce: redeploy the previous commit.
  - Hub field additions are additive, so rolling back code never needs data changes.
