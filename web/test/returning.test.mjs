// Unit tests for remembering a claim on the claimant's phone and the "Welcome back" line.
// Run: npm test
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { claimCookie, claimCookieName, remember, welcomeBackLine, CLAIM_COOKIE_DAYS } from '../lib/returning.js';

const TOKEN = 'A'.repeat(43);

test('claimCookie: one secure, script-proof cookie per promotion', () => {
  const c = claimCookie('aeg-nz-cashback', TOKEN);
  assert.ok(c.startsWith(`hub_claim_aeg-nz-cashback=${TOKEN};`));
  for (const part of ['Path=/', 'HttpOnly', 'Secure', 'SameSite=Lax', `Max-Age=${CLAIM_COOKIE_DAYS * 86400}`]) assert.ok(c.includes(part), part);
  assert.equal(claimCookieName('x-promo'), 'hub_claim_x-promo');
});

test('claimCookie: refuses anything that is not a real slug and link code', () => {
  assert.equal(claimCookie('Bad Slug', TOKEN), null);
  assert.equal(claimCookie('aeg-nz-cashback', 'short'), null);
  assert.equal(claimCookie('aeg-nz-cashback', `${TOKEN}; Domain=evil.example`), null, 'no header injection');
  assert.equal(claimCookie(undefined, undefined), null);
});

test('remember: adds the cookie to the response, or leaves it alone', () => {
  const ok = remember(new Response('{}'), 'aeg-nz-cashback', TOKEN);
  assert.match(ok.headers.get('set-cookie'), /^hub_claim_aeg-nz-cashback=/);
  const skipped = remember(new Response('{}'), 'aeg-nz-cashback', null);
  assert.equal(skipped.headers.get('set-cookie'), null);
});

test('welcomeBackLine: plain words for every stage', () => {
  assert.equal(welcomeBackLine({ stage: 'awaiting', outstanding: ['invoice', 'bank'] }), 'Your claim needs 2 more things from you.');
  assert.equal(welcomeBackLine({ stage: 'awaiting', outstanding: ['invoice'] }), 'Your claim needs 1 more thing from you.');
  assert.equal(welcomeBackLine({ stage: 'paid' }), 'Your cashback has been paid.');
  for (const stage of ['review', 'approved', 'payment_failed', 'not_approved', 'something_new', undefined]) {
    assert.ok(welcomeBackLine({ stage }).length > 10, String(stage));
  }
});
