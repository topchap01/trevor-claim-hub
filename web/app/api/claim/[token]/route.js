import { hub, json, okToken } from '@/lib/sf';
export const dynamic = 'force-dynamic';
export async function GET(_req, { params: paramsP }) {
  const params = await paramsP;
  if (!okToken(params.token)) return json({ status: 404, data: { error: 'expired' } });
  return json(await hub(`claims/${params.token}`));
}
