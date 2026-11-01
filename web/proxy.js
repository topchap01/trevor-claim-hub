import { NextResponse } from 'next/server';
import { route } from '@/lib/hosts';

// Serves <brand>.<HUB_ROOT_DOMAIN>/<campaign> from the campaign's page (lib/hosts.js, decisions.md #16).
export function proxy(request) {
  const root = process.env.HUB_ROOT_DOMAIN;
  if (!root) return NextResponse.next();
  const host = request.headers.get('x-forwarded-host') || request.headers.get('host');
  const r = route(host, request.nextUrl.pathname, root);
  if (r.action === 'next') return NextResponse.next();
  if (r.action === 'notFound') return new NextResponse('Not found', { status: 404, headers: { 'Content-Type': 'text/plain' } });
  const url = request.nextUrl.clone();
  url.pathname = r.pathname;
  return r.action === 'redirect' ? NextResponse.redirect(url, 308) : NextResponse.rewrite(url);
}

export const config = {
  // Static build files never need routing
  matcher: ['/((?!_next/static|_next/image).*)'],
};
