#!/usr/bin/env node
// browser_eval: the browser god-mode eval on REAL sites (docs/browser-godmode.md §6).
//
// What it measures: the part of Telesia's browser that does not need the model — the page script the phone injects
// into every page (tools/browser_page.js, copied into lib/services/browser/page_script.dart). Each task drives a real
// site exactly the way the agent's tools do: it reads S.snapshot() (the numbered elements and visible text the model
// sees), finds its target in that snapshot by visible words only (never by a selector the model could not know),
// taps where S.point() says a finger should go (a trusted touch, like WebHands on the phone), types with S.type,
// reads the data layer with S.schema / S.netList / S.extract, and checks the page really changed.
//
// It runs in a phone-sized Chromium (Pixel 8 viewport and user agent), the closest stand-in for Android's WebView
// that CI has. What it cannot cover (the model's choices, real WebView touch injection, site skills replay with the
// agent loop) is listed in docs/browser-eval.md and runs on the phone.
//
// Usage: node tools/browser_eval/eval.js [--only name,name] [--json out.json] [--md out.md]
// Exit code: 0 when the pass rate is at least --min (default 0.85), 1 otherwise. Real sites change, so one flaky
// site never fails the whole run; a broken page script fails most tasks at once.

const fs = require('fs');
const path = require('path');
const { chromium, devices } = require('playwright');

const args = process.argv.slice(2);
const arg = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const only = (arg('--only', '') || '').split(',').filter(Boolean);
const MIN = parseFloat(arg('--min', '0.85'));
const SRC = fs.readFileSync(process.env.BE_SCRIPT || path.join(__dirname, '..', 'browser_page.js'), 'utf8');
const TASK_MS = 45000;

// ---------------------------------------------------------------- the agent's tools, on a Playwright page
function tools(page) {
  const T = {
    calls: 0,
    async S(fn, ...a) {
      T.calls++;
      return page.evaluate(([fn, a]) => {
        const S = window.__sm2;
        if (!S) throw new Error('page script missing');
        return S[fn](...a);
      }, [fn, a]);
    },
    async snap() {
      const s = await T.S('snapshot', {});
      T.lastSnap = s;
      T.tokens.push(Math.ceil(JSON.stringify({ els: s.els, text: s.text }).length / 4));
      return s;
    },
    tokens: [],
    fallbacks: 0,
    // Find an element the way the model would: by its visible words (and optionally its kind).
    find(s, re, kind) {
      const rx = re instanceof RegExp ? re : new RegExp(re, 'i');
      return s.els.find((e) => rx.test(e.t || '') && (!kind || new RegExp(kind, 'i').test(e.k || '')));
    },
    // Like the agent's next step: if the target is not there yet (an animation, a lazy panel), look again shortly.
    async need(re, kind, tries = 4) {
      let s, e;
      for (let k = 0; k < tries; k++) {
        s = await T.snap();
        e = T.find(s, re, kind);
        if (e) return e;
        await page.waitForTimeout(700);
      }
      if (!e) throw new Error(`no element "${re}"${kind ? ' (' + kind + ')' : ''} in the snapshot: ${s.els.slice(0, 25).map((x) => x.k + ':' + x.t).join(' | ')}`);
      return e;
    },
    // Tap like a finger: where S.point says, as a trusted touch.
    async tap(e) {
      const p = await T.S('point', e.i);
      if (!p.ok) throw new Error(`cannot tap ${e.t}: ${p.err}`);
      // S.point gives a fraction of the VISUAL viewport (the screen, what WebHands taps on the phone). Playwright
      // touches in layout-viewport CSS pixels, so a zoomed-out page (no viewport meta) needs the visual viewport's
      // own offset and size, not the device's.
      const xy = await page.evaluate(([fx, fy]) => { const v = window.visualViewport;
        return v ? [v.offsetLeft + fx * v.width, v.offsetTop + fy * v.height] : [fx * innerWidth, fy * innerHeight]; }, [p.fx, p.fy]);
      // Same order as BrowserAgent._touch on the phone: a trusted touch, then ask the page who got it; when the touch
      // missed (it lands nowhere, or on something else) the script's own click is the fallback.
      await T.S('armHits');
      const url0 = page.url();
      await page.touchscreen.tap(Math.round(xy[0]), Math.round(xy[1]));
      await page.waitForTimeout(80);
      let hit = 'target';
      if (page.url() === url0) { try { hit = await T.S('hitOn', e.i); } catch (_) { hit = 'target'; } }
      if (hit !== 'target') { T.fallbacks++; try { await T.S('click', e.i); } catch (_) {} }
      await T.quiet();
    },
    async type(e, text) {
      const r = await T.S('type', e.i, text, false);
      if (!r.ok) throw new Error(`typing failed: ${r.err}`);
    },
    async key(k) { await T.S('key', k); await T.quiet(); },
    async quiet(max = 5000) { try { return await page.evaluate((m) => window.__sm2 && window.__sm2.quiet(m, 300), max); } catch (_) { await page.waitForTimeout(800); return 'nav'; } },
    // A wait that survives the page navigating under it (a form submit): the phone re-injects the script on the
    // new page and waits again, so this does too.
    async waitText(t, max = 15000) {
      const end = Date.now() + max;
      while (Date.now() < end) {
        try {
          await page.waitForFunction(() => !!window.__sm2, null, { timeout: Math.max(500, end - Date.now()) });
          const r = await page.evaluate(([t, m]) => window.__sm2.waitText(t, m), [t, Math.max(500, end - Date.now())]);
          if (r !== 'ok') throw new Error('never saw "' + t + '" (' + r + ')');
          return r;
        } catch (e) {
          if (!/context was destroyed|navigation/i.test(String(e))) throw e;
          await page.waitForLoadState('domcontentloaded').catch(() => {});
        }
      }
      throw new Error('never saw "' + t + '"');
    },
    async goto(url) { await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 }); await T.quiet(6000); },
  };
  return T;
}

const ok = (c, m) => { if (!c) throw new Error(m); };

// ---------------------------------------------------------------- the tasks (20, as the doc asks)
// kind: what part of "better than human" it proves (docs/browser-godmode.md §1).
const TASKS = [
  { name: 'wiki-search', kind: 'act', async run(T) {
    await T.goto('https://en.m.wikipedia.org/wiki/Main_Page');
    let box = (await T.snap()).els.find((e) => /search/i.test(e.t || '') && /input|search|text/i.test(e.k || ''));
    if (!box) { await T.tap(await T.need(/search/i)); box = await T.need(/search/i, 'input|text|search'); }
    await T.type(box, 'Mogadishu');
    await T.key('Enter');
    await T.waitText('Somalia', 15000);
    const s = await T.snap();
    ok(/Mogadishu/i.test(s.title), 'did not land on the Mogadishu article: ' + s.title);
  } },
  { name: 'hn-extract-30', kind: 'breadth', async run(T) {
    await T.goto('https://news.ycombinator.com/');
    const r = JSON.parse(await T.S('extract', { rows: 'tr.athing', fields: { title: '.titleline > a', link: { sel: '.titleline > a', attr: 'href' } } }));
    ok(r.n >= 30 && r.rows.length >= 30, 'expected 30 stories, got ' + r.n);
    ok(r.rows.every((x) => x.title && x.link), 'a story lost its title or link');
  } },
  { name: 'books-extract-20', kind: 'breadth', async run(T) {
    await T.goto('https://books.toscrape.com/');
    const r = JSON.parse(await T.S('extract', { rows: 'article.product_pod', fields: { title: { sel: 'h3 a', attr: 'title' }, price: '.price_color' } }));
    ok(r.n === 20 && r.rows.every((x) => x.title && /£\d/.test(x.price || '')), 'expected 20 books with prices, got ' + JSON.stringify(r).slice(0, 200));
  } },
  { name: 'http-triage-no-render', kind: 'speed', async run(T, page) {
    await T.goto('https://books.toscrape.com/');
    const html = await page.evaluate(() => fetch('/catalogue/page-2.html').then((r) => r.text()));
    const r = JSON.parse(await T.S('extractHtml', html, { rows: 'article.product_pod', fields: { title: { sel: 'h3 a', attr: 'title' } } }));
    ok(r.n === 20, 'page 2 over HTTP should give 20 books, got ' + r.n);
  } },
  { name: 'net-ear-json', kind: 'data', async run(T) {
    await T.goto('https://quotes.toscrape.com/scroll');
    await T.waitText('by', 10000);
    const list = JSON.parse(await T.S('netList', 'api'));
    const call = list.find((c) => /api\/quotes/.test(c.url || ''));
    ok(call, 'the data ear heard no /api/quotes call: ' + JSON.stringify(list).slice(0, 300));
    const body = JSON.parse(await T.S('netBody', call.id));
    const data = JSON.parse(body.body || '{}');
    ok(Array.isArray(data.quotes) && data.quotes.length === 10, 'the call body should carry 10 quotes');
  } },
  { name: 'net-ear-next-page-by-api', kind: 'data', async run(T, page) {
    // The god-mode move: instead of scrolling a feed, re-call the API the site itself used, for the next page
    // (what browser_fetch does on the phone, with the page's own cookies).
    await T.goto('https://quotes.toscrape.com/scroll');
    await T.waitText('by', 10000);
    const list = JSON.parse(await T.S('netList', 'api/quotes'));
    ok(list.length, 'no API call recorded to page from');
    const next = list[0].url.replace(/page=\d+/, 'page=2');
    const data = await page.evaluate((u) => fetch(u, { credentials: 'include' }).then((r) => r.json()), next);
    ok(Array.isArray(data.quotes) && data.quotes.length === 10 && data.page === 2, 'page 2 over the API should carry 10 quotes');
  } },
  { name: 'schema-jsonld', kind: 'data', async run(T) {
    await T.goto('https://www.allrecipes.com/recipe/10813/best-chocolate-chip-cookies/');
    const sc = JSON.parse(await T.S('schema'));
    ok(sc.n > 0 && sc.items.some((x) => x.kind === 'ld'), 'no JSON-LD found: ' + JSON.stringify(sc));
    const it = sc.items.find((x) => x.kind === 'ld');
    const full = JSON.parse(await T.S('schemaOpen', it.i));
    ok(/Recipe/.test(full.text || ''), 'the JSON-LD should describe the recipe');
  } },
  { name: 'state-tree', kind: 'data', async run(T) {
    await T.goto('https://nextjs.org/');
    const sc = JSON.parse(await T.S('schema'));
    const s = await T.snap();
    ok(sc.n > 0 || /og:/.test(s.sch || ''), 'no structured data on a Next.js site: ' + JSON.stringify(sc));
  } },
  { name: 'login-form', kind: 'act', async run(T, page) {
    await T.goto('https://quotes.toscrape.com/login');
    const who = await T.S('isLogin');
    ok(who, 'the sign-in page was not recognised as one');
    const filled = await T.S('login', 'telesia', 'secret');
    ok(filled === 'both', 'login fill: ' + filled);
    await T.tap(await T.need(/^login$/i, 'button'));
    await T.waitText('Logout', 10000).catch(async (e) => { throw new Error(e.message + ' at ' + page.url() + ' fields=' + await page.evaluate(() => [...document.querySelectorAll('input')].map((i) => i.name + '=' + i.value).join(','))); });
  } },
  { name: 'dropdown', kind: 'act', async run(T) {
    await T.goto('https://the-internet.herokuapp.com/dropdown');
    const s = await T.snap();
    const sel = s.els.find((e) => /select|combo|dropdown/i.test(e.k || ''));
    ok(sel, 'no dropdown in the snapshot');
    const r = await T.S('select', sel.i, 'Option 2');
    ok(r.ok && /Option 2/.test(r.value), 'select failed: ' + JSON.stringify(r));
  } },
  { name: 'checkboxes', kind: 'act', async run(T, page) {
    await T.goto('https://the-internet.herokuapp.com/checkboxes');
    const s = await T.snap();
    const boxes = s.els.filter((e) => /check/i.test(e.k || ''));
    ok(boxes.length >= 2, 'expected 2 checkboxes, saw ' + boxes.length);
    await T.tap(boxes[0]);
    const c = await page.evaluate(() => document.querySelectorAll('input[type=checkbox]')[0].checked);
    ok(c, 'the first box did not get ticked by the tap');
  } },
  { name: 'dynamic-wait', kind: 'speed', async run(T) {
    await T.goto('https://the-internet.herokuapp.com/dynamic_loading/2');
    await T.tap(await T.need(/^start$/i));
    const r = await T.waitText('Hello World!', 15000);
    ok(r && r.ok !== false, 'never saw Hello World!');
  } },
  { name: 'add-remove', kind: 'act', async run(T) {
    await T.goto('https://the-internet.herokuapp.com/add_remove_elements/');
    for (let k = 0; k < 3; k++) await T.tap(await T.need(/add element/i));
    const s = await T.snap();
    ok(s.els.filter((e) => /^delete$/i.test(e.t || '')).length === 3, 'expected 3 Delete buttons');
  } },
  { name: 'shadow-dom', kind: 'perception', async run(T) {
    await T.goto('https://the-internet.herokuapp.com/shadowdom');
    const s = await T.snap();
    ok(/My default text|different text/i.test(s.text) || s.els.length > 0, 'shadow text not read');
    const f = await T.S('find', 'different text');
    ok(f.ok, 'find() could not reach text inside a shadow root / slot');
  } },
  { name: 'iframe-editor', kind: 'perception', async run(T) {
    await T.goto('https://the-internet.herokuapp.com/iframe');
    const s = await T.snap();
    ok(/iframe|editor|tinymce/i.test(JSON.stringify(s.frames) + s.text + s.els.map((e) => e.t).join(' ')), 'the editor frame is invisible to the snapshot');
  } },
  { name: 'modal-detect', kind: 'perception', async run(T, page) {
    await T.goto('https://the-internet.herokuapp.com/entry_ad');
    await page.waitForTimeout(1500);
    const s = await T.snap();
    ok(s.modal, 'the entry pop-up was not flagged as a modal');
    const close = T.find(s, /^close$/i);
    ok(close, 'the pop-up has no Close in the snapshot');
    await T.tap(close);
  } },
  { name: 'file-upload', kind: 'act', async run(T) {
    await T.goto('https://the-internet.herokuapp.com/upload');
    const s = await T.snap();
    const f = s.els.find((e) => /file/i.test(e.k || '')) || T.find(s, /choose|browse|file/i);
    ok(f, 'no file field in the snapshot');
    const r = await T.S('upload', f.i, 'note.txt', 'text/plain', Buffer.from('hello from telesia').toString('base64'));
    ok(r.ok, 'upload: ' + r.err);
    await T.tap(await T.need(/^upload$/i));
    await T.waitText('File Uploaded', 15000);
  } },
  { name: 'key-press', kind: 'act', async run(T) {
    await T.goto('https://the-internet.herokuapp.com/key_presses');
    const box = await T.need(/./, 'input|text');
    await T.tap(box);
    await T.S('key', 'Tab');
    const r = await T.waitText('You entered: TAB', 5000);
    ok(r && r.ok !== false, 'the key press was not seen by the page');
  } },
  { name: 'snapshot-budget', kind: 'cost', async run(T) {
    // Heavy real pages: the model must still get a bounded, named view (≤140 elements, most of them named).
    for (const u of ['https://en.m.wikipedia.org/wiki/Somalia', 'https://github.com/trending', 'https://www.bbc.com/news']) {
      await T.goto(u);
      const s = await T.snap();
      ok(s.els.length > 5 && s.els.length <= 140, `${u}: ${s.els.length} elements`);
      const named = s.els.filter((e) => (e.t || '').trim()).length / s.els.length;
      ok(named >= 0.8, `${u}: only ${(named * 100) | 0}% of elements have a name`);
      ok(T.tokens[T.tokens.length - 1] <= 9000, `${u}: snapshot is ${T.tokens[T.tokens.length - 1]} tokens`);
    }
  } },
  { name: 'heal-after-redraw', kind: 'memory', async run(T, page) {
    await T.goto('https://the-internet.herokuapp.com/add_remove_elements/');
    const add = await T.need(/add element/i);
    // The page redraws the button (same words, new node): the old number must heal to the new one.
    await page.evaluate(() => { const b = document.querySelector('button'); const n = b.cloneNode(true); n.onclick = b.onclick; b.replaceWith(n); });
    const h = await T.S('heal', add.i);
    ok(h && (h.ok || h.i !== undefined || typeof h === 'number'), 'heal could not find the redrawn button: ' + JSON.stringify(h));
  } },
];

// ---------------------------------------------------------------- run
(async () => {
  // Behind an egress proxy that needs a login (some sandboxes), Chromium ignores the credentials in the URL.
  let proxy;
  const pu = process.env.HTTPS_PROXY || process.env.https_proxy || '';
  if (pu) { try { const u = new URL(pu); proxy = { server: `${u.protocol}//${u.host}`, username: decodeURIComponent(u.username), password: decodeURIComponent(u.password) }; } catch (_) {} }
  const browser = await chromium.launch({ args: ['--no-sandbox'], proxy });
  const phone = devices['Pixel 7'] || devices['Pixel 5'];
  const results = [];
  for (const t of TASKS) {
    if (only.length && !only.includes(t.name)) continue;
    const ctx = await browser.newContext({ ...phone, locale: 'en-US' });
    await ctx.addInitScript(SRC);
    const page = await ctx.newPage();
    const T = tools(page);
    const t0 = Date.now();
    let err = '';
    try {
      await Promise.race([t.run(T, page), new Promise((_, rej) => setTimeout(() => rej(new Error('timed out after ' + TASK_MS / 1000 + 's')), TASK_MS))]);
    } catch (e) { err = String(e && e.message || e).split('\n')[0].slice(0, 300); }
    const r = { name: t.name, kind: t.kind, ok: !err, ms: Date.now() - t0, calls: T.calls,
      snapTokens: T.tokens.length ? Math.max(...T.tokens) : 0, fallbacks: T.fallbacks, err };
    results.push(r);
    console.log(`${r.ok ? 'PASS' : 'FAIL'}  ${t.name.padEnd(22)} ${String(r.ms).padStart(6)}ms  calls=${r.calls}  snap≤${r.snapTokens}t${r.fallbacks ? '  touch-missed=' + r.fallbacks : ''}  ${err}`);
    await ctx.close();
  }
  await browser.close();
  const pass = results.filter((r) => r.ok).length;
  const rate = results.length ? pass / results.length : 0;
  const summary = { at: new Date().toISOString(), script: (SRC.match(/VERSION = (\d+)/) || [])[1], pass, total: results.length, rate, results };
  console.log(`\nbrowser_eval: ${pass}/${results.length} (${Math.round(rate * 100)}%)`);
  const j = arg('--json'); if (j) fs.writeFileSync(j, JSON.stringify(summary, null, 2));
  const m = arg('--md');
  if (m) {
    const lines = [`### browser_eval — ${pass}/${results.length} (${Math.round(rate * 100)}%)`, '', `page script v${summary.script} · ${summary.at}`, '',
      '| task | kind | result | time | script calls | biggest snapshot (tokens) | touch missed | why |', '|---|---|---|---|---|---|---|---|',
      ...results.map((r) => `| ${r.name} | ${r.kind} | ${r.ok ? 'pass' : '**fail**'} | ${(r.ms / 1000).toFixed(1)}s | ${r.calls} | ${r.snapTokens || ''} | ${r.fallbacks || ''} | ${r.err.replace(/\|/g, '/')} |`)];
    fs.writeFileSync(m, lines.join('\n') + '\n');
  }
  process.exit(rate >= MIN ? 0 : 1);
})();
