import { hub, json, okSlug, readJson, bad, clientIp } from '@/lib/sf';
export const dynamic = 'force-dynamic';
export async function POST(req) {
  const body = await readJson(req, 4_000);
  if (!body || !okSlug(body.slug) || typeof body.email !== 'string' || body.email.length > 120) return bad();
  return json(await hub('resend', { method: 'POST', body: { slug: body.slug, email: body.email }, ip: clientIp(req) }));
}
