'use client';
import { useState } from 'react';
import { api } from '@/lib/client';

/** What the claimant reads once a link is requested. Same words whether or not a claim exists, so nobody can test emails. */
function Sent({ email, supportEmail }) {
  return (
    <div className="good" role="status">
      <b>Check your email{email ? ` (${email})` : ''}.</b> If there's a claim with that address, a link to it is on its way. It can take a few minutes.
      {' '}Not there? Check your junk or spam folder{supportEmail ? <>, or email <a href={`mailto:${supportEmail}`}>{supportEmail}</a></> : ''}.
      <br />Only the newest link works, so use the latest email.
    </div>
  );
}

/** One tap, no typing: for when we already know the email (the claim form found a claim for it). */
export function SendLinkButton({ slug, email, supportEmail }) {
  const [state, setState] = useState('idle');
  async function send() {
    setState('sending');
    try { await api('resend', { slug, email }); setState('sent'); } catch { setState('error'); }
  }
  if (state === 'sent') return <Sent email={email} supportEmail={supportEmail} />;
  return (
    <div style={{ marginTop: 10 }}>
      {/* type="button": this sits inside the claim form and must not submit it */}
      <button type="button" className="btn block" onClick={send} disabled={state === 'sending'}>
        {state === 'sending' ? 'Sending…' : 'Email me the link to my claim'}
      </button>
      {state === 'error' && <div className="err">That didn't work. Please try again.</div>}
    </div>
  );
}

export default function ResendForm({ slug, intro, supportEmail }) {
  const [email, setEmail] = useState('');
  const [state, setState] = useState('idle');
  async function send(e) {
    e.preventDefault();
    setState('sending');
    try { await api('resend', { slug, email }); setState('sent'); } catch { setState('error'); }
  }
  return (
    <section className="card" id="already-claimed">
      <h2>Already claimed?</h2>
      <p className="sub">{intro || 'Enter the email you claimed with and we\'ll send you a link to your claim.'}</p>
      {state === 'sent' ? (
        <Sent email={email} supportEmail={supportEmail} />
      ) : (
        <form onSubmit={send}>
          <label htmlFor="resend-email">Email</label>
          <input id="resend-email" type="email" autoComplete="email" required value={email} onChange={(e) => setEmail(e.target.value)} />
          <div style={{ marginTop: 12 }}><button className="btn ghost" disabled={state === 'sending'}>{state === 'sending' ? 'Sending…' : 'Email me my link'}</button></div>
          {state === 'error' && <div className="err">That didn't work. Please try again.</div>}
        </form>
      )}
    </section>
  );
}
