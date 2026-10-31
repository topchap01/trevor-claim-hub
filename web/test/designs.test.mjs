// Campaign designs are untrusted: these tests pin what the hub strips before it serves one.
// Run: npm test
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cleanHtml, cleanCss, cleanTheme, fill, themeVars, loadDesign, designAsset } from '../lib/designs.js';

test('cleanHtml: removes scripts, handlers, frames, forms and javascript links', () => {
  const out = cleanHtml(`
    <script>alert(1)</script><p onclick="steal()">Hi</p><iframe src="https://evil.example"></iframe>
    <form action="https://evil.example"><input name="bsb"></form><a href="javascript:alert(1)">x</a>
    <style>body{display:none}</style><img src="x.png" onerror="steal()">`, 'aeg');
  assert.doesNotMatch(out, /script|onclick|iframe|<form|<input|javascript:|<style|onerror/i);
  assert.match(out, /<p>Hi<\/p>/);
  assert.match(out, /<img src="\/designs\/aeg\/x.png" \/>/);
});

test('cleanHtml: images only from the design folder; links only https, mailto, tel or anchors', () => {
  const out = cleanHtml(`<img src="https://tracker.example/p.gif"><img src="../secret.png"><img src="logo.png" srcset="logo.png 1x, https://x.example/a.png 2x">
    <a href="http://plain.example">p</a><a href="https://ok.example" target="_blank">ok</a><a href="#terms">t</a><a href="mailto:a@example.com">m</a>`, 'aeg');
  assert.doesNotMatch(out, /tracker|secret|x\.example|plain\.example/);
  assert.match(out, /srcset="\/designs\/aeg\/logo.png 1x"/);
  assert.match(out, /href="https:\/\/ok.example" target="_blank" rel="noopener noreferrer"/);
  assert.match(out, /href="#terms"/);
  assert.match(out, /href="mailto:a@example.com"/);
});

test('cleanHtml: keeps known hub slots and drops unknown ones', () => {
  const out = cleanHtml('<hub-slot name="claim-form"></hub-slot><hub-slot name="admin"></hub-slot>', 'aeg');
  assert.equal(out, '<hub-slot name="claim-form"></hub-slot>');
});

test('cleanCss: no imports, no off-site files, no legacy script hooks, cannot close the style tag', () => {
  const out = cleanCss(`@import url("https://evil.example/x.css");
    .a{background:url(https://evil.example/p.gif)} .b{background:url('banner.webp')}
    .c{width:expression(alert(1))} </style><script>alert(1)</script>`, 'aeg');
  assert.doesNotMatch(out, /@import|evil\.example|expression\(|<\/style|<script/i);
  assert.match(out, /url\("\/designs\/aeg\/banner.webp"\)/);
});

test('cleanTheme: only hex colours, a plain font list and design-folder files', () => {
  const t = cleanTheme({ colors: { brand: '#00053D', accent: 'red;background:url(x)' }, font: 'Arial; } body { display:none', logo: 'https://x.example/l.png', favicon: 'favicon-32.png' }, 'aeg');
  assert.equal(t.colors.brand, '#00053D');
  assert.equal(t.colors.accent, undefined);
  assert.equal(t.font, undefined);
  assert.equal(t.logo, undefined);
  assert.equal(t.favicon, '/designs/aeg/favicon-32.png');
  assert.deepEqual(themeVars(t), { '--campaign-brand': '#00053D', '--brand': '#00053D' });
});

test('fill: known placeholders are escaped; unknown ones are left out', () => {
  const out = fill('<p>{{ name }} {{supportEmail}} {{secret}}</p>', { name: '<b>AEG</b> & co', supportEmail: 'a@example.com', secret: 'x' });
  assert.equal(out, '<p>&lt;b&gt;AEG&lt;/b&gt; &amp; co a@example.com </p>');
});

test('the AEG NZ sandbox design loads, places the claim form and serves its assets', async () => {
  const d = await loadDesign('aeg-nz-cashback');
  assert.ok(d, 'design found');
  assert.match(d.html, /<hub-slot name="claim-form"><\/hub-slot>/);
  assert.equal(d.theme.colors.brand, '#00053D');
  assert.equal(d.theme.logo, '/designs/aeg-nz-cashback/logo.png');
  const banner = await designAsset('aeg-nz-cashback', 'banner.webp');
  assert.equal(banner.type, 'image/webp');
  assert.equal(await designAsset('aeg-nz-cashback', 'page.html'), null, 'page source is not an asset');
  assert.equal(await designAsset('aeg-nz-cashback', '..%2Fpackage.json'), null);
  assert.equal(await loadDesign('no-such-campaign'), null);
});
