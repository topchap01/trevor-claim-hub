'use client';
import { useEffect, useState } from 'react';
import { useSearchParams } from 'next/navigation';
import { api, money, when, prepareFile } from '@/lib/client';
import ResendForm from '../[slug]/ResendForm';
import Chat from '@/components/Chat';
import BankFields from '@/components/BankFields';

const STAGE = {
  awaiting: { title: (c) => `${c.outstanding.length} thing${c.outstanding.length === 1 ? '' : 's'} left to finish your claim`, text: (c) => `Add ${c.outstanding.length === 1 ? 'it' : 'them'} by ${when(c.serialDeadline, c.timezone)}. You can come back to this page any time from your email.` },
  review: { title: () => 'Everything\'s in. Our team is checking it.', text: () => 'We check claims within 5 business days and will email you when it\'s done.' },
  approved: { title: (c) => `Approved: ${money(c.cashback, c.country)} is on its way`, text: (c) => `We'll pay it to your account ending ${c.bank?.last3 ?? ''} ${c.paymentPromise || ''}.` },
  paid: { title: (c) => `Paid: ${money(c.cashback, c.country)}`, text: (c) => `Sent to your account ending ${c.bank?.last3 ?? ''}. It can take 1 to 2 business days to appear.` },
  payment_failed: { title: () => 'Your bank rejected the payment', text: () => 'Please update your bank details below and we\'ll pay again.' },
  not_approved: { title: () => 'Your claim wasn\'t approved', text: (c) => (c.invalidReason ? `Reason: ${c.invalidReason}. ` : '') + 'Reply to any of our emails if you think this is wrong.' },
};

export default function Hub() {
  const token = useSearchParams().get('token') || '';
  const isNew = useSearchParams().get('new') === '1';
  const slug = useSearchParams().get('s') || '';
  const [claim, setClaim] = useState(null);
  const [state, setState] = useState('loading');
  const [open, setOpen] = useState(null);

  // Loads the claim, and again whenever the claimant comes back to the tab (they may have been to their inbox)
  useEffect(() => {
    let live = true;
    const load = () => api(`claim/${encodeURIComponent(token)}`).then(
      (c) => { if (live) { setClaim(c); setState('ok'); } },
      (e) => { if (live) setState(e.status === 404 ? 'expired' : 'error'); },
    );
    load();
    window.addEventListener('focus', load);
    return () => { live = false; window.removeEventListener('focus', load); };
  }, [token]);

  if (state === 'loading') return <div className="wrap"><p className="muted" style={{ marginTop: 24 }}>Loading your claim…</p></div>;
  if (state === 'expired') return (
    <div className="wrap">
      <section className="card"><h2>This link has expired</h2><p className="sub">Links stop working when we send you a newer one. Get a fresh link below.</p></section>
      {/^[a-z0-9-]{3,60}$/.test(slug)
        ? <ResendForm slug={slug} intro="Enter the email address you claimed with and we'll send you a fresh link." />
        : <section className="card"><p className="sub">Open the promotion page you claimed on and use "Email me my link".</p></section>}
    </div>
  );
  if (state === 'error') return <div className="wrap"><div className="err" style={{ marginTop: 24 }}>We couldn't load your claim just now. Please refresh the page.</div></div>;

  const c = claim;
  const total = 2 + c.products.length + 1; // details, invoice, serials, bank
  const done = 1 + (c.checklist.invoice ? 1 : 0) + c.products.filter((p) => p.done).length + (c.checklist.bank ? 1 : 0);
  const pct = ['review', 'approved', 'paid'].includes(c.stage) ? 100 : Math.round((done / total) * 100);
  const s = STAGE[c.stage] || STAGE.awaiting;
  const canEdit = c.stage === 'awaiting';
  const refresh = (next) => { setClaim(next); setOpen(null); };

  return (
    <main>
      <section className="hubhead" style={{ background: c.brandColor ? `var(--campaign-brand, ${c.brandColor})` : undefined }}>
        <div className="inner">
          <p className="eyebrow">{c.campaign} · Claim {c.claimNumber}</p>
          <div className="amt">{money(c.cashback, c.country)} cashback</div>
          <p style={{ margin: '6px 0 0', opacity: .85 }}>Hi {c.firstName}. This page is private to you. No password needed.</p>
        </div>
      </section>
      <div className="wrap">
        <section className={`status ${c.stage}`} aria-live="polite">
          <h2>{s.title(c)}</h2>
          <p className="muted" style={{ margin: 0 }}>{s.text(c)}</p>
          <div className="bar" aria-hidden="true"><i style={{ width: `${pct}%` }} /></div>
        </section>
        {isNew && c.stage === 'awaiting' && <div className="good">Claim received. We've emailed you a link to this page so you can finish it later.</div>}

        <section className="card">
          <h2>Your claim checklist</h2>
          <div className="item"><span className="tick done">✓</span><div className="body"><div className="title">Your details</div><div className="meta">{c.firstName} · {c.emailMasked} · mobile ending {c.mobileLast3}</div></div></div>

          <Invoice c={c} token={token} canEdit={canEdit} open={open === 'invoice'} setOpen={setOpen} onDone={refresh} />

          {c.products.map((p) => (
            <Serial key={p.id} p={p} c={c} token={token} canEdit={canEdit} open={open === p.id} setOpen={setOpen} onDone={refresh} />
          ))}

          <Bank c={c} token={token} open={open === 'bank'} setOpen={setOpen} onDone={refresh} />
        </section>

        <section className="card">
          <h2>What's happened so far</h2>
          <ul className="timeline">
            {c.timeline.map((t, i) => <li key={i}><time>{short(t.at, c.timezone)}</time><span>{t.what}</span></li>)}
          </ul>
        </section>
        <p className="muted" style={{ textAlign: 'center', marginTop: 20, marginBottom: 60 }}>Need a hand? Tap "Questions? Ask us" or reply to any email from us.</p>
      </div>
      <Chat token={token} firstName={c.firstName} />
    </main>
  );
}

function Invoice({ c, token, canEdit, open, setOpen, onDone }) {
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const r = c.receipts[0];
  async function pick(e) {
    const f = e.target.files?.[0];
    if (!f) return;
    setErr(''); setBusy(true);
    try { onDone(await api(`claim/${token}/receipt`, await prepareFile(f))); }
    catch (x) { setErr(x.message); }
    finally { setBusy(false); e.target.value = ''; }
  }
  const ok = c.checklist.invoice;
  const checkText = r?.check;
  return (
    <div className="item">
      <span className={`tick ${ok ? 'done' : 'todo'}`}>{ok ? '✓' : '!'}</span>
      <div className="body">
        <div className="title">Invoice</div>
        <div className="meta">{ok ? [r?.store, r?.number].filter(Boolean).join(' · ') || 'Uploaded' : 'A photo or PDF of your tax invoice'}</div>
        {ok && checkText && (checkText === 'Passed'
          ? <div className="good">We read your invoice automatically and it matches your claim.</div>
          : <div className="note">{checkText.replace(/^Check: /, 'We read your invoice. Our team will check: ')}</div>)}
        {canEdit && !ok && (
          <div style={{ marginTop: 10 }}>
            <label className="btn small filebtn">
              <input type="file" accept="image/*,application/pdf" onChange={pick} disabled={busy} />
              {busy ? <span><span className="spinner" /> Reading your invoice…</span> : 'Upload invoice'}
            </label>
          </div>
        )}
        {err && <div className="err">{err}</div>}
      </div>
    </div>
  );
}

function Serial({ p, c, token, canEdit, open, setOpen, onDone }) {
  const [serial, setSerial] = useState('');
  const [pnc, setPnc] = useState('');
  const [busy, setBusy] = useState('');
  const [err, setErr] = useState('');
  const [msg, setMsg] = useState('');
  async function scan(e) {
    const f = e.target.files?.[0];
    if (!f) return;
    setErr(''); setMsg(''); setBusy('scan');
    try {
      const out = await api(`claim/${token}/plate`, await prepareFile(f, 1400));
      if (out.serial) setSerial(String(out.serial).toUpperCase());
      if (out.pnc) setPnc(String(out.pnc).replace(/\D/g, ''));
      setMsg(out.serial ? 'Read from your photo. Check it matches the plate, then save.' : 'We couldn\'t read the plate. Try a closer, sharper photo or type it in.');
    } catch (x) { setErr(x.message); }
    finally { setBusy(''); e.target.value = ''; }
  }
  async function save(e) {
    e.preventDefault();
    setErr(''); setBusy('save');
    try { onDone(await api(`claim/${token}/serial`, { productId: p.id, serial, pnc })); }
    catch (x) { setErr(x.message); setBusy(''); }
  }
  return (
    <div className="item">
      <span className={`tick ${p.done ? 'done' : 'todo'}`}>{p.done ? '✓' : '!'}</span>
      <div className="body">
        <div className="title">{single(p.name)} serial number</div>
        <div className="meta">{p.model}{p.done ? ` · ${p.serial}${p.pnc ? ` · PNC ${p.pnc}` : ''}` : ' · add it once it\'s delivered'}</div>
        {canEdit && !p.done && !open && <div style={{ marginTop: 10 }}><button className="btn small" onClick={() => setOpen(p.id)}>Add serial number</button></div>}
        {open && (
          <form className="inline" onSubmit={save}>
            <p className="muted" style={{ margin: 0 }}>{hint(p.category)}</p>
            {c.excludedSerialPrefixes && <p className="muted" style={{ margin: '6px 0 0' }}>Serial numbers starting with {orList(c.excludedSerialPrefixes)} are second-quality (T2) stock and don't qualify.</p>}
            <div style={{ marginTop: 10 }}>
              <label className="btn ghost small filebtn">
                <input type="file" accept="image/*" capture="environment" onChange={scan} disabled={!!busy} />
                {busy === 'scan' ? <span><span className="spinner" /> Reading the plate…</span> : 'Scan the rating plate'}
              </label>
            </div>
            {msg && <div className="good">{msg}</div>}
            <div className="row2">
              <div><label htmlFor={`s-${p.id}`}>Serial number</label><input id={`s-${p.id}`} type="text" maxLength={8} autoComplete="off" value={serial} onChange={(e) => setSerial(e.target.value.toUpperCase())} /></div>
              <div><label htmlFor={`p-${p.id}`}>PNC (9 digits)</label><input id={`p-${p.id}`} type="text" inputMode="numeric" maxLength={9} autoComplete="off" value={pnc} onChange={(e) => setPnc(e.target.value.replace(/\D/g, ''))} /></div>
            </div>
            {err && <div className="err">{err}</div>}
            <div style={{ marginTop: 12, display: 'flex', gap: 8 }}>
              <button className="btn small" disabled={!!busy || serial.length < 8}>{busy === 'save' ? 'Saving…' : 'Save'}</button>
              <button type="button" className="btn ghost small" onClick={() => setOpen(null)}>Cancel</button>
            </div>
          </form>
        )}
      </div>
    </div>
  );
}

function orList(csv = '') {
  const xs = csv.split(',').map((x) => x.trim()).filter(Boolean);
  return xs.length < 2 ? xs.join('') : `${xs.slice(0, -1).join(', ')} or ${xs[xs.length - 1]}`;
}

function single(n = '') { return /[^s]s$/i.test(n) ? n.slice(0, -1) : n; }

function short(iso, tz) {
  const d = new Date(iso);
  return d.toLocaleDateString('en-AU', { timeZone: tz, day: 'numeric', month: 'short' }) + ', ' + d.toLocaleTimeString('en-AU', { timeZone: tz, hour: 'numeric', minute: '2-digit' }).replace(' ', '').toLowerCase();
}

function hint(category = '') {
  const c = category.toLowerCase();
  if (c.includes('dish')) return 'The plate is usually on the side edge of the door. Open the door to see it.';
  if (c.includes('oven')) return 'The plate is usually on the oven frame, visible when the door is open.';
  if (c.includes('cooktop') || c.includes('cooking')) return 'The plate is usually underneath the cooktop. Check the manual or warranty card for a copy sticker.';
  if (c.includes('range')) return 'The plate is usually inside the rangehood, behind the filters.';
  if (c.includes('fridge')) return 'The plate is usually inside the fridge on a side wall, near the crisper.';
  return 'The serial number and PNC are on the appliance\'s rating plate.';
}

function Bank({ c, token, open, setOpen, onDone }) {
  const [step, setStep] = useState('start');
  const [code, setCode] = useState('');
  const [b, setB] = useState({ name: '', bsb: '', account: '' });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const [sentTo, setSentTo] = useState('');
  const failed = c.stage === 'payment_failed';
  const locked = ['paid', 'not_approved'].includes(c.stage);
  async function sendCode() {
    setErr(''); setBusy(true);
    try { const out = await api(`claim/${token}/code`, {}); setSentTo(out.to); setStep('code'); }
    catch (x) { setErr(x.message); }
    finally { setBusy(false); }
  }
  async function save(e) {
    e.preventDefault();
    setErr(''); setBusy(true);
    try { onDone(await api(`claim/${token}/bank`, { code, ...b })); setStep('start'); setCode(''); setB({ name: '', bsb: '', account: '' }); }
    catch (x) { setErr(x.message); }
    finally { setBusy(false); }
  }
  return (
    <div className="item">
      <span className={`tick ${failed ? 'bad' : c.checklist.bank ? 'done' : 'todo'}`}>{failed ? '!' : c.checklist.bank ? '✓' : '!'}</span>
      <div className="body">
        <div className="title">Bank details</div>
        <div className="meta">{c.bank ? `${c.bank.name} · account ending ${c.bank.last3}` : 'Where we pay your cashback'}</div>
        {!locked && !open && <div style={{ marginTop: 10 }}><button className={`btn small ${failed || !c.checklist.bank ? '' : 'ghost'}`} onClick={() => { setOpen('bank'); setStep('start'); }}>{c.bank ? 'Change bank details' : 'Add bank details'}</button></div>}
        {open && (
          <div className="inline">
            {step === 'start' && (<>
              <p className="muted" style={{ margin: 0 }}>To protect your cashback, we'll send a 6-digit code to {c.emailMasked} first.</p>
              <div style={{ marginTop: 10, display: 'flex', gap: 8 }}>
                <button className="btn small" onClick={sendCode} disabled={busy}>{busy ? 'Sending…' : 'Send me a code'}</button>
                <button className="btn ghost small" onClick={() => setOpen(null)}>Cancel</button>
              </div>
            </>)}
            {step === 'code' && (
              <form onSubmit={save}>
                <div className="good">Code sent to {sentTo}. It expires in 10 minutes.</div>
                <label htmlFor="otp">6-digit code</label>
                <input id="otp" type="text" inputMode="numeric" autoComplete="one-time-code" maxLength={7} value={code} onChange={(e) => setCode(e.target.value)} />
                <BankFields country={c.country} value={b} onChange={setB} idPrefix="hb" />
                <div style={{ marginTop: 12, display: 'flex', gap: 8 }}>
                  <button className="btn small" disabled={busy}>{busy ? 'Saving…' : 'Save bank details'}</button>
                  <button type="button" className="btn ghost small" onClick={() => setOpen(null)}>Cancel</button>
                </div>
              </form>
            )}
            {err && <div className="err">{err}</div>}
          </div>
        )}
      </div>
    </div>
  );
}
