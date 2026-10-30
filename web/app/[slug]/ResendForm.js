'use client';
import { useState } from 'react';
import { api } from '@/lib/client';

export default function ResendForm({ slug, intro }) {
  const [email, setEmail] = useState('');
  const [state, setState] = useState('idle');
  async function send(e) {
    e.preventDefault();
    setState('sending');
    try { await api('resend', { slug, email }); setState('sent'); } catch { setState('error'); }
  }
  return (
    <section className="card">
      <h2>Already claimed?</h2>
      <p className="sub">{intro || 'Enter the email you claimed with and we\'ll send you a link to your claim.'}</p>
      {state === 'sent' ? (
        <div className="good">If there's a claim with that email, a link is on its way. Check your inbox.</div>
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
