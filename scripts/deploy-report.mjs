#!/usr/bin/env node
// Reads `sf project deploy validate --json` on stdin and puts each failure on the CI check as an annotation,
// so a failed deploy or test can be read without opening the job log. Prints a plain summary to the log too.
// Usage (CI): sf project deploy validate ... --json | node scripts/deploy-report.mjs
let raw = '';
process.stdin.on('data', (d) => (raw += d)).on('end', () => {
  let j;
  try { j = JSON.parse(raw); } catch {
    console.log(raw.slice(0, 4000));
    console.log(`::error title=Deploy validation::Salesforce returned no readable result. ${raw.replace(/\s+/g, ' ').slice(0, 400).replace(/%/g, '%25')}`);
    return;
  }
  const one = (s) => String(s ?? '').replace(/\s+/g, ' ').trim().slice(0, 900);
  // GitHub workflow commands: % in the message, and also : and , in a property such as title, must be escaped
  const error = (title, msg) => console.log(`::error title=${one(title).replace(/%/g, '%25').replace(/:/g, '%3A').replace(/,/g, '%2C')}::${one(msg).replace(/%/g, '%25')}`);
  const list = (x) => (x == null ? [] : Array.isArray(x) ? x : [x]);
  const r = j.result || {};
  const d = r.details || {};
  const tests = d.runTestResult || {};
  console.log(`Status: ${r.status || j.name || 'unknown'}${r.id ? ` (deploy ID ${r.id})` : ''}`);
  console.log(`Components: ${r.numberComponentsDeployed ?? '?'} of ${r.numberComponentsTotal ?? '?'}, ${r.numberComponentErrors ?? 0} errors`);
  console.log(`Tests: ${r.numberTestsCompleted ?? '?'} of ${r.numberTestsTotal ?? '?'}, ${r.numberTestErrors ?? 0} failed`);
  for (const f of list(d.componentFailures)) {
    const where = [f.fileName, f.lineNumber && `line ${f.lineNumber}`].filter(Boolean).join(' ');
    error(`Deploy ${f.fullName || f.componentType}`, `${where}: ${f.problem}`);
  }
  for (const f of list(tests.failures)) {
    error(`Test ${f.name}.${f.methodName}`, `${f.message} ${f.stackTrace || ''}`);
  }
  for (const w of list(tests.codeCoverageWarnings)) {
    error(`Coverage ${w.name || ''}`, w.message);
  }
  if (j.status !== 0 && !list(d.componentFailures).length && !list(tests.failures).length) {
    error('Deploy validation', j.message || r.errorMessage || r.status || 'failed');
  }
});
