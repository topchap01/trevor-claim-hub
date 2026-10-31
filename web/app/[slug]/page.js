import { notFound } from 'next/navigation';
import parse from 'html-react-parser';
import { campaign, okSlug } from '@/lib/sf';
import { loadDesign, themeVars, fill } from '@/lib/designs';
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

async function load(paramsP) {
  const params = await paramsP;
  if (!okSlug(params.slug)) notFound();
  const { status, data: c } = await campaign(params.slug);
  if (status !== 200) notFound();
  return { c, design: await loadDesign(c.slug) };
}

export async function generateMetadata({ params }) {
  const { c, design } = await load(params);
  const t = design?.theme;
  return {
    title: t?.title || c.name,
    ...(t?.favicon || t?.appleIcon ? { icons: { icon: t.favicon, apple: t.appleIcon } } : {}),
  };
}

export async function generateViewport({ params }) {
  const { c, design } = await load(params);
  return { width: 'device-width', initialScale: 1, themeColor: design?.theme?.colors?.brand || c.brandColor || '#041E50' };
}

// ---------------------------------------------------------------- hub blocks, shared by every campaign

function Tiers({ c }) {
  return (
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
  );
}

function HowItWorks({ c }) {
  return (
    <section className="card">
      <h2>How it works</h2>
      <ol className="steps">
        <li>Tell us what you bought. It takes about two minutes.</li>
        <li>Add your invoice now or later. We check it straight away.</li>
        <li>Add serial numbers once your appliances arrive. No login: we email you a private link.</li>
        <li>We pay {c.paymentPromise || 'soon'} of approving your claim.</li>
      </ol>
    </section>
  );
}

function Claim({ c }) {
  return c.isOpen
    ? <ClaimForm campaign={c} />
    : <section className="card"><h2>Claims are closed</h2><p className="sub">This promotion is no longer taking new claims.</p></section>;
}

function KeyDates({ c, tz }) {
  return (
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
  );
}

function Terms({ c }) {
  return (
    <section className="card">
      <h2>Terms in brief</h2>
      <p className="terms">{c.termsSummary}</p>
      {c.termsUrl && <p><a href={c.termsUrl} target="_blank" rel="noopener noreferrer">Read the full terms and conditions</a></p>}
    </section>
  );
}

// ---------------------------------------------------------------- pages

export default async function CampaignPage({ params }) {
  const { c, design } = await load(params);
  const tz = c.timezone || 'Australia/Sydney';
  return design ? <DesignedPage c={c} tz={tz} design={design} /> : <StandardPage c={c} tz={tz} />;
}

function StandardPage({ c, tz }) {
  return (
    <main>
      <section className="hero" style={{ background: c.brandColor || undefined }}>
        <div className="inner">
          <p className="eyebrow">{c.name}</p>
          <h1>{c.headline}</h1>
          <p>Buy {c.minProducts || 1} or more participating appliances{c.retailers ? ` from ${c.retailers}` : ''} between {fmtDay(c.purchaseFrom)} and {fmtDay(c.purchaseTo)}. Claim by {fmt(c.claimsClose, tz)}.</p>
          <Tiers c={c} />
        </div>
      </section>
      <div className="wrap">
        <HowItWorks c={c} />
        <Claim c={c} />
        <ResendForm slug={c.slug} />
        <KeyDates c={c} tz={tz} />
        <Terms c={c} />
      </div>
      <Chat slug={c.slug} />
    </main>
  );
}

/** The studio's page, with the hub's blocks placed where its slots say. The claim form is always on the page. */
function DesignedPage({ c, tz, design }) {
  const top = c.tiers.reduce((m, t) => Math.max(m, t.amount || 0), 0);
  const html = fill(design.html, {
    name: c.name, headline: c.headline, brandName: c.brandName, retailers: c.retailers, supportEmail: c.supportEmail,
    purchaseFrom: fmtDay(c.purchaseFrom), purchaseTo: fmtDay(c.purchaseTo), claimsClose: fmtTime(c.claimsClose, tz),
    minSpend: c.minSpend ? money(c.minSpend, c.country) : '', maxCashback: top ? money(top, c.country) : '',
  });
  const blocks = {
    'claim-form': <Claim c={c} />,
    resend: <ResendForm slug={c.slug} />,
    'how-it-works': <HowItWorks c={c} />,
    tiers: <Tiers c={c} />,
    'key-dates': <KeyDates c={c} tz={tz} />,
    terms: <Terms c={c} />,
  };
  const placedForm = /<hub-slot name="claim-form"><\/hub-slot>/.test(html);
  const content = parse(html, {
    replace(node) {
      if (node.type !== 'tag' || node.name !== 'hub-slot') return undefined;
      const name = node.attribs?.name;
      return <div className={`hub-slot hub-slot-${name}`}>{blocks[name] || null}</div>;
    },
  });
  return (
    <main className="design" style={themeVars(design.theme)}>
      {design.css && <style dangerouslySetInnerHTML={{ __html: design.css }} />}
      {content}
      {!placedForm && <div className="hub-slot hub-slot-claim-form">{blocks['claim-form']}</div>}
      <Chat slug={c.slug} />
    </main>
  );
}
