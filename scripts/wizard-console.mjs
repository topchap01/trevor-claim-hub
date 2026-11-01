#!/usr/bin/env node
// Runs one request against the Wizard sandbox inside the "Wizard console" GitHub job, and writes result.json:
// the body of a GitHub check run named "Wizard result <request id>", which scripts/wizard.mjs reads back.
// Env: KIND (query | tooling-query | apex | describe), BODY, REQUEST_ID, GITHUB_SHA. Assumes `sf` is signed in as alias "ci".
// Never prints credentials: it only ever sees the org alias.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const MAX_TEXT = 60_000; // a check run's text holds 65,535 characters
const kind = process.env.KIND || '';
const body = process.env.BODY || '';
const requestId = process.env.REQUEST_ID || process.env.GITHUB_RUN_ID || 'manual';

/** Runs sf with --json and returns the parsed result, failures included (sf reports errors as JSON too). */
function sf(args) {
  let out;
  try {
    out = execFileSync('sf', [...args, '-o', 'ci', '--json'], { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024, stdio: ['ignore', 'pipe', 'ignore'], env: { ...process.env, SFDX_DISABLE_DNS_CHECK: 'true' } });
  } catch (err) {
    out = err.stdout || '';
  }
  try { return JSON.parse(out); } catch { return { status: 1, name: 'Unreadable', message: String(out).slice(0, 2000) }; }
}

const errorText = (j) => [j.name, j.message].filter(Boolean).join(': ') || 'Salesforce returned an error';
const strip = (r) => { if (r && typeof r === 'object') { delete r.attributes; for (const v of Object.values(r)) strip(v); } return r; };

function query(tooling) {
  const j = sf(['data', 'query', '-q', body, ...(tooling ? ['--use-tooling-api'] : [])]);
  if (j.status !== 0) return { ok: false, summary: 'Query failed', text: errorText(j) };
  const rows = (j.result.records || []).map(strip);
  const done = j.result.done !== false;
  return { ok: true, summary: `${j.result.totalSize} row${j.result.totalSize === 1 ? '' : 's'}${done ? '' : ' (more exist: add LIMIT or narrow the query)'}`,
    text: rows.map((r) => JSON.stringify(r)).join('\n') };
}

function apex() {
  const file = path.join(os.tmpdir(), 'wizard-console.apex');
  fs.writeFileSync(file, body);
  const j = sf(['apex', 'run', '-f', file]);
  const r = j.result || {};
  const debug = String(r.logs || '').split('\n').filter((l) => l.includes('|USER_DEBUG|')).map((l) => l.split('|DEBUG|').pop());
  if (j.status !== 0 && !('success' in r)) return { ok: false, summary: 'Apex did not run', text: errorText(j) };
  if (!r.compiled) return { ok: false, summary: 'Apex did not compile', text: `Line ${r.line}, column ${r.column}: ${r.compileProblem}` };
  if (!r.success) return { ok: false, summary: 'Apex threw an exception (all its changes were rolled back)', text: [r.exceptionMessage, r.exceptionStackTrace, '', ...debug].join('\n') };
  return { ok: true, summary: `Apex ran${debug.length ? `, ${debug.length} debug line${debug.length === 1 ? '' : 's'}` : ''}`, text: debug.join('\n') || '(no System.debug output)' };
}

function describe() {
  if (!/^[A-Za-z][A-Za-z0-9_]*$/.test(body.trim())) return { ok: false, summary: 'Bad object name', text: 'Give one object API name, e.g. Entry__c' };
  const j = sf(['sobject', 'describe', '-s', body.trim()]);
  if (j.status !== 0) return { ok: false, summary: 'Describe failed', text: errorText(j) };
  const d = j.result;
  const fields = (d.fields || []).map((f) => [f.name, f.type + (f.length ? `(${f.length})` : ''), f.label, f.nillable ? '' : 'required',
    (f.referenceTo || []).length ? `-> ${f.referenceTo.join('/')}` : '', f.unique ? 'unique' : '', f.externalId ? 'external id' : ''].filter(Boolean).join(' | '));
  const types = (d.recordTypeInfos || []).filter((t) => !t.master).map((t) => `${t.developerName} (${t.name})${t.active ? '' : ' inactive'}`);
  return { ok: true, summary: `${d.name}: ${fields.length} fields${types.length ? `, ${types.length} record types` : ''}`,
    text: [`Label: ${d.label}`, types.length ? `Record types: ${types.join(', ')}` : '', '', ...fields].filter((l, i) => l || i === 2).join('\n') };
}

const handlers = { query: () => query(false), 'tooling-query': () => query(true), apex, describe };
let res;
if (!handlers[kind]) res = { ok: false, summary: `Unknown kind "${kind}"`, text: 'Use query, tooling-query, apex or describe.' };
else if (!body.trim()) res = { ok: false, summary: 'Nothing to run', text: 'The body was empty.' };
else res = handlers[kind]();

let text = res.text || '';
if (text.length > MAX_TEXT) text = `${text.slice(0, MAX_TEXT)}\n\n[Cut at ${MAX_TEXT.toLocaleString('en-AU')} characters: select fewer fields or add a LIMIT.]`;
fs.writeFileSync('result.json', JSON.stringify({
  name: `Wizard result ${requestId}`, head_sha: process.env.GITHUB_SHA, status: 'completed', conclusion: res.ok ? 'success' : 'failure',
  output: { title: `${kind}: ${res.summary}`.slice(0, 255), summary: res.summary, text },
}));
console.log(`${kind}: ${res.summary}`);
process.exitCode = res.ok ? 0 : 1;
