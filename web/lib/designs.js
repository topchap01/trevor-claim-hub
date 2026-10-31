// Each campaign's own look (decisions.md #10).
//
// A design is a folder per campaign slug:
//   page.html   the entry page body, written by the studio. Hub blocks go where the page puts
//               <hub-slot name="claim-form"></hub-slot> (see SLOTS). {{placeholders}} are filled
//               from the campaign record, so dates and amounts on the page never disagree with the rules.
//   style.css   the page's styles.
//   theme.json  colours, font, logo and icons, also used on the private claim pages.
//   images and fonts, referenced by plain file name (banner.webp).
//
// Designs are untrusted input: scripts, event handlers, forms, frames and off-site styles are
// stripped, because the same page takes bank details. In the sandbox the folders live in
// web/designs/; production reads them from the public asset store (roadmap, Phase 2).
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import sanitizeHtml from 'sanitize-html';

export const SLOTS = ['claim-form', 'resend', 'how-it-works', 'tiers', 'key-dates', 'terms'];
export const PLACEHOLDERS = ['name', 'headline', 'brandName', 'retailers', 'supportEmail', 'purchaseFrom', 'purchaseTo', 'claimsClose', 'minSpend', 'maxCashback'];

const ROOT = path.join(process.cwd(), 'designs');
const okSlug = (s) => typeof s === 'string' && /^[a-z0-9-]{3,80}$/.test(s);
const okFile = (f) => typeof f === 'string' && /^[a-z0-9][a-z0-9_-]{0,80}\.[a-z0-9]{2,5}$/i.test(f);

export const ASSET_TYPES = {
  png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', webp: 'image/webp', avif: 'image/avif',
  gif: 'image/gif', svg: 'image/svg+xml', ico: 'image/x-icon', woff2: 'font/woff2', woff: 'font/woff',
};

const COLOR = /^#[0-9a-f]{3,8}$/i;
const FONT = /^[\w\s"',-]{1,200}$/;

const cache = new Map(); // slug -> { at, design }

/** The campaign's design, or null when it has none. Cached for 60 seconds per instance. */
export async function loadDesign(slug) {
  if (!okSlug(slug)) return null;
  const hit = cache.get(slug);
  if (hit && Date.now() - hit.at < 60_000) return hit.design;
  let design = null;
  try {
    const dir = path.join(ROOT, slug);
    const [html, css, theme] = await Promise.all([
      readFile(path.join(dir, 'page.html'), 'utf8'),
      readFile(path.join(dir, 'style.css'), 'utf8').catch(() => ''),
      readFile(path.join(dir, 'theme.json'), 'utf8').then(JSON.parse).catch(() => ({})),
    ]);
    design = { html: cleanHtml(html, slug), css: cleanCss(css, slug), theme: cleanTheme(theme, slug) };
  } catch (e) {
    if (e.code !== 'ENOENT') console.error('design load failed', slug, e.message);
  }
  cache.set(slug, { at: Date.now(), design });
  return design;
}

/** One image or font from a campaign's design folder, for the asset route. */
export async function designAsset(slug, file) {
  if (!okSlug(slug) || !okFile(file)) return null;
  const type = ASSET_TYPES[file.split('.').pop().toLowerCase()];
  if (!type) return null;
  try {
    return { body: await readFile(path.join(ROOT, slug, file)), type };
  } catch {
    return null;
  }
}

const assetUrl = (slug, f) => `/designs/${slug}/${f}`;

/** Relative file names become the hub's asset route; anything else off-site is dropped. */
function localUrl(value, slug) {
  const v = String(value || '').trim();
  if (okFile(v)) return assetUrl(slug, v);
  return null;
}

function safeHref(value) {
  const v = String(value || '').trim();
  if (/^(https:\/\/|mailto:|tel:|#)/i.test(v)) return v;
  return null;
}

export function cleanHtml(html, slug) {
  return sanitizeHtml(html, {
    allowedTags: [
      'header', 'nav', 'main', 'section', 'article', 'aside', 'footer', 'div', 'span', 'p', 'br', 'hr',
      'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'strong', 'b', 'em', 'i', 'u', 'small', 'sup', 'sub',
      'ul', 'ol', 'li', 'dl', 'dt', 'dd', 'a', 'img', 'picture', 'source', 'figure', 'figcaption',
      'table', 'thead', 'tbody', 'tr', 'th', 'td', 'blockquote', 'hub-slot',
    ],
    allowedAttributes: {
      '*': ['class', 'id', 'aria-label', 'aria-hidden', 'role', 'title', 'lang'],
      a: ['href', 'target', 'rel'],
      img: ['src', 'srcset', 'alt', 'width', 'height', 'loading', 'decoding'],
      source: ['srcset', 'media', 'type', 'width', 'height'],
      'hub-slot': ['name'],
      td: ['colspan', 'rowspan'], th: ['colspan', 'rowspan', 'scope'],
    },
    allowedSchemes: ['https', 'mailto', 'tel'],
    allowProtocolRelative: false,
    disallowedTagsMode: 'discard',
    transformTags: {
      a: (tag, attribs) => {
        const href = safeHref(attribs.href);
        const out = { ...attribs };
        if (href) out.href = href; else delete out.href;
        if (out.target === '_blank') out.rel = 'noopener noreferrer'; else delete out.target;
        return { tagName: 'a', attribs: out };
      },
      img: (tag, attribs) => {
        const out = { ...attribs, src: localUrl(attribs.src, slug) || '' };
        if (attribs.srcset) out.srcset = srcset(attribs.srcset, slug); else delete out.srcset;
        if (!out.srcset) delete out.srcset;
        return { tagName: 'img', attribs: out };
      },
      source: (tag, attribs) => ({ tagName: 'source', attribs: { ...attribs, srcset: srcset(attribs.srcset, slug) } }),
      'hub-slot': (tag, attribs) => ({ tagName: 'hub-slot', attribs: SLOTS.includes(attribs.name) ? { name: attribs.name } : {} }),
    },
    exclusiveFilter: (frame) => (frame.tag === 'img' && !frame.attribs.src) || (frame.tag === 'hub-slot' && !frame.attribs.name),
  });
}

function srcset(value, slug) {
  return String(value || '').split(',').map((part) => {
    const [file, size] = part.trim().split(/\s+/);
    const url = localUrl(file, slug);
    return url && (!size || /^\d+(\.\d+)?[wx]$/.test(size)) ? [url, size].filter(Boolean).join(' ') : null;
  }).filter(Boolean).join(', ');
}

/** Styles may only point at the design's own files: no @import, no off-site url(), no legacy script hooks. */
export function cleanCss(css, slug) {
  return String(css)
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/@import[^;]*;?/gi, '')
    .replace(/url\(\s*(['"]?)([^'")]*)\1\s*\)/gi, (m, q, f) => {
      const url = localUrl(f, slug);
      return url ? `url("${url}")` : 'none';
    })
    .replace(/expression\s*\(|behavior\s*:|-moz-binding/gi, '')
    .replace(/<\/?(style|script)/gi, '');
}

export function cleanTheme(t, slug) {
  const c = t.colors || {};
  const pick = (v) => (typeof v === 'string' && COLOR.test(v) ? v : undefined);
  return {
    title: typeof t.title === 'string' ? t.title.slice(0, 120) : undefined,
    colors: {
      brand: pick(c.brand), brandInk: pick(c.brandInk), accent: pick(c.accent), button: pick(c.button), buttonInk: pick(c.buttonInk),
      bg: pick(c.bg), ink: pick(c.ink),
    },
    font: typeof t.font === 'string' && FONT.test(t.font) ? t.font : undefined,
    logo: localUrl(t.logo, slug) || undefined,
    logoAlt: typeof t.logoAlt === 'string' ? t.logoAlt.slice(0, 80) : undefined,
    favicon: localUrl(t.favicon, slug) || undefined,
    appleIcon: localUrl(t.appleIcon, slug) || undefined,
  };
}

/** CSS variables that carry the campaign's look onto the hub's own blocks. */
export function themeVars(theme) {
  const c = theme?.colors || {};
  const v = {};
  if (c.brand) v['--campaign-brand'] = c.brand;
  if (c.brand) v['--brand'] = c.brand;
  if (c.brandInk) v['--brand-ink'] = c.brandInk;
  if (c.accent) v['--accent'] = c.accent;
  if (c.button) v['--btn'] = c.button;
  if (c.buttonInk) v['--btn-ink'] = c.buttonInk;
  if (c.bg) v['--bg'] = c.bg;
  if (c.ink) v['--ink'] = c.ink;
  if (theme?.font) v.fontFamily = theme.font;
  return v;
}

const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]));

/** Fills {{placeholders}} after sanitising, escaping every value. Unknown names are left out. */
export function fill(html, values) {
  return html.replace(/\{\{\s*([a-zA-Z]+)\s*\}\}/g, (m, k) => (PLACEHOLDERS.includes(k) ? esc(values[k]) : ''));
}
