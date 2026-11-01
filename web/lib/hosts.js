// Campaign addresses on the hub's own domain (decisions.md #16).
//
// A campaign lives at <brand>.<root>/<campaign>, for example aeg.entryform.claims/nz-cashback.
// Its Salesforce slug is "<brand>-<campaign>" (aeg-nz-cashback), so the brand comes from the host
// and the slug is rebuilt from the host and the path. A brand's subdomain can only ever show that
// brand's campaigns: another brand's slug on it is not found.
//
// The root comes from HUB_ROOT_DOMAIN (test.entryform.claims in the sandbox, entryform.claims in
// production). Any other host (the bare root, *.vercel.app, a campaign's own domain) keeps the plain
// /<slug> addresses, so nothing that worked before stops working.

const LABEL = /^[a-z0-9](?:[a-z0-9-]{0,30}[a-z0-9])?$/;
const SLUG = /^[a-z0-9-]{3,60}$/;

/** First path segments that belong to the hub itself, on every host. */
export const HUB_PATHS = new Set(['api', 'c', 'designs', '_next', 'favicon.ico', 'robots.txt', 'sitemap.xml']);

/** Subdomains that are never a brand. */
const NOT_BRANDS = new Set(['www', 'api', 'admin', 'mail', 'test', 'staging']);

function hostname(host) {
  return String(host || '').trim().toLowerCase().replace(/:\d+$/, '').replace(/\.$/, '');
}

/** The brand for a host such as aeg.entryform.claims, or null when the host is not a brand subdomain of root. */
export function brandOf(host, root) {
  const h = hostname(host);
  const r = hostname(root);
  if (!r || !h.endsWith('.' + r)) return null;
  const label = h.slice(0, -(r.length + 1));
  return LABEL.test(label) && !NOT_BRANDS.has(label) ? label : null;
}

/** The public address of a campaign: https://<brand>.<root>/<campaign>. */
export function campaignUrl(brand, slug, root) {
  if (!LABEL.test(brand || '') || !String(slug || '').startsWith(brand + '-') || !hostname(root)) return null;
  return `https://${brand}.${hostname(root)}/${slug.slice(brand.length + 1)}`;
}

/**
 * What to do with a request. Returns one of:
 *   { action: 'next' }                       serve as normal
 *   { action: 'rewrite', pathname }          serve this internal path, keep the address bar
 *   { action: 'redirect', pathname }         send the browser to this path on the same host (permanent)
 *   { action: 'notFound' }                   another brand's campaign, or an address that cannot be one
 */
export function route(host, pathname, root) {
  const brand = brandOf(host, root);
  if (!brand) return { action: 'next' };

  const parts = String(pathname || '/').split('/').filter(Boolean);
  if (parts.length === 0) return { action: 'next' };
  const prefix = brand + '-';

  if (HUB_PATHS.has(parts[0])) {
    // Campaign data and design files on a brand's subdomain: that brand's campaigns only
    if (parts[0] === 'designs' || (parts[0] === 'api' && parts[1] === 'campaign')) {
      const slug = parts[0] === 'designs' ? parts[1] : parts[2];
      if (slug && !slug.startsWith(prefix)) return { action: 'notFound' };
    }
    return { action: 'next' };
  }

  if (parts.length > 1) return { action: 'notFound' };
  const seg = parts[0];
  // The full slug on its own brand's subdomain: send it to the short address
  if (seg.startsWith(prefix) && SLUG.test(seg) && seg.length > prefix.length) {
    return { action: 'redirect', pathname: '/' + seg.slice(prefix.length) };
  }
  const slug = prefix + seg;
  if (!SLUG.test(slug)) return { action: 'notFound' };
  return { action: 'rewrite', pathname: '/' + slug };
}
