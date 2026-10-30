'use client';

export async function api(path, body) {
  const res = await fetch(`/api/${path}`, body === undefined ? { cache: 'no-store' } : {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
  });
  const data = await res.json().catch(() => ({ error: 'Something went wrong. Please try again.' }));
  if (!res.ok) throw Object.assign(new Error(data.error || 'Something went wrong.'), { status: res.status, data });
  return data;
}

export function money(n, country) {
  if (n === null || n === undefined || n === '') return '';
  const v = Math.round(Number(n) * 100) / 100;
  const cents = v % 1 !== 0;
  return (country === 'NZ' ? 'NZ$' : '$') + v.toLocaleString('en-AU', { minimumFractionDigits: cents ? 2 : 0, maximumFractionDigits: 2 });
}

/** What a tier pays: a fixed amount, or a share of the spend. Capped by the campaign maximum. */
export function tierAmount(t, spend, cap) {
  const raw = t.percent ? Math.round(spend * t.percent) / 100 : (t.amount || 0);
  return cap ? Math.min(raw, cap) : raw;
}

/** The best tier this basket qualifies for, or undefined. */
export function bestTier(tiers, qty, spend, minProducts, cap) {
  return tiers
    .filter((t) => qty >= (t.minQty || minProducts || 1) && (!t.maxQty || qty <= t.maxQty) && (!(t.minSpend > 0) || spend >= t.minSpend))
    .map((t) => ({ ...t, pays: tierAmount(t, spend, cap) }))
    .sort((a, b) => b.pays - a.pays)[0];
}

export function when(iso, tz = 'Australia/Sydney', withTime = true) {
  if (!iso) return '';
  const d = new Date(iso);
  const date = d.toLocaleDateString('en-AU', { timeZone: tz, day: 'numeric', month: 'long', year: 'numeric' });
  if (!withTime) return date;
  const time = d.toLocaleTimeString('en-AU', { timeZone: tz, hour: 'numeric', minute: '2-digit' }).replace(' ', '').toLowerCase();
  return `${time} ${date}`;
}

/** Shrinks photos on the phone before upload (max 1600px, JPEG), so uploads are quick on mobile data. PDFs pass through. */
export async function prepareFile(file, maxSide = 1600) {
  const readB64 = (blob) => new Promise((ok, bad) => {
    const r = new FileReader();
    r.onload = () => ok(String(r.result).split(',')[1]);
    r.onerror = bad;
    r.readAsDataURL(blob);
  });
  if (file.type === 'application/pdf') {
    if (file.size > 1_500_000) throw new Error('That PDF is over 1.5 MB. Take a photo of the invoice instead.');
    return { base64: await readB64(file), contentType: 'application/pdf', fileName: file.name };
  }
  if (!file.type.startsWith('image/')) throw new Error('Please choose a photo or a PDF.');
  const bmp = await createImageBitmap(file).catch(() => null);
  if (!bmp) return { base64: await readB64(file), contentType: file.type, fileName: file.name };
  const scale = Math.min(1, maxSide / Math.max(bmp.width, bmp.height));
  const canvas = document.createElement('canvas');
  canvas.width = Math.round(bmp.width * scale);
  canvas.height = Math.round(bmp.height * scale);
  canvas.getContext('2d').drawImage(bmp, 0, 0, canvas.width, canvas.height);
  const blob = await new Promise((ok) => canvas.toBlob(ok, 'image/jpeg', 0.82));
  return { base64: await readB64(blob), contentType: 'image/jpeg', fileName: (file.name || 'photo').replace(/\.[^.]+$/, '') + '.jpg' };
}
