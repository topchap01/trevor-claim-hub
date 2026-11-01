'use client';
import { useMemo, useState } from 'react';
import { useRouter } from 'next/navigation';
import { api, money, bestTier, addressFor } from '@/lib/client';
import BankFields from '@/components/BankFields';
import { SendLinkButton } from './ResendForm';

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
  const [existing, setExisting] = useState(''); // the email a claim already exists for, so we offer its link in one tap
  // Postal address and store, when the campaign asks (decisions.md #13)
  const [addr, setAddr] = useState({ line: '', unit: '', suburb: '', postcode: '', state: '' });
  const [store, setStore] = useState({ retailer: '', name: '', suburb: '', state: '' });
  const nz = campaign.country === 'NZ';
  const stores = campaign.stores || [];
  const storeNamed = !stores.length || store.retailer === 'Other';

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
    setExisting('');
    if (chosen.length < min) return setError(`Choose at least ${min} participating appliances.`);
    if (bySpend && chosen.some((r) => !(Number(r.price) > 0))) return setError('Add the price you paid for each appliance. The cashback depends on your total spend.');
    if (shortBy) return setError(`This promotion needs a combined spend of at least ${cur(campaign.minSpend)}. Your total is ${cur(spend)}.`);
    let address = null;
    if (campaign.collectAddress) {
      const a = addressFor(addr, campaign.regions);
      if (a.error) return setError(a.error);
      address = a.address;
    }
    if (campaign.collectStore) {
      if (stores.length && !store.retailer) return setError('Please choose the store you bought from.');
      if (storeNamed && !store.name.trim()) return setError('Please add the store name.');
      if (!store.suburb.trim()) return setError('Please add the suburb or town of the store.');
      if (!nz && !store.state) return setError('Please choose the state the store is in.');
    }
    if (!agree) return setError('Please confirm you have read the terms.');
    setBusy(true);
    try {
      const out = await api(`campaign/${campaign.slug}/claim`, {
        acceptedTerms: agree,
        ...me,
        products: chosen.map((r) => ({ promoProductId: r.promoProductId, price: r.price || null })),
        bank: addBank ? bank : null,
        ...(address ? { address } : {}),
        ...(campaign.collectStore ? { store: { retailer: stores.length ? store.retailer : 'Other', name: storeNamed ? store.name.trim() : '', suburb: store.suburb.trim(), state: nz ? '' : store.state } } : {}),
      });
      router.push(`/c?token=${encodeURIComponent(out.token)}&s=${encodeURIComponent(campaign.slug)}&new=1`);
    } catch (err) {
      if (err.data?.code === 'duplicate_email') setExisting(me.email.trim());
      else setError(err.message);
      setBusy(false);
    }
  }

  return (
    <form className="card" onSubmit={submit} noValidate>
      <h2>Make a claim</h2>
      <p className="sub">You can add your invoice and serial numbers after you submit.</p>
      <p className="returning">Already claimed? <a href="#already-claimed">Open your claim</a></p>

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

      {campaign.collectStore && (
        <fieldset className="group">
          <legend>Where did you buy?</legend>
          {stores.length > 0 && (
            <>
              <label htmlFor="st">Store</label>
              <select id="st" value={store.retailer} onChange={(e) => setStore({ ...store, retailer: e.target.value })}>
                <option value="">Choose the store</option>
                {stores.map((s) => <option key={s} value={s}>{s}</option>)}
              </select>
            </>
          )}
          {storeNamed && (
            <>
              <label htmlFor="stn">{stores.length ? 'Store name' : 'Store'}</label>
              <input id="stn" type="text" value={store.name} onChange={(e) => setStore({ ...store, name: e.target.value })} />
            </>
          )}
          <div className={nz ? '' : 'row2'}>
            <div><label htmlFor="sts">Store suburb or town</label><input id="sts" type="text" value={store.suburb} onChange={(e) => setStore({ ...store, suburb: e.target.value })} /></div>
            {!nz && (
              <div><label htmlFor="stst">Store state</label>
                <select id="stst" value={store.state} onChange={(e) => setStore({ ...store, state: e.target.value })}>
                  <option value="">Choose</option>
                  {(campaign.regions || []).map((r) => <option key={r.value} value={r.value}>{r.value}</option>)}
                </select>
              </div>
            )}
          </div>
        </fieldset>
      )}

      <div className="row2">
        <div><label htmlFor="fn">First name</label><input id="fn" type="text" autoComplete="given-name" required value={me.firstName} onChange={(e) => setMe({ ...me, firstName: e.target.value })} /></div>
        <div><label htmlFor="ln">Last name</label><input id="ln" type="text" autoComplete="family-name" required value={me.lastName} onChange={(e) => setMe({ ...me, lastName: e.target.value })} /></div>
      </div>
      <label htmlFor="em">Email</label>
      <input id="em" type="email" autoComplete="email" required value={me.email} onChange={(e) => setMe({ ...me, email: e.target.value })} />
      <p className="muted" style={{ margin: '4px 0 0' }}>We send your private claim link here. Use an inbox you can open.</p>
      <label htmlFor="mb">Mobile</label>
      <input id="mb" type="tel" autoComplete="tel" required value={me.mobile} onChange={(e) => setMe({ ...me, mobile: e.target.value })} />

      {campaign.collectAddress && (
        <fieldset className="group">
          <legend>Your postal address</legend>
          <label htmlFor="ad1">Street number and name</label>
          <input id="ad1" type="text" autoComplete="address-line1" placeholder="12 Example Street" value={addr.line} onChange={(e) => setAddr({ ...addr, line: e.target.value })} />
          <label htmlFor="ad2">Unit or apartment <span className="muted">(optional)</span></label>
          <input id="ad2" type="text" autoComplete="address-line2" value={addr.unit} onChange={(e) => setAddr({ ...addr, unit: e.target.value })} />
          <label htmlFor="ad3">{nz ? 'Suburb or town' : 'Suburb'}</label>
          <input id="ad3" type="text" autoComplete="address-level2" value={addr.suburb} onChange={(e) => setAddr({ ...addr, suburb: e.target.value })} />
          <div className="row2">
            <div><label htmlFor="ad4">Postcode</label><input id="ad4" type="text" inputMode="numeric" maxLength={4} autoComplete="postal-code" value={addr.postcode} onChange={(e) => setAddr({ ...addr, postcode: e.target.value.replace(/\D/g, '') })} /></div>
            <div><label htmlFor="ad5">{nz ? 'Region' : 'State'}</label>
              <select id="ad5" autoComplete="address-level1" value={addr.state} onChange={(e) => setAddr({ ...addr, state: e.target.value })}>
                <option value="">Choose</option>
                {(campaign.regions || []).map((r) => <option key={r.value} value={r.value}>{nz ? r.label : r.value}</option>)}
              </select>
            </div>
          </div>
        </fieldset>
      )}

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
      {existing && (
        <div className="note" role="alert">
          <b>You already have a claim with {existing}.</b> You don't need to claim again. We'll email you the link to it.
          <SendLinkButton slug={campaign.slug} email={existing} supportEmail={campaign.supportEmail} />
        </div>
      )}
      <div style={{ marginTop: 16 }}><button className="btn block" disabled={busy}>{busy ? <span><span className="spinner" /> Sending your claim…</span> : 'Submit my claim'}</button></div>
    </form>
  );
}
