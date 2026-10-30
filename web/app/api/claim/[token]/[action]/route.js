import { hub, json, okToken, readJson, bad, clientIp } from '@/lib/sf';
import { blobEnabled, storeInvoice, removeFile } from '@/lib/files';

export const dynamic = 'force-dynamic';
export const maxDuration = 60;

const ACTIONS = new Set(['serial', 'receipt', 'plate', 'code', 'bank', 'chat']);
const UPLOADS = new Set(['receipt', 'plate']);

export async function POST(req, { params: paramsP }) {
  const params = await paramsP;
  if (!okToken(params.token) || !ACTIONS.has(params.action)) return bad('Not found', 404);
  // Photos are shrunk on the phone to well under 2 MB; base64 adds a third
  const body = await readJson(req, UPLOADS.has(params.action) ? 3_000_000 : 64_000);
  if (!body) return bad('That request was too large or not valid.', 413);

  let fileKey;
  if (params.action === 'receipt' && blobEnabled() && typeof body.base64 === 'string') {
    try { fileKey = await storeInvoice(params.token, body.base64, body.contentType || 'image/jpeg'); }
    catch (err) {
      if (err.status) return bad(err.message, err.status);
      console.error('invoice store failed', err.message);
      return bad('We couldn\'t save your invoice just now. Please try again.', 503);
    }
    body.fileKey = fileKey;
  }

  const result = await hub(`claims/${params.token}/${params.action}`, { method: 'POST', body, ip: clientIp(req) });
  // Salesforce refused or failed: don't keep a file nothing points to
  if (fileKey && result.status !== 200) await removeFile(fileKey);
  return json(result);
}
