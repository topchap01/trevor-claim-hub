// Server-only: invoice files in private Vercel Blob storage (not Salesforce Files, whose storage is full).
// Turned on by the BLOB_READ_WRITE_TOKEN environment variable; without it, files go to Salesforce as before.
import crypto from 'node:crypto';
import { put, get, del } from '@vercel/blob';

export const blobEnabled = () => !!process.env.BLOB_READ_WRITE_TOKEN;

const TYPES = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp', 'image/heic': 'heic', 'application/pdf': 'pdf' };

/** Stores the file privately. The path holds a hash of the claim link, never the link itself. Returns the storage key. */
export async function storeInvoice(token, base64, contentType) {
  const ext = TYPES[contentType];
  if (!ext) throw Object.assign(new Error('Please upload a photo (JPEG or PNG) or a PDF.'), { status: 415 });
  const folder = crypto.createHash('sha256').update(token).digest('hex').slice(0, 24);
  const blob = await put(`invoices/${folder}/invoice.${ext}`, Buffer.from(base64, 'base64'), {
    access: 'private', contentType, addRandomSuffix: true,
  });
  return blob.pathname;
}

export async function removeFile(key) {
  try { await del(key); } catch (err) { console.error('blob delete failed', err.message); }
}

export async function readFile(key) {
  return get(key, { access: 'private' });
}
