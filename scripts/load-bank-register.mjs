#!/usr/bin/env node
// Loads the bank registers the claim hub checks bank details against into Hub_Bank_Branch__c (decisions.md #11).
//
//   NZ: Payments NZ Bank Branch Register, the .xlsx (or a .csv saved from it) from
//       https://www.paymentsnz.co.nz/resources/industry-registers/bank-branch-register/
//   AU: AusPayNet BSB directory, full version (.txt or .csv), plus optionally the "Key to Abbreviations" .csv for
//       full bank names, from https://auspaynet.com.au/BSBLinks (updated on the first NSW business day of each month)
//
// Usage:
//   node scripts/load-bank-register.mjs --org wizard --nz BankBranchRegister.xlsx --au BSBDirectoryFull.txt --au-key key.csv
//   add --dry-run to parse and write the upload file without touching Salesforce.
//
// Rows are upserted on Key__c, then rows an earlier load left behind (branches the register no longer lists) are deleted.
// Production is refused unless --approved-for-production is given (CLAUDE.md: production changes need Mark's approval).
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import zlib from 'node:zlib';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

// Below these counts the file is probably the wrong one or cut short, so nothing is loaded or deleted.
// NZ: the January 2026 register lists 3,296 branch numbers. AU: a deliberately low floor; adjust after the first real load.
export const MIN_ROWS = { NZ: 1000, AU: 1000 };

const LIMITS = { Name: 80, Key__c: 12, Country__c: 2, Bank_Code__c: 3, Bank_Name__c: 80, Branch_Name__c: 80, Suburb__c: 40, State__c: 3, Payments__c: 3, Load__c: 20 };
export const COLUMNS = Object.keys(LIMITS);

// ------------------------------------------------------------------ CSV and XLSX reading

/** Parses CSV text into rows of strings (quoted fields, doubled quotes, CRLF). */
export function parseCsv(text) {
  const rows = [];
  let row = [], field = '', quoted = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (quoted) {
      if (ch === '"' && text[i + 1] === '"') { field += '"'; i++; }
      else if (ch === '"') quoted = false;
      else field += ch;
    } else if (ch === '"') quoted = true;
    else if (ch === ',') { row.push(field); field = ''; }
    else if (ch === '\n' || ch === '\r') {
      if (ch === '\r' && text[i + 1] === '\n') i++;
      row.push(field); field = '';
      if (row.some((f) => f !== '')) rows.push(row);
      row = [];
    } else field += ch;
  }
  row.push(field);
  if (row.some((f) => f !== '')) rows.push(row);
  return rows;
}

/** Reads one file out of a zip archive (an .xlsx is a zip). */
function unzipEntry(buf, name) {
  // End of central directory: last 22+ bytes, signature 0x06054b50
  let eocd = buf.length - 22;
  while (eocd >= 0 && buf.readUInt32LE(eocd) !== 0x06054b50) eocd--;
  if (eocd < 0) throw new Error('Not a zip/xlsx file');
  let p = buf.readUInt32LE(eocd + 16);
  const count = buf.readUInt16LE(eocd + 10);
  for (let i = 0; i < count; i++) {
    const method = buf.readUInt16LE(p + 10), size = buf.readUInt32LE(p + 20);
    const nameLen = buf.readUInt16LE(p + 28), extraLen = buf.readUInt16LE(p + 30), commentLen = buf.readUInt16LE(p + 32);
    const local = buf.readUInt32LE(p + 42);
    const entry = buf.toString('utf8', p + 46, p + 46 + nameLen);
    if (entry === name) {
      const start = local + 30 + buf.readUInt16LE(local + 26) + buf.readUInt16LE(local + 28);
      const data = buf.subarray(start, start + size);
      return method === 0 ? data : zlib.inflateRawSync(data);
    }
    p += 46 + nameLen + extraLen + commentLen;
  }
  return null;
}

const xmlText = (s) => s.replace(/<[^>]+>/g, '').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, '&');

/** First worksheet of an .xlsx as rows of strings. Enough for a plain register export: shared, inline and number cells. */
export function readXlsx(buf) {
  const shared = [];
  const ss = unzipEntry(buf, 'xl/sharedStrings.xml');
  if (ss) for (const m of ss.toString('utf8').matchAll(/<si>([\s\S]*?)<\/si>/g)) shared.push(xmlText(m[1]));
  const sheet = unzipEntry(buf, 'xl/worksheets/sheet1.xml');
  if (!sheet) throw new Error('No first worksheet in the .xlsx');
  const col = (ref) => [...ref.replace(/[0-9]/g, '')].reduce((n, c) => n * 26 + c.charCodeAt(0) - 64, 0) - 1;
  const rows = [];
  for (const r of sheet.toString('utf8').matchAll(/<row[^>]*>([\s\S]*?)<\/row>/g)) {
    const row = [];
    for (const c of r[1].matchAll(/<c ([^>]*?)(?:\/>|>([\s\S]*?)<\/c>)/g)) {
      const attrs = c[1], inner = c[2] || '';
      const ref = /r="([A-Z]+)[0-9]+"/.exec(attrs)?.[1];
      const type = /t="([a-zA-Z]+)"/.exec(attrs)?.[1];
      const v = /<v>([\s\S]*?)<\/v>/.exec(inner)?.[1];
      let value = '';
      if (type === 's') value = shared[Number(v)] ?? '';
      else if (type === 'inlineStr') value = xmlText(/<is>([\s\S]*?)<\/is>/.exec(inner)?.[1] || '');
      else if (v !== undefined) value = xmlText(v);
      row[ref ? col(ref) : row.length] = value;
    }
    rows.push(Array.from(row, (x) => x ?? ''));
  }
  return rows.filter((r) => r.some((f) => String(f).trim() !== ''));
}

function readTable(file) {
  const buf = fs.readFileSync(file);
  return /\.xlsx$/i.test(file) ? readXlsx(buf) : parseCsv(buf.toString('utf8').replace(/^﻿/, ''));
}

// ------------------------------------------------------------------ registers to rows

const tidy = (s) => String(s ?? '').replace(/\s+/g, ' ').trim();

/** Payments NZ Bank Branch Register rows (header row first) to Hub_Bank_Branch__c rows. */
export function nzRows(table, load) {
  const header = table[0].map((h) => tidy(h).toLowerCase().replace(/ /g, '_'));
  const at = (name) => { const i = header.indexOf(name); if (i < 0) throw new Error(`NZ register has no "${name}" column. Columns: ${header.join(', ')}`); return i; };
  const bankNo = at('bank_number'), bankName = at('bank_name'), branchNo = at('branch_number'), branchInfo = at('branch_information');
  const out = new Map();
  for (const r of table.slice(1)) {
    const bank = tidy(r[bankNo]).replace(/\.0$/, ''), branch = tidy(r[branchNo]).replace(/\.0$/, '');
    if (!/^[0-9]{1,2}$/.test(bank) || !/^[0-9]{1,4}$/.test(branch)) continue;
    const key = `NZ-${bank.padStart(2, '0')}-${branch.padStart(4, '0')}`;
    out.set(key, { Name: key, Key__c: key, Country__c: 'NZ', Bank_Code__c: bank.padStart(2, '0'), Bank_Name__c: tidy(r[bankName]), Branch_Name__c: tidy(r[branchInfo]), Load__c: load });
  }
  return [...out.values()];
}

/** AusPayNet "Key to Abbreviations" CSV: mnemonic to the institution's full name. */
export function auNames(table) {
  const names = new Map();
  for (const r of table) if (/^[A-Z0-9]{2,3}$/.test(tidy(r[0])) && tidy(r[1])) names.set(tidy(r[0]), tidy(r[1]));
  return names;
}

/**
 * AusPayNet BSB directory to Hub_Bank_Branch__c rows. Accepts the fixed-width .txt
 * (BSB 7, mnemonic 3, name 35, address 35, suburb 20, state 3, postcode 4, payments 3)
 * or the .csv with the same fields in the same order.
 */
export function auRows(text, isCsv, names, load) {
  const records = isCsv
    ? parseCsv(text).map((f) => f.map(tidy))
    : text.split(/\r?\n/).map((l) => [l.slice(0, 7), l.slice(7, 10), l.slice(10, 45), l.slice(45, 80), l.slice(80, 100), l.slice(100, 103), l.slice(103, 107), l.slice(107, 110)].map(tidy));
  const out = new Map();
  for (const f of records) {
    if (!/^[0-9]{3}-[0-9]{3}$/.test(f[0] || '')) continue;
    const key = `AU-${f[0]}`;
    const payments = ['P', 'E', 'H'].filter((s) => (f[7] || '').toUpperCase().includes(s)).join('');
    out.set(key, { Name: key, Key__c: key, Country__c: 'AU', Bank_Code__c: f[1], Bank_Name__c: names.get(f[1]) || f[1], Branch_Name__c: f[2],
      Suburb__c: f[4], State__c: f[5], Payments__c: payments, Load__c: load });
  }
  return [...out.values()];
}

/** Rows as a CSV for the Bulk API, cut to the field lengths. */
export function toCsv(rows) {
  const q = (v) => { const s = String(v ?? ''); return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s; };
  return [COLUMNS.join(','), ...rows.map((r) => COLUMNS.map((c) => q(String(r[c] ?? '').slice(0, LIMITS[c]))).join(','))].join('\n') + '\n';
}

// ------------------------------------------------------------------ Salesforce

/** Runs an sf command with --json. On failure, throws Salesforce's own message rather than "Command failed". */
function sf(args) {
  try {
    return JSON.parse(execFileSync('sf', [...args, '--json'], { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024, stdio: ['ignore', 'pipe', 'ignore'], env: { ...process.env, SFDX_DISABLE_DNS_CHECK: 'true' } }));
  } catch (err) {
    let reason = err.message;
    try { const j = JSON.parse(err.stdout); reason = [j.name, j.message].filter(Boolean).join(': '); } catch { /* keep the raw message */ }
    throw new Error(`sf ${args.slice(0, 3).join(' ')} failed: ${reason}`);
  }
}

function args(argv) {
  const a = {};
  for (let i = 0; i < argv.length; i++) {
    if (!argv[i].startsWith('--')) continue;
    const k = argv[i].slice(2);
    a[k] = argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[++i] : true;
  }
  return a;
}

async function main() {
  const a = args(process.argv.slice(2));
  if (!a.nz && !a.au) {
    console.error('Usage: node scripts/load-bank-register.mjs --org <alias> [--nz register.xlsx] [--au BSBDirectoryFull.txt [--au-key key.csv]] [--dry-run]');
    process.exit(2);
  }
  const load = new Date().toISOString().slice(0, 16);
  const byCountry = {};
  if (a.nz) byCountry.NZ = nzRows(readTable(a.nz), load);
  if (a.au) {
    const names = a['au-key'] ? auNames(readTable(a['au-key'])) : new Map();
    byCountry.AU = auRows(fs.readFileSync(a.au, 'utf8'), /\.csv$/i.test(a.au), names, load);
  }
  for (const [c, rows] of Object.entries(byCountry)) {
    console.log(`${c}: ${rows.length} rows`);
    if (rows.length < MIN_ROWS[c]) { console.error(`${c}: fewer than ${MIN_ROWS[c]} rows, so this looks like the wrong file or a cut-short download. Nothing loaded.`); process.exit(1); }
  }
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'bank-register-'));
  const file = path.join(dir, 'Hub_Bank_Branch__c.csv');
  fs.writeFileSync(file, toCsv(Object.values(byCountry).flat()));
  console.log(`Upload file: ${file}`);
  if (a['dry-run']) return;

  if (!a.org) { console.error('--org is required (e.g. --org wizard)'); process.exit(2); }
  const org = sf(['org', 'display', '--target-org', a.org]).result;
  const sandbox = /\.sandbox\.my\.salesforce\.com/i.test(org.instanceUrl || '') || /test\.salesforce\.com/i.test(org.loginUrl || '');
  if (!sandbox && !a['approved-for-production']) {
    console.error(`${org.instanceUrl} is not a sandbox. Loading production needs Mark's approval; rerun with --approved-for-production once you have it.`);
    process.exit(1);
  }

  const up = sf(['data', 'upsert', 'bulk', '--sobject', 'Hub_Bank_Branch__c', '--file', file, '--external-id', 'Key__c', '--target-org', a.org, '--wait', '30']);
  console.log('Upserted:', up.result?.jobInfo?.numberRecordsProcessed ?? up.result?.processedRecords ?? 'see job in Setup', 'failed:', up.result?.jobInfo?.numberRecordsFailed ?? up.result?.failedRecords ?? 0);

  for (const c of Object.keys(byCountry)) {
    const stale = sf(['data', 'query', '--target-org', a.org, '--query', `SELECT Id FROM Hub_Bank_Branch__c WHERE Country__c = '${c}' AND Load__c != '${load}'`]).result.records;
    if (!stale.length) { console.log(`${c}: nothing left over from earlier loads`); continue; }
    const ids = path.join(dir, `stale-${c}.csv`);
    fs.writeFileSync(ids, 'Id\n' + stale.map((r) => r.Id).join('\n') + '\n');
    sf(['data', 'delete', 'bulk', '--sobject', 'Hub_Bank_Branch__c', '--file', ids, '--target-org', a.org, '--wait', '30']);
    console.log(`${c}: deleted ${stale.length} rows the register no longer lists`);
  }

  // Check what Salesforce now holds against the files, so a partly failed bulk job can't pass as a load
  const counts = Object.fromEntries(sf(['data', 'query', '--target-org', a.org, '--query', 'SELECT Country__c c, COUNT(Id) n FROM Hub_Bank_Branch__c GROUP BY Country__c'])
    .result.records.map((r) => [r.c, r.n]));
  let mismatch = false;
  for (const [c, rows] of Object.entries(byCountry)) {
    const held = counts[c] ?? 0;
    console.log(`${c}: ${held} rows in Salesforce, ${rows.length} in the file`);
    if (held !== rows.length) mismatch = true;
  }
  if (mismatch) throw new Error('Salesforce does not hold the same number of rows as the files. Check the bulk job under Setup, Bulk Data Load Jobs.');
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((err) => { console.error(err.message); process.exit(1); });
}
