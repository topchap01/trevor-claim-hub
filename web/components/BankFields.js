'use client';

/** Bank account inputs in the claimant's country format. value: { name, bsb, account } */
export default function BankFields({ country, value, onChange, idPrefix = 'b' }) {
  const set = (patch) => onChange({ ...value, ...patch });
  return (
    <>
      <label htmlFor={`${idPrefix}-n`}>Account name</label>
      <input id={`${idPrefix}-n`} type="text" autoComplete="off" value={value.name} onChange={(e) => set({ name: e.target.value })} />
      {country === 'NZ' ? (
        <>
          <label htmlFor={`${idPrefix}-a`}>Account number</label>
          <input id={`${idPrefix}-a`} type="text" inputMode="numeric" autoComplete="off" placeholder="12-3456-7890123-00" value={value.account} onChange={(e) => set({ account: nzFormat(e.target.value), bsb: '' })} />
          <p className="muted" style={{ margin: '4px 0 0' }}>Bank, branch, account and suffix: 15 or 16 digits, as shown on your statement or banking app.</p>
        </>
      ) : (
        <div className="row2">
          <div><label htmlFor={`${idPrefix}-b`}>BSB</label><input id={`${idPrefix}-b`} type="text" inputMode="numeric" autoComplete="off" placeholder="000-000" value={value.bsb} onChange={(e) => set({ bsb: e.target.value })} /></div>
          <div><label htmlFor={`${idPrefix}-a`}>Account number</label><input id={`${idPrefix}-a`} type="text" inputMode="numeric" autoComplete="off" value={value.account} onChange={(e) => set({ account: e.target.value })} /></div>
        </div>
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
