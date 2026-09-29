import React, {useEffect, useState} from 'react';
import {createRoot} from 'react-dom/client';
import './style.css';

const money = cents => new Intl.NumberFormat('en-BE', {style: 'currency', currency: 'EUR'}).format(cents / 100);
const samples = ['Two large oat lattes and a cappuccino, please.', 'One latte and one decaf soy latte.', 'Coffee, please.'];
async function api(path, body) {
  const response = await fetch('/api/' + path, body ? {
    method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(body)
  } : {});
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || 'The coffee counter is unavailable.');
  return data;
}
function DrinkList({items, label}) {
  return <ul aria-label={label} className="mt-4 divide-y divide-[#ddcdbb]">
    {items.map((item, index) => <li key={index} className="py-4">
      <div className="flex items-start justify-between gap-3">
        <h3 className="text-2xl capitalize">{item.quantity} × {item.drink}</h3>
        <strong className="whitespace-nowrap pt-1">{money(item.totalCents)}</strong>
      </div>
      <p className="mt-2 capitalize">{item.size} · {item.milk === 'none' ? 'no milk' : item.milk + ' milk'}{item.decaf ? ' · decaf' : ''}</p>
      <p className="mt-1 text-sm text-[#796553]">{money(item.unitCents)} each</p>
    </li>)}
  </ul>;
}
function App() {
  const [config, setConfig] = useState(null), [menu, setMenu] = useState([]);
  const [text, setText] = useState(samples[0]), [result, setResult] = useState(null), [order, setOrder] = useState(null);
  const [error, setError] = useState(''), [busy, setBusy] = useState(false);
  useEffect(() => {
    Promise.all([api('config'), api('menu')]).then(([c, m]) => {setConfig(c); setMenu(m);}).catch(e => setError(e.message));
  }, []);
  function changeOrder(value) {setText(value); setResult(null); setOrder(null); setError('');}
  async function interpret(e) {
    e.preventDefault(); setBusy(true); setError(''); setResult(null); setOrder(null);
    try {setResult(await api('interpret', {text}));} catch (e) {setError(e.message);} finally {setBusy(false);}
  }
  async function confirm() {
    setBusy(true); setError('');
    try {setOrder(await api('orders', {quoteId: result.quote.id}));} catch (e) {setError(e.message);} finally {setBusy(false);}
  }
  const quote = result?.quote;
  return <main className="mx-auto max-w-6xl px-5 py-8 md:px-10 md:py-12">
    <header className="flex flex-wrap items-center justify-between gap-4 border-b border-[#ddcdbb] pb-6">
      <a href="/" className="flex items-center gap-3 text-xl font-bold"><span className="cup" aria-hidden="true">☕</span>Devoxx Coffee Lab</a>
      <div className="text-right"><span className="rounded-full bg-[#e4eee5] px-3 py-1 text-sm text-[#325c37]">{config?.provider || 'Connecting…'}</span><p className="mt-2 max-w-sm break-all text-xs text-[#8a7a6b]">{config?.model}</p></div>
    </header>
    <section className="grid gap-10 py-12 md:grid-cols-[1.1fr_.9fr]">
      <div>
        <p className="mb-3 text-xs font-bold uppercase tracking-[.18em] text-[#b4762a]">One order. Three ways to serve it.</p>
        <h1 className="mb-4 text-5xl leading-tight md:text-6xl">Your coffee.<br/>In your words.</h1>
        <p className="max-w-lg text-lg text-[#796553]">Ordering for yourself or the whole team? Ask for up to six drinks, with different sizes and milks, in one order.</p>
        <form onSubmit={interpret} className="mt-8">
          <label htmlFor="order" className="mb-2 block font-bold">What can we get you?</label>
          <textarea id="order" disabled={busy} value={text} onChange={e => changeOrder(e.target.value)} maxLength={500} rows={3} required className="w-full rounded-2xl border border-[#cebba4] bg-white p-4 text-lg shadow-sm focus:outline-2 focus:outline-[#b4762a]"/>
          <div className="mt-3 flex flex-wrap gap-2">{samples.map(t => <button type="button" className="sample" key={t} disabled={busy} onClick={() => changeOrder(t)}>{t}</button>)}</div>
          <button disabled={busy || !text.trim()} className="primary mt-5" type="submit">{busy ? 'Working on your order…' : 'Review my order'}<span aria-hidden="true"> →</span></button>
        </form>
        {config && !config.configured && <p className="mt-4 text-sm text-[#a8452f]">The barista is waiting for the server’s API key.</p>}
        <div aria-live="polite">
          {error && <p role="alert" className="mt-5 rounded-xl bg-[#f7e5df] p-4 text-[#8d3624]">{error}</p>}
          {result?.clarification && <p className="mt-5 rounded-xl bg-[#efe4d6] p-4">{result.clarification} Update your order above and try again.</p>}
        </div>
      </div>
      <aside className="min-w-0 rounded-3xl bg-white p-7 shadow-sm md:p-9">
        <div className="mb-6 flex items-center justify-between"><h2 className="text-3xl">The coffee counter</h2><span className="text-3xl" aria-hidden="true">☕</span></div>
        {order ? <div role="status" className="rounded-2xl bg-[#e4eee5] p-5">
          <p className="mb-2 text-sm font-bold text-[#4e7a52]">ORDER CONFIRMED</p><h3 className="text-3xl">You’re in the queue.</h3>
          <DrinkList items={order.items} label="Confirmed drinks"/>
          <div className="mt-3 flex justify-between border-t border-[#bdd0bf] pt-4"><span>Total</span><strong className="text-2xl">{money(order.totalCents)}</strong></div>
          <p className="mt-4 break-all text-xs text-[#637666]">Reference {order.id.slice(0, 8)}</p><p className="mt-4 text-sm">Demo order only. No payment was taken.</p>
        </div> : quote ? <div>
          <p className="text-sm uppercase tracking-wider text-[#8a7a6b]">Your proposed order</p>
          <DrinkList items={quote.items} label="Proposed drinks"/>
          <div className="my-6 flex items-center justify-between gap-2 border-y border-[#efe4d6] py-5"><span>Total · {quote.items.reduce((n, item) => n + item.quantity, 0)} cups</span><strong className="text-2xl">{money(quote.totalCents)}</strong></div>
          <button onClick={confirm} disabled={busy} className="primary w-full">Confirm order</button>
          <p className="mt-3 text-xs text-[#8a7a6b]">Review every drink. Nothing is ordered until you confirm. Quote valid for 10 minutes.</p>
        </div> : <>
          <p className="mb-5 text-[#8a7a6b]">Made simple. Served with care.</p>
          {menu.map(m => <div className="flex justify-between border-b border-[#f3ece4] py-3" key={m.drink}><span className="capitalize">{m.drink}</span><strong>{money(m.priceCents)}</strong></div>)}
          <p className="mt-5 text-xs leading-relaxed text-[#8a7a6b]">Regular prices. Large +€0.70, oat or soy +€0.40. Espresso is small. Mix different drinks, up to six cups in total. Decaf at no extra charge.</p>
        </>}
        {result && <div className="mt-7 border-t border-[#efe4d6] pt-4 text-xs text-[#8a7a6b]"><span>{result.provider}</span><span className="float-right">{(result.elapsedMs / 1000).toFixed(2)} s response</span><p className="mt-2">Observed request duration, including server processing.</p></div>}
      </aside>
    </section>
    <footer className="border-t border-[#ddcdbb] pt-5 text-xs text-[#8a7a6b]">Conference demo · Synthetic orders only · Orders reset when the server restarts</footer>
  </main>;
}
createRoot(document.getElementById('root')).render(<App/>);
