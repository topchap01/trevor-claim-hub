import { hub, json, okToken } from '@/lib/sf';
import { remember } from '@/lib/returning';
export const dynamic = 'force-dynamic';
export async function GET(_req, { params: paramsP }) {
  const params = await paramsP;
  if (!okToken(params.token)) return json({ status: 404, data: { error: 'expired' } });
  const result = await hub(`claims/${params.token}`);
  const res = json(result);
  // Opening a claim link (from an email, on any phone) remembers that claim there too, replacing an older link
  return result.status === 200 ? remember(res, result.data?.slug, params.token) : res;
}
