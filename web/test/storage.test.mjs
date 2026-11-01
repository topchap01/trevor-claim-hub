// Unit tests for the nightly invoice storage check (decisions.md #17). Salesforce and S3 are stand-ins.
// Run: npm test
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { reconcile, runStorageCheck, tooManyToRemove, tooManyMissing } from '../lib/storage.js';

const NOW = new Date('2026-11-02T03:17:00Z');
const daysAgo = (n) => new Date(NOW - n * 86_400_000);
let n = 0;
const s3Key = () => `invoices/${'a'.repeat(24)}/00000000-0000-4000-8000-${String(++n).padStart(12, '0')}.jpg`;
const file = (key, ageDays = 30, size = 1000) => ({ key, size, at: daysAgo(ageDays) });

/** A stand-in for the Salesforce storage API: an index in pages, a due list, and the reports it received. */
function fakeHub({ keys = [], due = [], page = 2, failKeys = false } = {}) {
  const reports = [];
  const hub = async (path, opts = {}) => {
    if (path.startsWith('storage/keys')) {
      if (failKeys) return { status: 503, data: { error: 'down' } };
      const after = path.split('/')[2];
      const start = after ? Number(after) : 0;
      const slice = keys.slice(start, start + page);
      return { status: 200, data: { keys: slice, next: start + page < keys.length ? String(start + page) : null } };
    }
    if (path === 'storage/due') return { status: 200, data: { months: due.length ? 12 : null, keys: due } };
    if (path === 'storage/report') { reports.push(opts.body); return { status: 200, data: {} }; }
    return { status: 404, data: {} };
  };
  return { hub, reports };
}
function fakeStore(files) {
  const deleted = [];
  return {
    deleted,
    async *listStored() { for (const f of files) yield f; },
    async deleteStored(keys) { deleted.push(...keys); return { deleted: keys, failed: [] }; },
  };
}

test('reconcile: counts the store, finds unlinked and missing files', () => {
  const [a, b, c, d] = [s3Key(), s3Key(), s3Key(), s3Key()];
  const blob = `invoices/${'a'.repeat(24)}/invoice-AbC.jpg`;
  const r = reconcile({ stored: [file(a), file(b, 2), file(c, 30)], indexed: new Set([a, d, blob]), now: NOW });
  assert.equal(r.files, 3);
  assert.equal(r.bytes, 3000);
  assert.equal(r.unlinked, 2);
  assert.deepEqual(r.removable, [c], 'only unlinked files past the 7-day grace');
  assert.deepEqual(r.missing, [d], 'Blob keys are never "missing" from S3');
  assert.equal(r.expected, 2);
});

test('guards: too many unlinked or missing files means a fault, not leftovers', () => {
  assert.equal(tooManyToRemove(50, 100), false);
  assert.equal(tooManyToRemove(51, 100), true);
  assert.equal(tooManyToRemove(100, 1000), false);
  assert.equal(tooManyToRemove(101, 1000), true);
  assert.equal(tooManyMissing(5, 8), false, 'small numbers are always reported');
  assert.equal(tooManyMissing(6, 10), true);
  assert.equal(tooManyMissing(5, 10), false);
});

test('a normal night: removes old unlinked files and expired files, reports the missing', async () => {
  const keys = Array.from({ length: 30 }, s3Key);
  const [expired, missing] = [keys[0], keys[1]];
  const stray = s3Key();
  const fresh = s3Key();
  const stored = keys.filter((k) => k !== missing).map((k) => file(k)).concat([file(stray, 10), file(fresh, 1)]);
  const { hub, reports } = fakeHub({ keys, due: [expired] });
  const store = fakeStore(stored);
  const r = await runStorageCheck({ hub, ...store, store: 'b/sandbox/invoices/', now: NOW });

  assert.equal(r.saved, true);
  assert.deepEqual(store.deleted.sort(), [stray, expired].sort(), 'the stray past grace and the expired file');
  const sent = reports[0];
  assert.equal(sent.files, 31);
  assert.equal(sent.unlinked, 2);
  assert.equal(sent.unlinkedRemoved, 1);
  assert.deepEqual(sent.expiredRemoved, [expired]);
  assert.deepEqual(sent.missing, [missing]);
  assert.equal(sent.missingCount, 1);
  assert.deepEqual(sent.problems, []);
  assert.equal(sent.store, 'b/sandbox/invoices/');
});

test('if the index cannot be read, nothing is deleted and the failure is reported', async () => {
  const { hub, reports } = fakeHub({ failKeys: true });
  const store = fakeStore([file(s3Key())]);
  const r = await runStorageCheck({ hub, ...store, store: 's', now: NOW });
  assert.deepEqual(store.deleted, []);
  assert.match(reports[0].problems[0], /Could not read the Salesforce index/);
  assert.equal(r.saved, true);
});

test('if the store cannot be listed, nothing is deleted', async () => {
  const { hub, reports } = fakeHub({ keys: [s3Key()] });
  const deleted = [];
  await runStorageCheck({
    hub, store: 's', now: NOW,
    listStored: async function* () { throw Object.assign(new Error('denied'), { name: 'AccessDenied' }); },
    deleteStored: async (k) => { deleted.push(...k); return { deleted: k, failed: [] }; },
  });
  assert.deepEqual(deleted, []);
  assert.match(reports[0].problems[0], /Could not list the store \(AccessDenied\)/);
});

test('a store full of files no claim knows is a fault: nothing deleted', async () => {
  const stored = Array.from({ length: 80 }, () => file(s3Key()));
  const { hub, reports } = fakeHub({ keys: [] });
  const store = fakeStore(stored);
  await runStorageCheck({ hub, ...store, store: 's', now: NOW });
  assert.deepEqual(store.deleted, []);
  assert.match(reports[0].problems[0], /too many to be leftovers/);
});

test('most expected files missing is a fault: no claim flagged, count still reported', async () => {
  const keys = Array.from({ length: 20 }, s3Key);
  const { hub, reports } = fakeHub({ keys });
  const store = fakeStore(keys.slice(0, 5).map((k) => file(k)));
  await runStorageCheck({ hub, ...store, store: 's', now: NOW });
  assert.deepEqual(reports[0].missing, []);
  assert.equal(reports[0].missingCount, 15);
  assert.match(reports[0].problems[0], /wrong bucket or folder/);
});
