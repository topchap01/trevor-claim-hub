// Uptime check: 200 when the web app can sign in to Salesforce and the hub reports no problems, 503 otherwise.
// Returns counts only, no personal data. Point an uptime monitor at it every minute.
import { hub } from '@/lib/sf';

export const dynamic = 'force-dynamic';

export async function GET() {
  const started = Date.now();
  const r = await hub('health');
  const body = {
    ok: r.status === 200 && r.data.ok === true,
    salesforce: r.status === 200 ? 'reachable' : `error ${r.status}`,
    responseMs: Date.now() - started,
    problems: r.status === 200 ? (r.data.problems || []).length : null, // counts only; details are in Salesforce
  };
  return new Response(JSON.stringify(body), {
    status: body.ok ? 200 : 503,
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });
}
