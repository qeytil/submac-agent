// Smoke test for tools/browser_page.js with a fake layout (jsdom has none).
// Run: NODE_PATH=<dir with jsdom> node tools/browser_page_test.js
const { JSDOM } = require('jsdom');
const fs = require('fs');
const path = require('path');
const src = fs.readFileSync(path.join(__dirname, 'browser_page.js'), 'utf8');
let fails = 0;
function ok(c, m) { if (!c) { fails++; console.log('FAIL', m); } else console.log('ok  ', m); }

function page(html, pre) {
  const dom = new JSDOM(`<!doctype html><body>${html}</body>`, { runScripts: 'outside-only', pretendToBeVisual: true, url: 'https://shop.test/cart' });
  const w = dom.window;
  w.innerWidth = 400; w.innerHeight = 800;
  Object.defineProperty(w.HTMLElement.prototype, 'innerText', { get() { return this.textContent; }, set(v) { this.textContent = v; } });
  const rect = (el) => {
    const r = (el.getAttribute && el.getAttribute('data-r')) || '';
    if (!r) return { left: 0, top: 0, width: 0, height: 0, right: 0, bottom: 0, x: 0, y: 0 };
    const [l, t, ww, hh] = r.split(',').map(Number);
    return { left: l, top: t - (w.__sy || 0), width: ww, height: hh, right: l + ww, bottom: t + hh - (w.__sy || 0), x: l, y: t };
  };
  w.Element.prototype.getBoundingClientRect = function () { return rect(this); };
  w.document.elementFromPoint = function (x, y) {
    let hit = null;
    w.document.querySelectorAll('[data-r]').forEach((el) => {
      if (el.style.display === 'none') return;
      const r = rect(el);
      if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) hit = el; // later = on top
    });
    return hit;
  };
  w.Element.prototype.scrollIntoView = function () { const r = rect(this); w.__sy = Math.max(0, (r.top + (w.__sy || 0)) - 300); };
  w.scrollBy = function (o) { w.__sy = (w.__sy || 0) + (o.top || 0); };
  Object.defineProperty(w, 'scrollY', { get: () => w.__sy || 0 });
  if (pre) pre(w); // set fakes up BEFORE the script wraps them
  w.eval(src);
  return w;
}

// 1. A card wrapper with an inner Buy button: the button gets its own number and its own exact point,
//    and the wrapper's point avoids the button.
{
  const w = page(`
    <div onclick="1" data-r="0,100,400,200" id="card"><span data-r="10,110,200,20">Nice shoes</span>
      <button id="buy" data-r="300,250,80,40">Buy now</button></div>
    <a href="/x" data-r="10,400,100,30" id="lnk">More</a>`);
  const S = w.__sm2;
  const snap = S.snapshot();
  const buy = snap.els.find((e) => e.t === 'Buy now');
  ok(!!buy, 'button inside a clickable card is numbered');
  const fx = buy.c[0] * 400, fy = buy.c[1] * 800;
  ok(fx >= 300 && fx <= 380 && fy >= 250 && fy <= 290, 'button point lies inside the button: ' + fx + ',' + fy);
  const card = snap.els.find((e) => e.k === 'clickable');
  const cx = card.c[0] * 400, cy = card.c[1] * 800;
  ok(!(cx >= 300 && cx <= 380 && cy >= 250 && cy <= 290), 'card point avoids the inner button: ' + cx + ',' + cy);
  let clicked = '';
  w.document.getElementById('buy').addEventListener('click', () => (clicked += 'buy'));
  const r = S.click(buy.i);
  ok(r.ok && clicked === 'buy', 'click lands on the button itself');
}

// 2. A sticky bar covers an element: it is not offered while covered, and click reports what covers it.
{
  const w = page(`<button id="b" data-r="10,10,100,40">Save</button><div id="bar" data-r="0,0,400,60">Sticky header</div>`);
  const S = w.__sm2;
  const snap = S.snapshot();
  ok(!snap.els.some((e) => e.t === 'Save'), 'covered button is not offered');
}

// 3. Typing sets the value through the native setter and checks it.
{
  const w = page(`<input id="q" data-r="10,10,300,40" placeholder="Search">`);
  const S = w.__sm2;
  const snap = S.snapshot();
  const q = snap.els[0];
  let inputs = 0;
  w.document.getElementById('q').addEventListener('input', () => inputs++);
  const r = S.type(q.i, 'red shoes');
  ok(r.ok && w.document.getElementById('q').value === 'red shoes' && inputs > 0, 'type sets value and fires input');
}

// 4. Stable numbers across snapshots; gone after removal.
{
  const w = page(`<button id="a" data-r="10,10,100,40">A</button><button id="b" data-r="10,60,100,40">B</button>`);
  const S = w.__sm2;
  const s1 = S.snapshot(), s2 = S.snapshot();
  ok(s1.els[1].i === s2.els[1].i, 'same element keeps its number');
  w.document.getElementById('b').remove();
  ok(S.click(s1.els[1].i).ok === false, 'removed element reports gone');
}

// 5. Elements below the fold are listed as off-screen; clicking scrolls them in first.
{
  const w = page(`<button id="far" data-r="10,1000,100,40">Far</button>`);
  const S = w.__sm2;
  const snap = S.snapshot();
  const far = snap.els.find((e) => e.t === 'Far');
  ok(far && far.o === 1, 'below-the-fold element is listed as off-screen');
  let hit = false; w.document.getElementById('far').addEventListener('click', () => (hit = true));
  const r = S.click(far.i);
  ok(r.ok && hit, 'click scrolls it in and presses it');
}

// 6. Cookie banner: the refuse button is found.
{
  const w = page(`<div id="onetrust-banner-sdk" data-r="0,600,400,200"><button data-r="10,700,150,40">Accept all</button><button data-r="200,700,150,40">Reject all</button></div>`);
  const b = w.__sm2.snapshot().banner;
  ok(b && b.kind === 'reject', 'cookie banner refuse button found');
}

// 7. Select + payment page markers.
{
  const w = page(`<select id="s" data-r="10,10,200,40"><option value="1">Small</option><option value="2">Large</option></select><input autocomplete="cc-number" data-r="10,80,200,40">`);
  const S = w.__sm2; const snap = S.snapshot();
  ok(snap.card === true, 'card field marks a payment page');
  const sel = snap.els.find((e) => e.k.startsWith('dropdown'));
  ok(S.select(sel.i, 'large').ok && w.document.getElementById('s').value === '2', 'select picks by visible text');
}
// 8. The data ear: fetch calls that carry data are recorded with bodies; assets are not; the API reads back.
(async () => {
  const w = page(`<button data-r="10,10,100,40">x</button>`, (w0) => {
    const mkRes = (ct, body) => ({
      status: 200,
      headers: { get: (k) => (String(k).toLowerCase() === 'content-type' ? ct : null) },
      clone() { return this; },
      text: async () => body,
    });
    w0.fetch = async (u) => {
      if (String(u).includes('/api/list')) return mkRes('application/json', '{"items":[1,2,3]}');
      if (String(u).includes('/img/logo.png')) return mkRes('image/png', '\x89PNG');
      return mkRes('text/plain', 'plain data body');
    };
  });
  const S = w.__sm2;
  await Promise.all([w.fetch('/api/list'), w.fetch('/img/logo.png'), w.fetch('/data/readme')]);
  await new Promise((r) => setTimeout(r, 10));
  ok(S.calls.length === 2, 'only data calls recorded, the image is not (got ' + S.calls.length + ')');
  ok(S.snapshot().calls === 2, 'snapshot carries the call count');
  const list = JSON.parse(S.netList('api'));
  ok(list.length === 1 && list[0].m === 'GET' && list[0].st === 200 && list[0].hasBody === true, 'netList filters by url and lists metadata');
  const one = JSON.parse(S.netBody(list[0].id));
  ok(one.body === '{"items":[1,2,3]}', 'netBody returns the JSON body');
  ok(JSON.parse(S.netBody(99999)).err === 'gone', 'netBody says gone for unknown ids');
  S.netClear();
  ok(S.calls.length === 0, 'netClear forgets everything');
// 9. The schema ear + the extract walker: JSON-LD, app state, OG count, and one-call row extraction.
{
  const w = page(`
    <script type="application/ld+json">{"@type":"Product","name":"Red shoes","price":"19.99"}</script>
    <script>window.__NEXT_DATA__={"page":"/search","props":{"items":[1,2,3]}};</script>
    <meta property="og:title" content="Shop">
    <div class="card" data-r="10,10,380,120">
      <h3 class="name" data-r="10,20,200,30">Red shoes</h3>
      <span class="price" data-r="10,60,100,30">$19.99</span>
      <a href="/p/red" data-r="10,90,100,30">View</a>
    </div>
    <div class="card" data-r="10,150,380,120">
      <h3 class="name" data-r="10,160,200,30">Blue hat</h3>
      <span class="price" data-r="10,200,100,30">$9.99</span>
      <a href="/p/blue" data-r="10,230,100,30">View</a>
    </div>`);
  const S = w.__sm2;
  const idx = JSON.parse(S.schema());
  ok(idx.n === 2, 'schema index holds the ld block and the state block (got ' + idx.n + ')');
  ok(idx.items[0].kind === 'ld' && idx.items[0].name === 'Product', 'JSON-LD item carries its @type');
  ok(idx.items[1].kind === 'state' && idx.items[1].name === '__NEXT_DATA__', 'state block is named');
  ok(idx.og === 1, 'og metas counted');
  ok(!('text' in idx.items[0]), 'the index stays small: no text in it');
  const open = JSON.parse(S.schemaOpen(0));
  ok(open.text.includes('"Red shoes"') && open.text.includes('19.99'), 'schemaOpen returns the full ld text');
  ok(JSON.parse(S.schemaOpen(99)).err === 'gone', 'schemaOpen says gone for unknown indexes');
  ok(S.snapshot().sch.includes('JSON-LD Product') && S.snapshot().sch.includes('og:1'), 'snapshot summary line: ' + S.snapshot().sch);
  const ex = JSON.parse(S.extract({ rows: '.card', fields: { name: '.name', price: '.price', link: { sel: 'a', attr: 'href' } } }));
  ok(ex.n === 2 && ex.rows.length === 2, 'extract walks every row');
  ok(ex.rows[0].name === 'Red shoes' && ex.rows[0].price === '$19.99' && ex.rows[0].link === '/p/red', 'fields resolved: ' + JSON.stringify(ex.rows[0]));
  ok(ex.rows[1].name === 'Blue hat', 'second row resolved too');
  const miss = JSON.parse(S.extract({ rows: '.card', fields: { name: '.name', sku: '.sku' } }));
  ok(miss.rows[0].sku === null, 'a missing field is null, not an error');
  ok(JSON.parse(S.extract({ rows: '.card', fields: { name: '.name' }, limit: 1 })).rows.length === 1, 'limit caps the rows');
  ok(JSON.parse(S.extract({})).err, 'a spec with no rows answers with an error');
  let noThrow = true;
  try { JSON.parse(S.extract({ rows: 'a[bad' })); } catch (e) { noThrow = false; }
  ok(noThrow, 'a bad selector answers (err on strict engines), never throws');
}
// 10. The same walker on HTML that was never rendered (many links, no navigation).
{
  const w = page(`<div class="card" data-r="10,10,380,120"><h3 class="name">Live</h3></div>`);
  const S = w.__sm2;
  const html = '<html><body><div class="card"><h3 class="name">Far shoes</h3>' +
    '<span class="price">$5.00</span><a href="/p/far">View</a></div>' +
    '<div class="card"><h3 class="name">Far hat</h3><span class="price">$7.00</span></div></body></html>';
  const r = JSON.parse(S.extractHtml(html, { rows: '.card', fields: { name: '.name', price: '.price', link: { sel: 'a', attr: 'href' } } }));
  ok(r.n === 2 && r.rows.length === 2, 'extractHtml walks a fetched page (got ' + JSON.stringify(r).slice(0, 80) + ')');
  ok(r.rows[0].name === 'Far shoes' && r.rows[0].price === '$5.00' && r.rows[0].link === '/p/far', 'fields resolved from the string');
  ok(r.rows[1].link === null, 'a missing field is null on a fetched page too');
  ok(JSON.parse(S.extract({ rows: '.card', fields: { name: '.name' } })).rows[0].name === 'Live', 'the live page is untouched by extractHtml');
  ok(JSON.parse(S.extractHtml('', { rows: '.card' })).n === 0, 'empty html is no rows, not an error');
  ok(JSON.parse(S.extractHtml(html, {})).err, 'a spec with no rows still answers with an error');
}
})().then(() => {
  console.log(fails ? fails + ' FAILED' : 'ALL OK');
  process.exit(fails ? 1 : 0);
});
