import { hub, json, okSlug } from '@/lib/sf';
export const dynamic = 'force-dynamic';
export async function GET(_req, { params: paramsP }) {
  const params = await paramsP;
  if (!okSlug(params.slug)) return json({ status: 404, data: { error: 'Not found' } });
  return json(await hub(`campaigns/${params.slug}`));
}
