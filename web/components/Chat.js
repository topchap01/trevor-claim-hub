'use client';
import { useEffect, useRef, useState } from 'react';
import { api } from '@/lib/client';

/** Help assistant. Pass `token` on a claim page (answers about that claim) or `slug` on the promotion page. */
export default function Chat({ token, slug, firstName, suggestions }) {
  const [open, setOpen] = useState(false);
  const [msgs, setMsgs] = useState([]);
  const [text, setText] = useState('');
  const [busy, setBusy] = useState(false);
  const end = useRef(null);
  useEffect(() => { end.current?.scrollIntoView({ block: 'end' }); }, [msgs, open, busy]);

  async function ask(q) {
    q = (q || '').trim();
    if (!q || busy) return;
    const next = [...msgs, { role: 'user', content: q }];
    setMsgs(next); setText(''); setBusy(true);
    try {
      const path = token ? `claim/${token}/chat` : `campaign/${slug}/chat`;
      const out = await api(path, { messages: next.filter((m) => m.role !== 'note').map(({ role, content }) => ({ role, content })) });
      const add = [{ role: 'assistant', content: out.reply }];
      if (out.handover && out.handoverNote) add.push({ role: 'note', content: out.handoverNote });
      setMsgs((m) => [...m, ...add]);
    } catch {
      setMsgs((m) => [...m, { role: 'note', content: 'Sorry, that didn\'t go through. Please try again.' }]);
    } finally { setBusy(false); }
  }

  const chips = suggestions || (token
    ? ['Where do I find the serial number?', 'When will I get paid?', 'What else do you need from me?', 'Can I talk to a person?']
    : ['Which appliances are included?', 'How much cashback will I get?', 'Can I add serial numbers later?']);

  return (
    <>
      {!open && <button className="chatfab" onClick={() => setOpen(true)} aria-label="Open help chat">Questions? Ask us</button>}
      {open && (
        <section className="chatpanel" role="dialog" aria-label="Help chat">
          <header>
            <div><b>Help</b><span>Automated assistant. It can see {token ? 'your claim and ' : ''}the promotion terms.</span></div>
            <button className="iconbtn" aria-label="Close chat" onClick={() => setOpen(false)}>×</button>
          </header>
          <div className="chatmsgs" aria-live="polite">
            <div className="msg bot">Hi{firstName ? ` ${firstName}` : ''}. What can I help with?</div>
            {msgs.map((m, i) => <div key={i} className={`msg ${m.role === 'user' ? 'me' : m.role === 'note' ? 'sys' : 'bot'}`}>{m.content}</div>)}
            {busy && <div className="msg bot"><span className="spinner" /> </div>}
            <div ref={end} />
          </div>
          {msgs.length === 0 && <div className="chips">{chips.map((c) => <button key={c} className="chip" onClick={() => ask(c)}>{c}</button>)}</div>}
          <form className="chatin" onSubmit={(e) => { e.preventDefault(); ask(text); }}>
            <input type="text" aria-label="Your question" placeholder="Type a question" value={text} maxLength={500} onChange={(e) => setText(e.target.value)} />
            <button className="btn small" disabled={busy || !text.trim()}>Send</button>
          </form>
        </section>
      )}
    </>
  );
}
