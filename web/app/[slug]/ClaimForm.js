'use client';
import { useMemo, useState } from 'react';
import { useRouter } from 'next/navigation';
import { api, money, bestTier } from '@/lib/client';
import BankFields from '@/components/BankFields';

const blankRow = () => ({ id: Math.random().toString(36).slice(2), promoProductId: '', price: '' });

export default function ClaimForm({ campaign }) {
  const router = useRouter();
  const min = campaign.minProducts || 1, max = campaign.maxProducts || 6;
  const [rows, setRows] = useState(Array.from({ length: Math.max(min, 2) }, blankRow));
  const [me, setMe] = useState({ firstName: '', lastName: '', email: '', mobile: '' });
  const [addBank, setAddBank] = useState(true);
  const [bank, setBank] = useState({ name: '', bsb: '', account: '' });
  const [agree, setAgree] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  const byCategory = useMemo(() => {
    const m = {};
    for (const p of campaign.products) (m[p.category] ||= []).push(p);
    return m;
  }, [campaign.products]);

  const chosen = rows.filter((r) => r.promoProductId);
  const bySpend = !!campaign.needsPrices;
  const spend = chosen.reduce((a, r) => a + (Number(r.price) || 0), 0);
  const cur = (n) => money(n, campaign.country);
  const tier = bestTier(campaign.tiers, chosen.length, spend, min, campaign.maxCashback);
  const shortBy = campaign.minSpend && spend < campaign.minSpend ? campaign.minSpend - spend : 0;

  const setRow = (id, patch) => setRows((rs) => rs.map((r) => (r.id === id ? { ...r, ...patch } : r)));

  async function submit(e) {
    e.preventDefault();
    setError('');
    if (chosen.length < min) return setError(`Choose at least ${min} participating appliances.`);
    if (bySpend && chosen.some((r) => !(Number(r.price) > 0))) return setError('Add the price you paid for each appliance. The cashback depends on your total spend.');
    if (shortBy) return setError(`This promotion needs a combined spend of at least ${cur(campaign.minSpend)}. Your total is ${cur(spend)}.`);
    if (!agree) return setError('Please confirm you have read the terms.');
    setBusy(true);
    try {
      const out = await api(`campaign/${campaign.slug}/claim`, {
        ...me,
        products: chosen.map((r) => ({ promoProductId: r.promoProductId, price: r.price || null })),
        bank: addBank ? bank : null,
      });
      router.push(`/c?token=${encodeURIComponent(out.token)}&new=1`);
    } catch (err) {
      setError(err.message);
      setBusy(false);
    }
  }

  return (
    <form className="card" onSubmit={submit} noValidate>
      <h2>Make a claim</h2>
      <p className="sub">You can add your invoice and serial numbers after you submit.</p>

      <label>What did you buy?</label>
      {rows.map((r, i) => (
        <div className="prod" key={r.id}>
          <div>
            <select aria-label={`Appliance ${i + 1}`} value={r.promoProductId} onChange={(e) => setRow(r.id, { promoProductId: e.target.value })}>
              <option value="">Choose appliance {i + 1}</option>
              {Object.entries(byCategory).map(([cat, items]) => (
                <optgroup key={cat} label={cat}>
                  {items.map((p) => <option key={p.id} value={p.id}>{p.model} · {p.name}</option>)}
                </optgroup>
              ))}
            </select>
          </div>
          <div><input aria-label={`Price paid for appliance ${i + 1}`} type="number" inputMode="decimal" placeholder={campaign.country === 'NZ' ? 'Price NZ$' : 'Price $'} value={r.price} onChange={(e) => setRow(r.id, { price: e.target.value })} /></div>
          <button type="button" className="iconbtn" aria-label={`Remove appliance ${i + 1}`} disabled={rows.length <= min} onClick={() => setRows((rs) => rs.filter((x) => x.id !== r.id))}>×</button>
        </div>
      ))}
      {rows.length < max && <div style={{ marginTop: 10 }}><button type="button" className="btn ghost small" onClick={() => setRows((rs) => [...rs, blankRow()])}>+ Add another appliance</button></div>}
      <div className="total">
        <span className="muted">{chosen.length} appliance{chosen.length === 1 ? '' : 's'}{bySpend ? `, total ${cur(spend)}` : ' chosen'}</span>
        <b>{tier && (!bySpend || spend > 0) ? `${cur(tier.pays)} cashback${tier.percent ? ` (${tier.percent}%)` : ''}` : chosen.length < min ? `Choose ${min}+ to qualify` : shortBy ? `${cur(shortBy)} more to qualify` : 'Add prices to see your cashback'}</b>
      </div>
      {(campaign.retailers || campaign.singleTransaction) && <p className="muted" style={{ margin: '6px 0 0' }}>{[campaign.retailers && `Bought from ${campaign.retailers}`, campaign.singleTransaction && 'all on one invoice'].filter(Boolean).join(', ')}. Use the price on your invoice after any discount.</p>}

      <div className="row2">
        <div><label htmlFor="fn">First name</label><input id="fn" type="text" autoComplete="given-name" required value={me.firstName} onChange={(e) => setMe({ ...me, firstName: e.target.value })} /></div>
        <div><label htmlFor="ln">Last name</label><input id="ln" type="text" autoComplete="family-name" required value={me.lastName} onChange={(e) => setMe({ ...me, lastName: e.target.value })} /></div>
      </div>
      <label htmlFor="em">Email</label>
      <input id="em" type="email" autoComplete="email" required value={me.email} onChange={(e) => setMe({ ...me, email: e.target.value })} />
      <p className="muted" style={{ margin: '4px 0 0' }}>We send your private claim link here. Use an inbox you can open.</p>
      <label htmlFor="mb">Mobile</label>
      <input id="mb" type="tel" autoComplete="tel" required value={me.mobile} onChange={(e) => setMe({ ...me, mobile: e.target.value })} />

      <label className="check" style={{ marginTop: 18 }}>
        <input type="checkbox" checked={addBank} onChange={(e) => setAddBank(e.target.checked)} />
        <span>Add bank details now, so we can pay you as soon as your claim is approved</span>
      </label>
      {addBank && (
        <div className="inline">
          <BankFields country={campaign.country} value={bank} onChange={setBank} idPrefix="cf" />
          <p className="muted" style={{ margin: '6px 0 0' }}>After today we only ever show the last 3 digits. Changing them later needs a security code.</p>
        </div>
      )}

      <label className="check" style={{ marginTop: 18 }}>
        <input type="checkbox" checked={agree} onChange={(e) => setAgree(e.target.checked)} />
        <span>I've read the terms below and I'm claiming for appliances I bought for my own home.</span>
      </label>

      {error && <div className="err" role="alert">{error}</div>}
      <div style={{ marginTop: 16 }}><button className="btn block" disabled={busy}>{busy ? <span><span className="spinner" /> Sending your claim…</span> : 'Submit my claim'}</button></div>
    </form>
  );
}
