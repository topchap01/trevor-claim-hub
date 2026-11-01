---
name: wizard-sandbox
description: Use whenever a Trevor Claim Hub task needs the Wizard Salesforce sandbox (query records, run Apex, list an object's fields, deploy) from a chat with no Salesforce login of its own.
---

# Using the Wizard sandbox from a chat

Chats have no Salesforce login. They reach Wizard through GitHub jobs that sign in with the sandbox secrets kept in the repository (`SF_SANDBOX_*`). The chat starts a job and reads back what it returns. Nobody pastes, sees or needs a password or key.

| Need | How |
|---|---|
| Read records, count things, check data | `node scripts/wizard.mjs query "<SOQL>"` |
| Read metadata (Apex classes, flows, validation rules) | `node scripts/wizard.mjs tooling-query "<SOQL>"` |
| See an object's fields, types and record types | `node scripts/wizard.mjs describe Entry__c` |
| Run Apex (set-up, fixes, several answers at once) | `node scripts/wizard.mjs apex path/to/script.apex`, or the code in quotes |
| Deploy code to Wizard | The **Deploy to Wizard** job. Its file, `.github/workflows/deploy-wizard.yml`, says how to start it. |
| Check a pull request's Apex | Nothing to do: CI deploys check-only and runs every hub test in Wizard on each pull request. |
| Refresh the bank registers | Replace the files in `data/bank-registers/` and merge (docs/runbook.md). |

## Before the first call

1. The repository must be in the session with **push** access. Call `add_repo` with owner `topchap01`, repo `trevor-claim-hub`, access `push`, then clone it. Starting a job needs push access; read access is not enough.
2. Run the commands from the clone's root folder.

## How it behaves

- Each call takes about 1 to 2 minutes: the job installs the Salesforce CLI and signs in every time. When you need several answers, ask for them in one Apex script with `System.debug` lines rather than making several calls.
- The result prints on stdout: a one-line summary, then the rows (one JSON object per line), the debug lines or the fields.
- Exit code 0 means Salesforce ran it. Exit code 1 means Salesforce refused it (bad SOQL, compile error, an exception) or the job failed; the reason is printed.
- An Apex exception rolls back every change the script made.
- Output is capped at 60,000 characters. Select only the fields you need and add a `LIMIT`.
- Each result is also kept on GitHub as a check run named `Wizard result <id>`, against the commit the job ran from.

## Rules

1. **Wizard only.** The job signs in with the sandbox secrets and stops unless `Organization.IsSandbox` is true. Production stays read-only and is never reached this way (CLAUDE.md rule 1).
2. **Apex changes Wizard for real.** It runs as Mark's Wizard admin user. Before running a script that writes, say in one line what it will change. Read-only questions need no warning.
3. **Made-up data only.** Create claimants with `@example.com` addresses (CLAUDE.md rule 2).
4. **Treat older records as possibly real.** Wizard was created from production, so records you did not make may be copies of real customers'. Select only the fields the task needs. Never copy customer names, emails, phone numbers, addresses or bank details into chat, pull requests or docs. Remember that results stay visible on GitHub to anyone with access to the repository.
5. **No credentials, ever.** If a job fails at "Sign in to the sandbox", report the error the job shows. Don't ask anyone for a password or key; the fix is in Wizard's Claim Hub CI app or the repository's secrets (docs/runbook.md).

## Without a clone

If a clone isn't possible, the same job can be driven with `gh api`. Pick any short id, for example `a1b2c3`:

```bash
gh api -X POST repos/topchap01/trevor-claim-hub/actions/workflows/wizard-console.yml/dispatches \
  -f ref=main -f 'inputs[kind]=query' -f 'inputs[body]=SELECT Id, Name FROM Promotional_Campaign__c LIMIT 5' \
  -f 'inputs[request_id]=a1b2c3' -F return_run_details=true
# -> {"workflow_run_id": N, ...}. Poll until "completed":
gh api repos/topchap01/trevor-claim-hub/actions/runs/N --jq '.status + " " + (.conclusion // "") + " " + .head_sha'
# Then read the result, using the head_sha from the run:
gh api "repos/topchap01/trevor-claim-hub/commits/<head_sha>/check-runs?check_name=Wizard%20result%20a1b2c3" \
  --jq '.check_runs[0] | .conclusion, .output.summary, .output.text'
```
