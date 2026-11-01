#!/usr/bin/env node
// Query or run Apex in the Wizard sandbox from any session that has the `gh` CLI, with no Salesforce login of its own.
// It starts the "Wizard console" GitHub job, waits for it, and prints the result. See .claude/skills/wizard/SKILL.md.
//
//   node scripts/wizard.mjs query "SELECT Id, Name FROM Promotional_Campaign__c WHERE Hub_Enabled__c = true"
//   node scripts/wizard.mjs tooling-query "SELECT Name, ApiVersion FROM ApexClass WHERE Name LIKE 'ClaimHub%'"
//   node scripts/wizard.mjs describe Entry__c
//   node scripts/wizard.mjs apex scripts/apex/some-script.apex      (a file)
//   node scripts/wizard.mjs apex "System.debug([SELECT COUNT() FROM Entry__c]);"
//
// Exit code 0 when Salesforce ran it cleanly, 1 when it refused (bad SOQL, compile error, exception) or the job failed.
// Wizard only. Production is never reachable this way: the job signs in with the sandbox secrets and checks IsSandbox.
import fs from 'node:fs';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const REPO = process.env.WIZARD_REPO || 'topchap01/trevor-claim-hub';
const WORKFLOW = 'wizard-console.yml';
const KINDS = ['query', 'tooling-query', 'apex', 'describe'];
const MAX_BODY = 60_000; // GitHub limits the inputs of one job start to 65,535 characters

const gh = (args) => JSON.parse(execFileSync('gh', ['api', ...args], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 }) || 'null');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export function parseArgs(argv) {
  const [kind, ...rest] = argv;
  if (!KINDS.includes(kind) || !rest.length) return null;
  let body = rest.join(' ');
  if (kind === 'apex' && rest.length === 1 && fs.existsSync(rest[0]) && fs.statSync(rest[0]).isFile()) body = fs.readFileSync(rest[0], 'utf8');
  if (kind === 'apex' && rest.length === 1 && rest[0] === '-') body = fs.readFileSync(0, 'utf8');
  return { kind, body };
}

async function main() {
  const req = parseArgs(process.argv.slice(2));
  if (!req) {
    console.error(`Usage: node scripts/wizard.mjs <${KINDS.join('|')}> <SOQL | Apex or .apex file | object name>`);
    process.exit(2);
  }
  if (req.body.length > MAX_BODY) { console.error(`Too long (${req.body.length} characters; the limit is ${MAX_BODY}).`); process.exit(2); }
  const id = crypto.randomBytes(5).toString('hex');

  const started = gh(['-X', 'POST', `repos/${REPO}/actions/workflows/${WORKFLOW}/dispatches`, '-f', 'ref=main',
    '-f', `inputs[kind]=${req.kind}`, '-f', `inputs[body]=${req.body}`, '-f', `inputs[request_id]=${id}`, '-F', 'return_run_details=true']);
  const runId = started && started.workflow_run_id;
  if (!runId) throw new Error('GitHub did not return a run for the Wizard console job.');
  process.stderr.write(`Wizard ${req.kind} ${id}: run ${runId} started, waiting`);

  let run;
  for (let waited = 0; ; waited += 5) {
    await sleep(5000);
    run = gh([`repos/${REPO}/actions/runs/${runId}`]);
    if (run.status === 'completed') break;
    if (waited > 900) throw new Error(`Still running after 15 minutes: ${run.html_url}`);
    process.stderr.write('.');
  }
  process.stderr.write(` ${run.conclusion}\n`);

  const checks = gh([`repos/${REPO}/commits/${run.head_sha}/check-runs?check_name=${encodeURIComponent(`Wizard result ${id}`)}`]);
  const result = checks.check_runs && checks.check_runs[0];
  if (!result) {
    const job = gh([`repos/${REPO}/actions/runs/${runId}/jobs`]).jobs[0];
    const notes = job ? gh([`repos/${REPO}/check-runs/${job.id}/annotations`]).filter((a) => !/Node\.js 20|ubuntu-latest/.test(a.message)) : [];
    console.log(`No result was published. ${run.html_url}`);
    for (const a of notes) console.log(`${a.title}: ${a.message}`);
    process.exit(1);
  }
  console.log(result.output.summary);
  if (result.output.text) console.log(`\n${result.output.text}`);
  process.exit(result.conclusion === 'success' ? 0 : 1);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((err) => { console.error(`\n${err.message}`); process.exit(1); });
}
