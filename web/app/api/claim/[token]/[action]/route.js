import { hub, json, okToken, readJson, bad, clientIp } from '@/lib/sf';
import { blobEnabled, storeInvoice, removeFile } from '@/lib/files';

export const dynamic = 'force-dynamic';
export const maxDuration = 60;

// Exactly the fields each action may send. Anything else from the browser (fileKey above all) is dropped.
const FIELDS = {
  serial: ['productId', 'serial', 'pnc'],
  receipt: ['base64', 'contentType', 'fileName'],
  plate: ['base64', 'contentType'],
  code: [],
  bank: ['code', 'name', 'bsb', 'account'],
  chat: ['messages'],
};

export async function POST(req, { params: paramsP }) {
  const params = await paramsP;
  const allowed = FIELDS[params.action];
  if (!okToken(params.token) || !allowed) return bad('Not found', 404);
  // Photos are shrunk on the phone to well under 2 MB; base64 adds a third
  const raw = await readJson(req, params.action === 'receipt' || params.action === 'plate' ? 3_000_000 : 64_000);
  if (!raw) return bad('That request was too large or not valid.', 413);
  const body = Object.fromEntries(allowed.filter((k) => raw[k] !== undefined).map((k) => [k, raw[k]]));
  if ((params.action === 'receipt' || params.action === 'plate') && typeof body.base64 !== 'string') return bad();
  if (params.action === 'chat') body.messages = Array.isArray(body.messages) ? body.messages.slice(-12) : [];

  let fileKey;
  if (params.action === 'receipt' && blobEnabled()) {
    try { fileKey = await storeInvoice(params.token, body.base64, body.contentType || 'image/jpeg'); }
    catch (err) {
      if (err.status) return bad(err.message, err.status);
      console.error('invoice store failed', err.message);
      return bad('We couldn\'t save your invoice just now. Please try again.', 503);
    }
    body.fileKey = fileKey;
  }

  const result = await hub(`claims/${params.token}/${params.action}`, { method: 'POST', body, ip: clientIp(req) });
  // Remove the file only when Salesforce definitely refused it. On a timeout or 5xx it may still have been saved,
  // so the file stays (an unreferenced file costs a few cents; a claim pointing at a deleted file loses the invoice).
  if (fileKey && result.status >= 400 && result.status < 500) await removeFile(fileKey);
  return json(result);
}
