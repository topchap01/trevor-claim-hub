import { test } from 'node:test';
import assert from 'node:assert/strict';
import { brandOf, campaignUrl, route } from '../lib/hosts.js';

const ROOT = 'test.entryform.claims';

test('brand comes from a subdomain of the root only', () => {
  assert.equal(brandOf('aeg.test.entryform.claims', ROOT), 'aeg');
  assert.equal(brandOf('AEG.test.entryform.claims:443', ROOT), 'aeg');
  assert.equal(brandOf('harvey-norman.test.entryform.claims', ROOT), 'harvey-norman');
  assert.equal(brandOf('test.entryform.claims', ROOT), null, 'the bare root is not a brand');
  assert.equal(brandOf('a.b.test.entryform.claims', ROOT), null, 'one label only');
  assert.equal(brandOf('www.test.entryform.claims', ROOT), null);
  assert.equal(brandOf('trevor-claim-hub-test.vercel.app', ROOT), null);
  assert.equal(brandOf('aeg.entryform.claims', 'entryform.claims'), 'aeg');
  assert.equal(brandOf('test.entryform.claims', 'entryform.claims'), null, 'the sandbox host is not a production brand');
  assert.equal(brandOf('aeg.test.entryform.claims', ''), null, 'no root set: no brand routing');
  assert.equal(brandOf('-bad.test.entryform.claims', ROOT), null);
});

test('a brand subdomain serves that brand\'s campaigns at short addresses', () => {
  assert.deepEqual(route('aeg.test.entryform.claims', '/nz-cashback', ROOT), { action: 'rewrite', pathname: '/aeg-nz-cashback' });
  assert.deepEqual(route('electrolux.test.entryform.claims', '/kitchen-refresh/', ROOT), { action: 'rewrite', pathname: '/electrolux-kitchen-refresh' });
});

test('the full slug on its own brand redirects to the short address', () => {
  assert.deepEqual(route('aeg.test.entryform.claims', '/aeg-nz-cashback', ROOT), { action: 'redirect', pathname: '/nz-cashback' });
});

test('another brand\'s campaign, pages or files are not found on a brand subdomain', () => {
  assert.equal(route('aeg.test.entryform.claims', '/a/b', ROOT).action, 'notFound');
  assert.equal(route('aeg.test.entryform.claims', '/api/campaign/electrolux-kitchen-refresh', ROOT).action, 'notFound');
  assert.equal(route('aeg.test.entryform.claims', '/api/campaign/electrolux-kitchen-refresh/claim', ROOT).action, 'notFound');
  assert.equal(route('aeg.test.entryform.claims', '/designs/electrolux-kitchen-refresh/logo.png', ROOT).action, 'notFound');
  assert.equal(route('aeg.test.entryform.claims', '/Bad_Name', ROOT).action, 'notFound');
});

test('hub routes pass through on every host', () => {
  for (const p of ['/', '/c', '/api/health', '/api/claim/abc', '/api/resend', '/api/campaign/aeg-nz-cashback/claim', '/designs/aeg-nz-cashback/banner.jpg', '/favicon.ico']) {
    assert.equal(route('aeg.test.entryform.claims', p, ROOT).action, 'next', p);
  }
});

test('other hosts keep the plain slug addresses', () => {
  for (const h of ['test.entryform.claims', 'trevor-claim-hub-test.vercel.app', 'aegcashbackpromo.co.nz']) {
    assert.equal(route(h, '/aeg-nz-cashback', ROOT).action, 'next', h);
  }
});

test('campaign address is built from brand and slug', () => {
  assert.equal(campaignUrl('aeg', 'aeg-nz-cashback', 'entryform.claims'), 'https://aeg.entryform.claims/nz-cashback');
  assert.equal(campaignUrl('aeg', 'electrolux-kitchen-refresh', 'entryform.claims'), null, 'slug must belong to the brand');
});
