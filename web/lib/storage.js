// Server-only: the nightly invoice storage check (decisions.md #17). Salesforce is the index of which file belongs to which
// claim; S3 is the store. Once a night this compares the two, deletes what should go and records the result in Salesforce,
// where the console shows it.
//
// What it deletes, and the guards that stop it deleting the wrong things:
//   - Files no claim points to (a replaced invoice, or an upload Salesforce never saved), once they are 7 days old.
//     Nothing is deleted if the Salesforce index could not be read in full, or if the unlinked files are more than
//     a tenth of the store: that pattern means a fault (wrong folder, wrong org), not leftovers.
//   - Files whose retention period has ended, as Salesforce decides them (ClaimHubStorage.due). None while no period is set.
// Claims whose file is missing are reported to Salesforce, which puts each in front of a person once. If more than half
// the files Salesforce expects are missing, that is reported as a fault and no claim is flagged.
import { storeOf } from './files.js';

export const GRACE_DAYS = 7;
const DAY = 86_400_000;

/** Compares the store with the index. stored: [{ key, size, at }], indexed: Set of keys. Pure; no deletes. */
export function reconcile({ stored, indexed, now = new Date(), graceDays = GRACE_DAYS }) {
  const inStore = new Set(stored.map((f) => f.key));
  const unlinked = stored.filter((f) => !indexed.has(f.key));
  const removable = unlinked.filter((f) => f.at && now - f.at > graceDays * DAY).map((f) => f.key);
  // Only files that live in S3 can be missing from it (older sandbox files are in Blob)
  const expected = [...indexed].filter((k) => storeOf(k) === 's3');
  const missing = expected.filter((k) => !inStore.has(k));
  return {
    files: stored.length,
    bytes: stored.reduce((n, f) => n + (f.size || 0), 0),
    unlinked: unlinked.length,
    removable,
    expected: expected.length,
    missing,
  };
}

/** Too many unlinked files to be leftovers: a fault, so nothing is deleted. */
export const tooManyToRemove = (removable, files) => removable > Math.max(50, Math.floor(files / 10));
/** Most of what Salesforce expects is missing: a fault (wrong folder or bucket), so no claim is flagged. */
export const tooManyMissing = (missing, expected) => expected >= 10 && missing > expected / 2;

/**
 * Runs the check. Dependencies are passed in so tests can stand in for Salesforce and S3:
 *   hub(path, opts) -> { status, data }   (lib/sf.js)
 *   listStored() -> async iterable of { key, size, at }
 *   deleteStored(keys) -> { deleted, failed }
 *   store: the store's name for the record
 * Returns what was reported to Salesforce, plus whether the report was saved.
 */
export async function runStorageCheck({ hub, listStored, deleteStored, store, now = new Date() }) {
  const problems = [];
  const report = { store, files: null, bytes: null, unlinked: null, unlinkedRemoved: 0, missingCount: 0, missing: [], expiredRemoved: [], problems };
  const send = async () => {
    const r = await hub('storage/report', { method: 'POST', body: report });
    return { ...report, saved: r.status === 200, missing: report.missing.length, expiredRemoved: report.expiredRemoved.length };
  };

  // 1. The index: every key Salesforce points to. A partial index would make real files look unlinked, so stop here.
  const indexed = new Set();
  let after = '';
  for (let page = 0; page < 5000; page++) {
    const r = await hub(`storage/keys${after ? '/' + after : ''}`);
    if (r.status !== 200 || !Array.isArray(r.data?.keys)) {
      problems.push(`Could not read the Salesforce index (error ${r.status}). Nothing was deleted.`);
      return send();
    }
    for (const k of r.data.keys) indexed.add(k);
    if (!r.data.next) break;
    after = r.data.next;
  }

  // 2. The store.
  const stored = [];
  try { for await (const f of listStored()) stored.push(f); }
  catch (err) {
    problems.push(`Could not list the store (${err.name || 'error'}). Nothing was deleted.`);
    return send();
  }

  // 3. Compare.
  const r = reconcile({ stored, indexed, now });
  Object.assign(report, { files: r.files, bytes: r.bytes, unlinked: r.unlinked });

  // 4. Unlinked files older than the grace period.
  if (r.removable.length && tooManyToRemove(r.removable.length, r.files)) {
    problems.push(`${r.removable.length} of ${r.files} files have no claim pointing to them. That is too many to be leftovers, so none were deleted. Check the bucket and the Salesforce org match.`);
  } else if (r.removable.length) {
    const d = await deleteStored(r.removable);
    report.unlinkedRemoved = d.deleted.length;
    if (d.failed.length) problems.push(`S3 refused to delete ${d.failed.length} unlinked file(s).`);
  }

  // 5. Retention: Salesforce decides what is due.
  const due = await hub('storage/due');
  if (due.status !== 200) problems.push(`Could not read which files are due for deletion (error ${due.status}).`);
  const dueKeys = due.status === 200 ? (due.data.keys || []).filter((k) => storeOf(k) === 's3') : [];
  if (dueKeys.length) {
    const inStore = new Set(stored.map((f) => f.key));
    const present = dueKeys.filter((k) => inStore.has(k));
    const d = present.length ? await deleteStored(present) : { deleted: [], failed: [] };
    // A due file already gone from the store is done with too
    report.expiredRemoved = [...d.deleted, ...dueKeys.filter((k) => !inStore.has(k))];
    if (d.failed.length) problems.push(`S3 refused to delete ${d.failed.length} file(s) due under retention.`);
  }

  // 6. Missing files, leaving out those just deleted under retention.
  const gone = new Set(report.expiredRemoved);
  const missing = r.missing.filter((k) => !gone.has(k));
  report.missingCount = missing.length;
  if (tooManyMissing(missing.length, r.expected)) {
    problems.push(`${missing.length} of ${r.expected} files Salesforce expects are not in the store. That looks like the wrong bucket or folder, so no claim was flagged.`);
  } else {
    report.missing = missing.slice(0, 2000);
  }
  return send();
}
