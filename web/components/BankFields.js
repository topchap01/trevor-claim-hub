'use client';

import { useEffect, useState } from 'react';
import { bankPrefix, bankLine } from '@/lib/client';

/**
 * Bank account inputs in the claimant's country format. value: { name, bsb, account }
 * Once the bank and branch digits are in, shows the bank and branch back (from the Payments NZ or AusPayNet register),
 * so the claimant can see a wrong BSB or bank code before they submit. The full check runs in Salesforce on submit.
 */
export default function BankFields({ country, value, onChange, idPrefix = 'b' }) {
  const set = (patch) => onChange({ ...value, ...patch });
  const prefix = bankPrefix(country, value);
  const [found, setFound] = useState(null); // { prefix, result }

  useEffect(() => {
    if (!prefix) return undefined;
    let live = true;
    const t = setTimeout(async () => {
      try {
        const res = await fetch(`/api/bank/${country}/${prefix}`, { cache: 'no-store' });
        const result = res.ok ? await res.json() : null;
        if (live) setFound({ prefix, result });
      } catch {
        if (live) setFound({ prefix, result: null }); // the lookup is a help, not a gate
      }
    }, 250);
    return () => { live = false; clearTimeout(t); };
  }, [country, prefix]);

  const line = prefix && found?.prefix === prefix ? bankLine(country, found.result) : null;
  const lineEl = line && (
    <p className={line.ok ? 'muted' : 'note'} style={{ margin: '6px 0 0' }} aria-live="polite">{line.text}</p>
  );

  return (
    <>
      <label htmlFor={`${idPrefix}-n`}>Account name</label>
      <input id={`${idPrefix}-n`} type="text" autoComplete="off" value={value.name} onChange={(e) => set({ name: e.target.value })} />
      {country === 'NZ' ? (
        <>
          <label htmlFor={`${idPrefix}-a`}>Account number</label>
          <input id={`${idPrefix}-a`} type="text" inputMode="numeric" autoComplete="off" placeholder="12-3140-0234566-00" value={value.account} onChange={(e) => set({ account: nzFormat(e.target.value), bsb: '' })} />
          <p className="muted" style={{ margin: '4px 0 0' }}>Bank, branch, account and suffix: 15 or 16 digits, as shown on your statement or banking app.</p>
          {lineEl}
        </>
      ) : (
        <>
          <div className="row2">
            <div><label htmlFor={`${idPrefix}-b`}>BSB</label><input id={`${idPrefix}-b`} type="text" inputMode="numeric" autoComplete="off" placeholder="000-000" value={value.bsb} onChange={(e) => set({ bsb: e.target.value })} /></div>
            <div><label htmlFor={`${idPrefix}-a`}>Account number</label><input id={`${idPrefix}-a`} type="text" inputMode="numeric" autoComplete="off" value={value.account} onChange={(e) => set({ account: e.target.value })} /></div>
          </div>
          {lineEl}
        </>
      )}
    </>
  );
}

/** 12-3456-7890123-00 as the person types. */
function nzFormat(v) {
  const d = v.replace(/\D/g, '').slice(0, 16);
  const parts = [d.slice(0, 2), d.slice(2, 6), d.slice(6, 13), d.slice(13)].filter(Boolean);
  return parts.join('-');
}
