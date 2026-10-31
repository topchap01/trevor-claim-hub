// Bank and branch for the first six digits of a bank number (NZ bank and branch, or an AU BSB), so the claim form
// can show them back as the claimant types. Register data only: no account number or personal data is sent.
import { hub, json, bad } from '@/lib/sf';

export const dynamic = 'force-dynamic';

const cache = new Map(); // "NZ123140" -> { at, result }: the registers change monthly; spares the org's API allowance
const TTL_MS = 12 * 60 * 60_000;
const MAX = 5_000;

export async function GET(_req, { params: paramsP }) {
  const params = await paramsP;
  const country = String(params.country || '').toUpperCase();
  const code = String(params.code || '');
  if (!['NZ', 'AU'].includes(country) || !/^[0-9]{6}$/.test(code)) return bad();
  const key = country + code;
  const hit = cache.get(key);
  if (hit && Date.now() - hit.at < TTL_MS) return json(hit.result);
  const result = await hub(`banks/${country}/${code}`);
  if (result.status === 200) {
    if (cache.size >= MAX) cache.delete(cache.keys().next().value);
    cache.set(key, { at: Date.now(), result });
  }
  return json(result);
}
