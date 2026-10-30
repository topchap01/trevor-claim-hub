import { notFound } from 'next/navigation';
import { hub, okSlug } from '@/lib/sf';
import ClaimForm from './ClaimForm';
import ResendForm from './ResendForm';
import Chat from '@/components/Chat';

export const dynamic = 'force-dynamic';

function money(n, country) {
  return (country === 'NZ' ? 'NZ$' : '$') + Number(n).toLocaleString('en-AU', { maximumFractionDigits: 0 });
}

function fmtTime(iso, tz) {
  const d = new Date(iso);
  return d.toLocaleTimeString('en-AU', { timeZone: tz, hour: 'numeric', minute: '2-digit' }).replace(' ', '').toLowerCase() + ' ' + fmt(iso, tz);
}

function fmtDay(ymd) {
  return new Date(ymd + 'T12:00:00Z').toLocaleDateString('en-AU', { timeZone: 'UTC', day: 'numeric', month: 'long', year: 'numeric' });
}

function fmt(iso, tz) {
  return new Date(iso).toLocaleDateString('en-AU', { timeZone: tz || 'Australia/Sydney', day: 'numeric', month: 'long', year: 'numeric' });
}

export default async function CampaignPage({ params: paramsP }) {
  const params = await paramsP;
  if (!okSlug(params.slug)) notFound();
  const { status, data: c } = await hub(`campaigns/${params.slug}`);
  if (status !== 200) notFound();
  const tz = c.timezone || 'Australia/Sydney';
  return (
    <main>
      <section className="hero" style={{ background: c.brandColor || undefined }}>
        <div className="inner">
          <p className="eyebrow">{c.name}</p>
          <h1>{c.headline}</h1>
          <p>Buy {c.minProducts || 1} or more participating appliances{c.retailers ? ` from ${c.retailers}` : ''} between {fmtDay(c.purchaseFrom)} and {fmtDay(c.purchaseTo)}. Claim by {fmt(c.claimsClose, tz)}.</p>
          <div className="tiers">
            {c.tiers.map((t, i) => (
              <div className="tier" key={t.label}>
                <b>{t.percent ? `${t.percent}% back` : money(t.amount, c.country)}</b>
                <span>{t.minSpend > 0
                  ? (t.maxSpend ? `Spend ${money(t.minSpend, c.country)} to ${money(t.maxSpend, c.country)}` : `Spend ${money(t.minSpend, c.country)}+`)
                  : `Buy ${t.minQty}${t.maxQty ? (t.maxQty === t.minQty ? '' : ` to ${t.maxQty}`) : (t.percent || i === c.tiers.length - 1 ? '+' : '')} appliances`}</span>
              </div>
            ))}
          </div>
        </div>
      </section>
      <div className="wrap">
        <section className="card">
          <h2>How it works</h2>
          <ol className="steps">
            <li>Tell us what you bought. It takes about two minutes.</li>
            <li>Add your invoice now or later. We check it straight away.</li>
            <li>Add serial numbers once your appliances arrive. No login: we email you a private link.</li>
            <li>We pay {c.paymentPromise || 'soon'} of approving your claim.</li>
          </ol>
        </section>
        {c.isOpen ? <ClaimForm campaign={c} /> : <section className="card"><h2>Claims are closed</h2><p className="sub">This promotion is no longer taking new claims.</p></section>}
        <ResendForm slug={c.slug} />
        <section className="card">
          <h2>Key dates</h2>
          <table className="dates"><tbody>
            <tr><th>Buy between</th><td>{fmtDay(c.purchaseFrom)} and {fmtDay(c.purchaseTo)}</td></tr>
            <tr><th>Claims close</th><td>{fmtTime(c.claimsClose, tz)}</td></tr>
            {c.serialDeadline && <tr><th>Serial numbers by</th><td>{fmtTime(c.serialDeadline, tz)}</td></tr>}
            {c.bankDeadline && <tr><th>Fix bank details by</th><td>{fmtTime(c.bankDeadline, tz)}</td></tr>}
          </tbody></table>
          <p className="muted" style={{ margin: '8px 0 0' }}>Times are {c.country === 'NZ' ? 'New Zealand' : 'Sydney'} time.</p>
        </section>
        <section className="card">
          <h2>Terms in brief</h2>
          <p className="terms">{c.termsSummary}</p>
          {c.termsUrl && <p><a href={c.termsUrl} target="_blank" rel="noopener noreferrer">Read the full terms and conditions</a></p>}
        </section>
      </div>
      <Chat slug={c.slug} />
    </main>
  );
}
