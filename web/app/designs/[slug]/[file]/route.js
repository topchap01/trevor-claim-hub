import { designAsset } from '@/lib/designs';

// Serves a campaign design's images and fonts from the hub's own address, so the content security
// policy can stay 'self' and emails can link to the logo.
export async function GET(req, { params }) {
  const { slug, file } = await params;
  const asset = await designAsset(slug, file);
  if (!asset) return new Response('Not found', { status: 404 });
  const headers = {
    'Content-Type': asset.type,
    'Cache-Control': 'public, max-age=300, s-maxage=86400, stale-while-revalidate=604800',
    'X-Content-Type-Options': 'nosniff',
  };
  // An SVG opened on its own could run script; this keeps it inert
  if (asset.type === 'image/svg+xml') headers['Content-Security-Policy'] = "default-src 'none'; style-src 'unsafe-inline'; sandbox";
  return new Response(asset.body, { headers });
}
