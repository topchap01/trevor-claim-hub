// Nightly invoice storage check (lib/storage.js, decisions.md #17). Run by Vercel Cron (web/vercel.json), which sends
// CRON_SECRET as a bearer token; anything else is refused. Returns counts only.
import crypto from 'node:crypto';
import { hub } from '@/lib/sf';
import { s3Enabled, listStored, deleteStored, storeName } from '@/lib/files';
import { runStorageCheck } from '@/lib/storage';

export const dynamic = 'force-dynamic';
export const maxDuration = 300;

const reply = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });

function authorised(req) {
  const secret = process.env.CRON_SECRET;
  if (!secret) return false;
  const want = Buffer.from(`Bearer ${secret}`);
  const got = Buffer.from(req.headers.get('authorization') || '');
  return got.length === want.length && crypto.timingSafeEqual(got, want);
}

export async function GET(req) {
  if (!process.env.CRON_SECRET) return reply(503, { error: 'CRON_SECRET is not set' });
  if (!authorised(req)) return reply(401, { error: 'Not authorised' });
  if (!s3Enabled()) return reply(200, { skipped: 'Invoices are not on S3 in this environment' });
  const r = await runStorageCheck({ hub, listStored, deleteStored, store: storeName() });
  if (r.problems.length) console.error('storage check problems', r.problems.join(' | '));
  return reply(r.saved ? 200 : 502, {
    files: r.files, bytes: r.bytes, unlinked: r.unlinked, unlinkedRemoved: r.unlinkedRemoved,
    missing: r.missingCount, expiredRemoved: r.expiredRemoved, problems: r.problems.length, saved: r.saved,
  });
}
