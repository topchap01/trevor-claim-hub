import { Suspense } from 'react';
import Hub from './Hub';
import { loadDesign, themeVars } from '@/lib/designs';
export const dynamic = 'force-dynamic';

// The claim link carries the campaign (s=slug), so the private claim page wears that campaign's look,
// whichever address it is opened on.
async function themeFor(searchParams) {
  const s = (await searchParams)?.s;
  return (await loadDesign(typeof s === 'string' ? s : ''))?.theme || null;
}

export async function generateMetadata({ searchParams }) {
  const t = await themeFor(searchParams);
  return {
    title: t?.title ? `Your claim · ${t.title}` : 'Your claim',
    ...(t?.favicon || t?.appleIcon ? { icons: { icon: t.favicon, apple: t.appleIcon } } : {}),
  };
}

export default async function ClaimPage({ searchParams }) {
  const t = await themeFor(searchParams);
  const hub = <Suspense fallback={<div className="wrap"><p className="muted" style={{ marginTop: 24 }}>Loading your claim…</p></div>}><Hub /></Suspense>;
  if (!t) return hub;
  return (
    <div className="themed" style={themeVars(t)}>
      {/* A small logo from the hub's own asset route; next/image would add an optimiser for one file */}
      {/* eslint-disable-next-line @next/next/no-img-element */}
      {t.logo && <div className="brandbar"><img src={t.logo} alt={t.logoAlt || ''} height="36" /></div>}
      {hub}
    </div>
  );
}
