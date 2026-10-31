import { hub, json, okSlug, readJson, bad, clientIp } from '@/lib/sf';
import { remember } from '@/lib/returning';
export const dynamic = 'force-dynamic';
export const maxDuration = 60;
export async function POST(req, { params: paramsP }) {
  const params = await paramsP;
  if (!okSlug(params.slug)) return bad('Not found', 404);
  const body = await readJson(req);
  if (!body) return bad();
  const result = await hub(`campaigns/${params.slug}/claims`, { method: 'POST', body, ip: clientIp(req) });
  const res = json(result);
  // Remember the new claim on this phone, so coming back to the promotion page offers "Open my claim"
  return result.status === 200 ? remember(res, params.slug, result.data?.token) : res;
}
