// Server-only: signs in to Salesforce as the hub's API-only integration user (OAuth 2.0 JWT bearer)
// and calls the claim hub API (Apex REST, ClaimHubApi). Claimants' browsers never talk to Salesforce.
import crypto from 'node:crypto';

const TIMEOUT_MS = 55_000; // under the route's 60 s limit, so a slow Salesforce call fails cleanly
let cached = null; // { token, instance, exp } – per server instance, refreshed on 401

function b64url(input) {
  return Buffer.from(input).toString('base64').replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
}

function required(name) {
  const v = process.env[name];
  if (!v) throw new Error(`Missing environment variable ${name}`);
  return v;
}

async function accessToken() {
  if (cached && cached.exp > Date.now() + 60_000) return cached;
  const header = b64url(JSON.stringify({ alg: 'RS256' }));
  const claims = b64url(JSON.stringify({
    iss: required('SF_CLIENT_ID'),
    sub: required('SF_USERNAME'),
    aud: process.env.SF_AUDIENCE || 'https://test.salesforce.com',
    exp: Math.floor(Date.now() / 1000) + 180,
  }));
  const key = required('SF_PRIVATE_KEY').replace(/\\n/g, '\n');
  const signature = crypto.createSign('RSA-SHA256').update(`${header}.${claims}`).sign(key);
  const res = await fetch(`${required('SF_LOGIN_URL')}/services/oauth2/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: `${header}.${claims}.${b64url(signature)}` }),
    cache: 'no-store',
    signal: AbortSignal.timeout(15_000),
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`Salesforce sign-in failed: ${json.error || res.status}`);
  cached = { token: json.access_token, instance: json.instance_url, exp: Date.now() + 50 * 60_000 };
  return cached;
}

/**
 * Calls the claim hub API. Never throws: Salesforce being down or slow comes back as a 503 the pages can show.
 * GETs are retried once on a network error; POSTs are not (they may have been applied).
 */
export async function hub(path, { method = 'GET', body, ip } = {}) {
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const { token, instance } = await accessToken();
      const headers = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
      if (ip) headers['X-Hub-Client-IP'] = ip;
      const res = await fetch(`${instance}/services/apexrest/claimhub/v1/${path}`, {
        method, headers, body: body ? JSON.stringify(body) : undefined, cache: 'no-store', signal: AbortSignal.timeout(TIMEOUT_MS),
      });
      if (res.status === 401 && attempt === 0) { cached = null; continue; }
      const text = await res.text();
      let data;
      try { data = JSON.parse(text); } catch { data = { error: 'Unexpected response' }; }
      if (res.status >= 500) console.error('claim hub API', method, redact(path), res.status, data.ref || '');
      return { status: res.status, data };
    } catch (err) {
      console.error('claim hub API unreachable', method, redact(path), err.name, err.message);
      if (method !== 'GET' || attempt === 1) {
        return { status: 503, data: { error: 'We can\'t reach our claims system right now. Please try again in a few minutes.' } };
      }
    }
  }
  return { status: 503, data: { error: 'We can\'t reach our claims system right now. Please try again in a few minutes.' } };
}

/** Claim link codes never go into logs. */
const redact = (p) => String(p).replace(/[A-Za-z0-9_-]{40,64}/g, '{token}');

const campaignCache = new Map(); // slug -> { at, result }: promotion details change rarely; spares the org's API allowance

/** Public promotion details, cached for 60 seconds per server instance. */
export async function campaign(slug) {
  const hit = campaignCache.get(slug);
  if (hit && Date.now() - hit.at < 60_000) return hit.result;
  const result = await hub(`campaigns/${slug}`);
  if (result.status === 200) campaignCache.set(slug, { at: Date.now(), result });
  return result;
}

export function json(result) {
  return new Response(JSON.stringify(result.data), {
    status: result.status,
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });
}

/** The caller's IP address as Vercel reports it (first hop of x-forwarded-for). */
export function clientIp(req) {
  const xff = req.headers.get('x-forwarded-for') || '';
  return xff.split(',')[0].trim() || req.headers.get('x-real-ip') || undefined;
}

/** Reads a JSON body up to a size limit. Returns null for anything else. */
export async function readJson(req, maxBytes = 64_000) {
  const len = Number(req.headers.get('content-length') || 0);
  if (len > maxBytes) return null;
  const text = await req.text().catch(() => null);
  if (text === null || text.length > maxBytes) return null;
  try {
    const v = JSON.parse(text);
    return v && typeof v === 'object' && !Array.isArray(v) ? v : null;
  } catch { return null; }
}

export const okToken = (t) => typeof t === 'string' && /^[A-Za-z0-9_-]{40,64}$/.test(t);
export const okSlug = (s) => typeof s === 'string' && /^[a-z0-9-]{3,80}$/.test(s);
export const bad = (error = 'Bad request', status = 400) => json({ status, data: { error } });
