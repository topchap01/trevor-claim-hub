#!/usr/bin/env node
// End-to-end smoke test of a deployed claim hub: refusals, a full claim, invoice upload, serials, link resend, health.
// Creates made-up claims (@example.com) on the given campaign. Sandbox only.
//
// Usage: node scripts/smoke-test.mjs <baseUrl> [slug]
//   VERCEL_BYPASS=<protection bypass secret>  for SSO-protected preview deployments
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const BASE = (process.argv[2] || 'http://127.0.0.1:3100').replace(/\/$/, '');
const SLUG = process.argv[3] || 'aeg-nz-cashback';
const here = path.dirname(fileURLToPath(import.meta.url));
const headers = { 'Content-Type': 'application/json', ...(process.env.VERCEL_BYPASS ? { 'x-vercel-protection-bypass': process.env.VERCEL_BYPASS } : {}) };
const call = async (method, p, body) => {
  const r = await fetch(`${BASE}/api/${p}`, { method, headers, body: body ? JSON.stringify(body) : undefined });
  return { status: r.status, body: await r.json().catch(() => ({})) };
};
let failed = 0;
const check = (name, ok, detail = '') => { console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${ok ? '' : '  ' + JSON.stringify(detail).slice(0, 300)}`); if (!ok) failed++; };
const run = String(Date.now()).slice(-6);
const serial = () => '6' + String(Math.floor(Math.random() * 1e7)).padStart(7, '0');

const health = await call('GET', 'health');
check('health check answers', health.status === 200 || health.status === 503, health);

const c = await call('GET', `campaign/${SLUG}`);
check('campaign loads', c.status === 200 && c.body.products?.length > 0, c);
if (c.status !== 200) process.exit(1);
const min = Math.max(1, Number(c.body.minProducts) || 1);
const spendEach = Math.ceil((Number(c.body.minSpend) || 0) / min) + 100;
const items = c.body.products.slice(0, min).map((p) => ({ promoProductId: p.id, price: spendEach }));
const person = { firstName: 'Smoke', lastName: 'Test', email: `smoke.test.${run}@example.com`, mobile: '021 555 0199' };
const bank = c.body.country === 'NZ' ? { name: 'S Test', account: '12-3140-0123456-00' } : { name: 'S Test', bsb: '062000', account: '12345678' };

check('refuses a missing name', (await call('POST', `campaign/${SLUG}/claim`, { ...person, firstName: '', products: items })).status === 400);
check('refuses a product from another promotion', (await call('POST', `campaign/${SLUG}/claim`, { ...person, products: [{ promoProductId: 'a0X000000000000AAA' }] })).status === 400);
check('refuses bad JSON', (await fetch(`${BASE}/api/campaign/${SLUG}/claim`, { method: 'POST', headers, body: 'nope' })).status === 400);

const lodged = await call('POST', `campaign/${SLUG}/claim`, { ...person, products: items, bank });
check('lodges a claim', lodged.status === 200 && lodged.body.token, lodged);
if (lodged.status !== 200) process.exit(1);
const t = lodged.body.token;
check('one claim per email', (await call('POST', `campaign/${SLUG}/claim`, { ...person, products: items, bank })).status === 409);

let v = await call('GET', `claim/${t}`);
check('claim page loads', v.status === 200 && v.body.stage === 'awaiting', v);
check('unknown link is refused', (await call('GET', `claim/${'x'.repeat(43)}`)).status === 404);

const inv = fs.readFileSync(path.join(here, 'fixtures/sample-invoice.jpg')).toString('base64');
const r = await call('POST', `claim/${t}/receipt`, { base64: inv, contentType: 'image/jpeg', fileName: 'invoice.jpg' });
check('invoice uploads and is read', r.status === 200 && r.body.checklist?.invoice === true && r.body.receipts?.[0]?.check, r);

const prods = r.body.products || v.body.products;
const prefix = (c.body.excludedSerialPrefixes || '').split(',')[0];
if (prefix) check('refuses an excluded serial prefix', (await call('POST', `claim/${t}/serial`, { productId: prods[0].id, serial: prefix + '1234567' })).status === 400);
for (const p of prods) {
  const s = await call('POST', `claim/${t}/serial`, { productId: p.id, serial: serial() });
  check(`saves a serial for ${p.model}`, s.status === 200, s);
  v = s;
}
check('complete claim moves to the team', v.body.stage === 'review', v.body.outstanding);
check('resend link answers the same either way', (await call('POST', 'resend', { slug: SLUG, email: person.email })).status === 200
  && (await call('POST', 'resend', { slug: SLUG, email: `nobody.${run}@example.com` })).status === 200);

console.log(`\n${failed ? failed + ' check(s) failed' : 'All checks passed'}  (claim ${t.slice(0, 6)}…, ${person.email})`);
process.exit(failed ? 1 : 0);
