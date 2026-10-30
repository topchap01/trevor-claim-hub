import { Suspense } from 'react';
import Hub from './Hub';
export const dynamic = 'force-dynamic';
export default function ClaimPage() {
  return <Suspense fallback={<div className="wrap"><p className="muted" style={{ marginTop: 24 }}>Loading your claim…</p></div>}><Hub /></Suspense>;
}
