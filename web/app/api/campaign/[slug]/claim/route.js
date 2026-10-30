import { hub, json, okSlug, readJson, bad, clientIp } from '@/lib/sf';
export const dynamic = 'force-dynamic';
export const maxDuration = 60;
export async function POST(req, { params: paramsP }) {
  const params = await paramsP;
  if (!okSlug(params.slug)) return bad('Not found', 404);
  const body = await readJson(req);
  if (!body) return bad();
  return json(await hub(`campaigns/${params.slug}/claims`, { method: 'POST', body, ip: clientIp(req) }));
}
