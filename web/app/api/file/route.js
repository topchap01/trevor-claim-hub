// Staff invoice viewer. Salesforce issues a ten-minute ticket (ClaimHubFiles.invoiceLink); this route asks Salesforce
// which file the ticket opens and streams it from private storage. No ticket, no file.
import { hub } from '@/lib/sf';
import { readFile } from '@/lib/files';

export const dynamic = 'force-dynamic';

const notFound = () => new Response('This link has expired. Open the invoice again from Salesforce.', {
  status: 404, headers: { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' },
});

export async function GET(req) {
  const t = new URL(req.url).searchParams.get('t');
  if (!t || !/^[A-Za-z0-9_-]{40,64}$/.test(t)) return notFound();
  const r = await hub(`files/${t}`);
  if (r.status !== 200 || !r.data.key) return notFound();
  const file = await readFile(r.data.key).catch(() => null);
  if (!file || file.statusCode !== 200) return notFound();
  return new Response(file.stream, {
    headers: {
      'Content-Type': file.blob.contentType || 'application/octet-stream',
      'Content-Disposition': 'inline',
      'Cache-Control': 'private, no-store',
      'X-Robots-Tag': 'noindex',
    },
  });
}
