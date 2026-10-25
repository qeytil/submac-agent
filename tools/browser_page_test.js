// Smoke test for tools/browser_page.js with a fake layout (jsdom has none).
// Run: NODE_PATH=<dir with jsdom> node tools/browser_page_test.js
const { JSDOM } = require('jsdom');
const fs = require('fs');
const path = require('path');
const src = fs.readFileSync(path.join(__dirname, 'browser_page.js'), 'utf8');
let fails = 0;
function ok(c, m) { if (!c) { fails++; console.log('FAIL', m); } else console.log('ok  ', m); }

function page(html) {
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
console.log(fails ? fails + ' FAILED' : 'ALL OK');
process.exit(fails ? 1 : 0);
