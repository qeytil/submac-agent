// SubMac browser page script v2 (browser-use v2). Injected at document start and on demand.
// Source of truth for lib/services/browser/page_script.dart (tools/gen_page_script.py copies it there).
// Rules: never mutate the page's DOM (no overlays, no attributes); every wait has a hard limit;
// coordinates the agent sees are fractions of the VISUAL viewport (what the screenshot shows), so
// pinch zoom, device pixel ratio and scroll never shift a tap.
(function () {
  var VERSION = 8;
  if (window.__sm2 && window.__sm2.v === VERSION) return;
  var S = (window.__sm2 = { v: VERSION });

  // ---------------------------------------------------------------- activity: network + DOM
  S.net = 0;
  S.netAt = Date.now();
  S.mut = 0;
  S.mutAt = Date.now();
  function netDone() { S.net = Math.max(0, S.net - 1); S.netAt = Date.now(); }

  // The data ear: the page's own API calls (fetch/XHR), recorded with bodies when they carry data.
  // The agent reads these with browser_net / re-calls them with browser_fetch — it sees what the
  // site's own code receives, which humans cannot. Ring of 40; bodies capped at 20000 chars.
  S.calls = [];
  S.callId = 0;
  var ASSET = /\.(js|css|mjs|png|jpe?g|gif|svg|webp|avif|ico|woff2?|ttf|otf|eot|mp4|webm|m3u8|ts|mp3|wav|pdf)([?#]|$)/i;
  function wantsData(u, ct) {
    u = String(u || '');
    if (u.indexOf('data:') === 0 || ASSET.test(u)) return false;
    ct = String(ct || '').toLowerCase();
    if (/\bjson\b|xml|csv|text\/plain/.test(ct)) return true;
    if (ct === '' && (u.indexOf('/api/') >= 0 || /\.json([?#]|$)/i.test(u))) return true;
    return false;
  }
  function cut(b) { b = String(b == null ? '' : b); return b.length > 20000 ? b.slice(0, 20000) : b; }
  function record(o) {
    try {
      S.callId++;
      o.id = S.callId;
      S.calls.push(o);
      if (S.calls.length > 40) S.calls.shift();
    } catch (e) {}
  }

  try {
    var of = window.fetch;
    if (of && !of.__sm) {
      var nf = function () {
        S.net++; S.netAt = Date.now();
        var p;
        try { p = of.apply(this, arguments); } catch (e) { netDone(); throw e; }
        try {
          var inp = arguments[0];
          var u = typeof inp === 'string' ? inp : (inp && inp.url) || '';
          var m = (arguments[1] && arguments[1].method) || (inp && inp.method) || 'GET';
          var t0 = Date.now();
          p.then(function (res) {
            try {
              var ct = '';
              try { ct = res.headers.get('content-type') || ''; } catch (e2) {}
              if (!wantsData(u, ct) && !(ct !== '' && !/html|javascript|ecmascript|image|video|audio|font|octet|event-stream/.test(ct.toLowerCase()))) return;
              var size = 0;
              try { size = +(res.headers.get('content-length') || 0); } catch (e2) {}
              var rec = function (body) { record({ url: String(u).slice(0, 300), m: String(m), st: res.status, ct: ct.slice(0, 60), ms: Date.now() - t0, size: body != null ? body.length : size, body: cut(body || '') }); };
              try {
                res.clone().text().then(rec, function () { rec(null); });
              } catch (e2) { rec(null); }
            } catch (e2) {}
          }, function () {});
        } catch (e) {}
        try { p.then(netDone, netDone); } catch (e) { netDone(); }
        return p;
      };
      nf.__sm = 1;
      window.fetch = nf;
    }
  } catch (e) {}
  try {
    var ox = XMLHttpRequest.prototype.open;
    if (ox && !ox.__smOpen) {
      var nop = function (m, u) { try { this.__smReq = { m: String(m || 'GET'), u: String(u || '').slice(0, 300) }; } catch (e) {} return ox.apply(this, arguments); };
      nop.__smOpen = 1;
      XMLHttpRequest.prototype.open = nop;
    }
  } catch (e) {}
  try {
    var xs = XMLHttpRequest.prototype.send;
    if (!xs.__sm) {
      var ns = function () {
        S.net++; S.netAt = Date.now();
        var done = false, self = this;
        var fin = function () { if (!done) { done = true; netDone(); } };
        try { self.addEventListener('loadend', fin); } catch (e) { fin(); }
        // A request that never ends must not hold every wait hostage.
        setTimeout(fin, 15000);
        try {
          self.addEventListener('load', function () {
          try {
            var req = self.__smReq || { m: 'GET', u: '' };
            var ct = '';
            try { ct = self.getResponseHeader('content-type') || ''; } catch (e2) {}
            if (!wantsData(req.u, ct)) return;
            var len = 0, body = '';
            try { len = self.responseText ? self.responseText.length : 0; } catch (e2) {}
            if (len > 0 && len <= 20000) {
              try { body = String(self.responseText || '').slice(0, 20000); } catch (e2) {}
            }
            record({ url: req.u, m: req.m, st: self.status, ct: ct.slice(0, 60), ms: Date.now() - (self.__smT0 || Date.now()), size: len, body: body });
          } catch (e2) {}
          });
          self.__smT0 = Date.now();
        } catch (e) {}
        return xs.apply(self, arguments);
      };
      ns.__sm = 1;
      var ns = function () {
        S.net++; S.netAt = Date.now();
        var done = false, self = this;
        var fin = function () { if (!done) { done = true; netDone(); } };
        try { self.addEventListener('loadend', fin); } catch (e) { fin(); }
        // A request that never ends must not hold every wait hostage.
        setTimeout(fin, 15000);
        return xs.apply(self, arguments);
      };
      ns.__sm = 1;
      XMLHttpRequest.prototype.send = ns;
    }
  } catch (e) {}
  S.watch = function () {
    if (S.mo || !document.documentElement) return;
    try {
      S.mo = new MutationObserver(function (l) { S.mut += l.length; S.mutAt = Date.now(); });
      S.mo.observe(document.documentElement, { childList: true, subtree: true, attributes: true, characterData: true });
    } catch (e) {}
  };
  S.watch();
  if (!S.mo) document.addEventListener('DOMContentLoaded', S.watch);

  // Trusted input check: did a real finger land on the element we meant?
  S.hitLog = [];
  ['pointerdown', 'touchstart', 'mousedown', 'keydown', 'beforeinput'].forEach(function (t) {
    document.addEventListener(t, function (e) {
      if (!e.isTrusted) return;
      S.hitLog.push(e.composedPath ? e.composedPath()[0] : e.target);
      if (S.hitLog.length > 20) S.hitLog.shift();
    }, true);
  });

  // ---------------------------------------------------------------- viewport maths
  function vv() {
    var v = window.visualViewport;
    return v ? { x: v.offsetLeft, y: v.offsetTop, w: v.width, h: v.height, s: v.scale || 1 }
             : { x: 0, y: 0, w: window.innerWidth, h: window.innerHeight, s: 1 };
  }
  S.vv = vv;
  // Layout CSS px (client coords) -> fraction of what is on screen.
  function frac(x, y) { var v = vv(); return { fx: (x - v.x) / v.w, fy: (y - v.y) / v.h }; }
  // Fraction of the screen -> client coords.
  function unfrac(fx, fy) { var v = vv(); return { x: v.x + fx * v.w, y: v.y + fy * v.h }; }
  S.frac = frac; S.unfrac = unfrac;

  // Deepest element at a client point, through open shadow roots and same-origin frames.
  function at(x, y) {
    var top = document.elementFromPoint(x, y), guard = 0;
    while (top && guard++ < 12) {
      if (top.shadowRoot) {
        var inner = top.shadowRoot.elementFromPoint(x, y);
        if (inner && inner !== top) { top = inner; continue; }
      }
      if (top.tagName === 'IFRAME' || top.tagName === 'FRAME') {
        try {
          var r = top.getBoundingClientRect(), d = top.contentDocument;
          if (d) {
            var fx = x - r.left - top.clientLeft, fy = y - r.top - top.clientTop;
            var f = d.elementFromPoint(fx, fy);
            if (f) { x = fx; y = fy; top = f; continue; }
          }
        } catch (e) {}
      }
      break;
    }
    return top;
  }
  S.at = at;
  function up(n) { return n.parentNode || (n.host ? n.host : null) || (n.nodeType === 11 ? n.host : null); }
  function deepContains(a, b) {
    var n = b, g = 0;
    while (n && g++ < 400) {
      if (n === a) return true;
      if (n.nodeType === 9) { // document of a frame: step out to the frame element
        var w = n.defaultView, fe = null;
        try { fe = w && w.frameElement; } catch (e) {}
        n = fe; continue;
      }
      n = n.parentNode || n.host || null;
    }
    return false;
  }
  S.deepContains = deepContains;

  // ---------------------------------------------------------------- what is interactive
  var Q = 'a[href],button,input:not([type=hidden]),textarea,select,summary,label[for],[role=button],[role=link],[role=checkbox],' +
    '[role=radio],[role=tab],[role=menuitem],[role=menuitemcheckbox],[role=menuitemradio],[role=option],[role=switch],[role=combobox],' +
    '[role=textbox],[role=slider],[role=searchbox],[role=spinbutton],[role=treeitem],[contenteditable=""],[contenteditable=true],' +
    '[onclick],[tabindex]:not([tabindex="-1"])';
  S.Q = Q;
  var STRONG = { A: 1, BUTTON: 1, SELECT: 1, TEXTAREA: 1, INPUT: 1, SUMMARY: 1 };
  function isStrong(el) {
    if (STRONG[el.tagName]) return true;
    var r = el.getAttribute && el.getAttribute('role');
    return r === 'button' || r === 'link' || r === 'tab' || r === 'menuitem' || r === 'option' || r === 'checkbox' || r === 'radio' || r === 'switch';
  }
  function pointer(el) {
    try {
      if (getComputedStyle(el).cursor !== 'pointer') return false;
      var p = el.parentElement;
      return !(p && getComputedStyle(p).cursor === 'pointer');
    } catch (e) { return false; }
  }
  function txt(s) { return (s || '').toString().replace(/\s+/g, ' ').trim(); }
  function name(el) {
    var t = el.getAttribute('aria-label') || '';
    if (!t) {
      var lb = el.getAttribute('aria-labelledby');
      if (lb) { var d = el.ownerDocument; t = lb.split(/\s+/).map(function (id) { var e = d.getElementById(id); return e ? e.innerText : ''; }).join(' '); }
    }
    if (!t && el.labels && el.labels[0]) t = el.labels[0].innerText;
    if (!t) t = el.getAttribute('placeholder') || el.getAttribute('title') || el.getAttribute('alt') || '';
    if (!t && (el.tagName === 'INPUT') && /^(submit|button|reset)$/i.test(el.type)) t = el.value;
    if (!t) t = el.innerText || '';
    if (!t) { var i = el.querySelector && el.querySelector('img[alt]'); if (i) t = i.alt; }
    if (!t) { var sv = el.querySelector && el.querySelector('svg title'); if (sv) t = sv.textContent; }
    if (!t) t = el.getAttribute('name') || el.id || '';
    t = txt(t);
    return t.length > 80 ? t.slice(0, 80) + '…' : t;
  }
  function kind(el) {
    var tag = el.tagName.toLowerCase(), role = el.getAttribute('role');
    if (tag === 'input') {
      var ty = (el.getAttribute('type') || 'text').toLowerCase();
      if (ty === 'submit' || ty === 'button' || ty === 'reset' || ty === 'image') return 'button';
      if (ty === 'checkbox' || ty === 'radio') return ty + (el.checked ? ' (checked)' : '');
      if (ty === 'range') return 'slider value=' + el.value + ' (' + el.min + '-' + el.max + ')';
      if (ty === 'file') return 'file-upload';
      if (ty === 'password') return 'field(password)' + (el.value ? ' (filled)' : '');
      return 'field(' + ty + ')' + (el.value ? ' value="' + el.value.slice(0, 40) + '"' : '');
    }
    if (tag === 'textarea' || el.isContentEditable) {
      var v = tag === 'textarea' ? el.value : el.innerText;
      return 'textbox' + (v ? ' value="' + txt(v).slice(0, 40) + '"' : '');
    }
    if (tag === 'select') { var o = el.options[el.selectedIndex]; return 'dropdown' + (o ? ' "' + txt(o.text) + '"' : ''); }
    if (role === 'slider') return 'slider value=' + (el.getAttribute('aria-valuenow') || '?');
    if (role === 'combobox') return 'combobox' + (el.getAttribute('aria-expanded') === 'true' ? ' (open)' : '');
    if (tag === 'a') return 'link';
    if (role === 'tab') return 'tab' + (el.getAttribute('aria-selected') === 'true' ? ' (selected)' : '');
    if (role) return role + (el.getAttribute('aria-expanded') === 'true' ? ' (open)' : '') + (el.getAttribute('aria-checked') === 'true' ? ' (checked)' : '');
    if (tag === 'button') return 'button' + (el.disabled ? ' (disabled)' : '');
    return 'clickable';
  }
  function shown(el) {
    try {
      var s = getComputedStyle(el);
      return !(s.visibility === 'hidden' || s.display === 'none' || parseFloat(s.opacity) < 0.05);
    } catch (e) { return true; }
  }

  // Stable numbers: the same element keeps its number for as long as the page lives.
  S.ids = S.ids || new WeakMap();
  S.byId = S.byId || {};
  S.next = S.next || 1;
  function idOf(el) {
    var i = S.ids.get(el);
    if (!i) { i = S.next++; S.ids.set(el, i); }
    S.byId[i] = el;
    return i;
  }
  S.get = function (i) { var el = S.byId[i]; return el && el.isConnected ? el : null; };

  // Every document we can read: the page, open shadow roots, same-origin frames (with their offset).
  function scopes() {
    var out = [], blocked = [];
    function addDoc(doc, ox, oy, depth) {
      out.push({ root: doc, ox: ox, oy: oy });
      // shadow roots
      try {
        var all = doc.querySelectorAll('*');
        for (var z = 0; z < all.length && z < 6000; z++) {
          var sr = all[z].shadowRoot;
          if (sr) {
            out.push({ root: sr, ox: ox, oy: oy });
            var inner = sr.querySelectorAll('*');
            for (var y = 0; y < inner.length && y < 2000; y++) if (inner[y].shadowRoot) out.push({ root: inner[y].shadowRoot, ox: ox, oy: oy });
          }
        }
      } catch (e) {}
      if (depth > 2) return;
      var frames = doc.querySelectorAll('iframe,frame');
      for (var k = 0; k < frames.length && k < 20; k++) {
        var fr = frames[k], r = fr.getBoundingClientRect();
        if (r.width < 20 || r.height < 20) continue;
        var d = null;
        try { d = fr.contentDocument; } catch (e) { d = null; }
        if (d && d.documentElement) addDoc(d, ox + r.left + fr.clientLeft, oy + r.top + fr.clientTop, depth + 1);
        else {
          var src = fr.getAttribute('src') || '';
          var host = '';
          try { host = new URL(src, location.href).host; } catch (e) {}
          blocked.push({ host: host, b: box(r.left + ox, r.top + oy, r.width, r.height) });
        }
      }
    }
    addDoc(document, 0, 0, 0);
    return { scopes: out, blocked: blocked };
  }
  function box(l, t, w, h) { var a = frac(l, t), v = vv(); return [round3(a.fx), round3(a.fy), round3(w / v.w), round3(h / v.h)]; }
  function round3(n) { return Math.round(n * 1000) / 1000; }

  // The point where a finger really reaches el: the centre if it is not covered, otherwise the first
  // free point of a 3x3 grid inside the visible part. A point that lands on another numbered control
  // inside el (a link inside a card) is avoided when a cleaner point exists.
  function hitPoint(el, ox, oy) {
    var r = el.getBoundingClientRect();
    if (r.width < 2 || r.height < 2) return null;
    var W = window.innerWidth, H = window.innerHeight;
    var L = Math.max(r.left + ox, 0), T = Math.max(r.top + oy, 0), R = Math.min(r.right + ox, W), B = Math.min(r.bottom + oy, H);
    if (R - L < 2 || B - T < 2) return null;
    var pts = [[0.5, 0.5], [0.3, 0.5], [0.7, 0.5], [0.5, 0.3], [0.5, 0.7], [0.2, 0.25], [0.8, 0.25], [0.2, 0.75], [0.8, 0.75]];
    var loose = null;
    for (var k = 0; k < pts.length; k++) {
      var x = L + (R - L) * pts[k][0], y = T + (B - T) * pts[k][1];
      var top = at(x, y);
      if (!top) continue;
      var lab = el.labels && el.labels[0];
      var ok = top === el || deepContains(el, top) || (lab && (lab === top || deepContains(lab, top)));
      if (!ok) continue;
      // Is there another strong control between top and el? Then this point would press that one.
      var n = top, inner = false, g = 0;
      while (n && n !== el && g++ < 60) { if (n.nodeType === 1 && n !== top && isStrong(n)) { inner = true; break; } n = n.parentNode || n.host; }
      if (top !== el && isStrong(top) && top !== el) inner = true;
      if (!inner) return { x: x, y: y, top: top };
      if (!loose) loose = { x: x, y: y, top: top };
    }
    return loose;
  }
  S.hitPoint = hitPoint;

  // ---------------------------------------------------------------- the snapshot
  S.snapshot = function (opts) {
    opts = opts || {};
    S.watch();
    var sc = scopes(), list = [], seen = new Set(), pw = false, card = false;
    var W = window.innerWidth, H = window.innerHeight, v = vv();
    var below = H * 1.6;
    for (var s = 0; s < sc.scopes.length; s++) {
      var scp = sc.scopes[s], nodes;
      try { nodes = Array.prototype.slice.call(scp.root.querySelectorAll(Q)); } catch (e) { continue; }
      try {
        var extra = scp.root.querySelectorAll('div,span,li,img,svg,i');
        for (var x = 0; x < extra.length && x < 1500; x++) if (pointer(extra[x])) nodes.push(extra[x]);
      } catch (e) {}
      for (var k = 0; k < nodes.length; k++) {
        var el = nodes[k];
        if (seen.has(el)) continue;
        seen.add(el);
        if (el.tagName === 'INPUT' && el.type === 'password' && shown(el)) pw = true;
        if (el.tagName === 'INPUT' && /cc-|card/i.test((el.getAttribute('autocomplete') || '') + ' ' + (el.name || '') + ' ' + (el.id || ''))) card = true;
        // Skip a child of a numbered strong control (the label inside a button).
        var p = el.parentElement, dup = false, g = 0;
        while (p && g++ < 30) { if (seen.has(p) && isStrong(p) && S.ids.get(p) && list.some(function (e) { return e.el === p; })) { dup = true; break; } p = p.parentElement; }
        if (dup) continue;
        if (!shown(el)) continue;
        var r = el.getBoundingClientRect();
        if (r.width < 3 || r.height < 3) continue;
        var top = r.top + scp.oy, left = r.left + scp.ox;
        if (top > below || top + r.height < -H * 0.25 || left > W || left + r.width < 0) continue;
        var inView = top < H && top + r.height > 0;
        var hp = inView ? hitPoint(el, scp.ox, scp.oy) : null;
        if (inView && !hp) {
          // In view but covered by something else (a sticky bar, a pop-up). A pop-up's own controls still count.
          continue;
        }
        if (list.length >= (opts.max || 140)) break;
        var id = idOf(el);
        var href = '';
        if (el.tagName === 'A' && el.href && el.href.indexOf('javascript:') !== 0) href = el.href.length > 160 ? el.href.slice(0, 160) : el.href;
        var c = hp ? frac(hp.x, hp.y) : frac(left + r.width / 2, top + r.height / 2);
        list.push({
          el: el, i: id, k: kind(el), t: name(el), h: href,
          c: [round3(c.fx), round3(c.fy)],
          b: box(left, top, r.width, r.height),
          o: inView ? 0 : 1,
          d: el.disabled || el.getAttribute('aria-disabled') === 'true' ? 1 : 0,
        });
      }
    }
    if (!card) {
      try { card = !!document.querySelector('iframe[src*="stripe"],iframe[src*="braintree"],iframe[src*="adyen"],iframe[src*="checkout"],iframe[title*="card" i],iframe[name*="card" i]'); } catch (e) {}
    }
    // Visible text, top to bottom, including readable frames.
    var parts = [], len = 0, maxText = opts.text || 2600;
    for (var q = 0; q < sc.scopes.length && len < maxText; q++) {
      var root = sc.scopes[q].root;
      if (root.nodeType !== 9) continue;
      try {
        var wk = root.createTreeWalker(root.body || root, NodeFilter.SHOW_TEXT, null), n;
        while ((n = wk.nextNode()) && len < maxText) {
          var st = txt(n.nodeValue); if (!st) continue;
          var pe = n.parentElement; if (!pe) continue;
          var tg = pe.tagName; if (tg === 'SCRIPT' || tg === 'STYLE' || tg === 'NOSCRIPT' || tg === 'TEMPLATE') continue;
          var rr = pe.getBoundingClientRect(), oy = sc.scopes[q].oy;
          if (rr.bottom + oy < 0 || rr.top + oy > H || rr.width === 0) continue;
          parts.push(st); len += st.length + 1;
        }
      } catch (e) {}
    }
    var text = parts.join(' ').slice(0, maxText);
    var de = document.documentElement, sh = Math.max(de.scrollHeight, document.body ? document.body.scrollHeight : 0);
    var modal = false;
    try {
      modal = Array.prototype.slice.call(document.querySelectorAll('[role=dialog],[role=alertdialog],[aria-modal=true],dialog[open]')).some(function (d) {
        var b = d.getBoundingClientRect(); return b.width > 40 && b.height > 40 && shown(d);
      });
    } catch (e) {}
    var fav = '';
    try { var li = document.querySelector('link[rel~="icon"],link[rel="shortcut icon"],link[rel="apple-touch-icon"]'); if (li && li.href) fav = li.href; } catch (e) {}
    var banner = S.banner();
    var els = list.map(function (e) { var o = {}; for (var key in e) if (key !== 'el') o[key] = e[key]; return o; });
    return {
      url: location.href, title: document.title, els: els, text: text, pw: pw, card: card, modal: modal,
      more: (window.scrollY + H) < (sh - 40), sy: sh > H ? Math.round(window.scrollY / (sh - H) * 100) : 0,
      vw: Math.round(v.w), vh: Math.round(v.h), zoom: round3(v.s), dpr: window.devicePixelRatio || 1,
      fav: fav, banner: banner, frames: sc.blocked.slice(0, 6), ready: document.readyState,
      calls: S.calls.length,
      fp: S.fp(), focus: S.focusName(),
    };
  };

  // The data ear's API: list the recorded calls (no bodies), read one body, forget them all.
  S.netList = function (filter) {
    var f = String(filter || '').toLowerCase(), out = [];
    for (var i = 0; i < S.calls.length; i++) {
      var c = S.calls[i];
      if (f && String(c.url).toLowerCase().indexOf(f) < 0) continue;
      out.push({ id: c.id, url: c.url, m: c.m, st: c.st, ct: c.ct, ms: c.ms, size: c.size, hasBody: !!c.body });
    }
    return JSON.stringify(out);
  };
  S.netBody = function (id) {
    for (var i = 0; i < S.calls.length; i++) {
      if (S.calls[i].id === id) {
        var c = S.calls[i];
        return JSON.stringify({ id: c.id, url: c.url, m: c.m, st: c.st, ct: c.ct, ms: c.ms, size: c.size, body: c.body || '' });
      }
    }
    return JSON.stringify({ err: 'gone' });
  };
  S.netClear = function () { S.calls.length = 0; return 'ok'; };

  // A cheap fingerprint of what the page is showing (url + structure + visible words).
  S.fp = function () {
    var s = location.href + '|' + document.title + '|' + (document.body ? document.body.childElementCount : 0) + '|';
    try { s += (document.body ? document.body.innerText : '').slice(0, 1200); } catch (e) {}
    var h = 0;
    for (var i = 0; i < s.length; i++) { h = ((h << 5) - h + s.charCodeAt(i)) | 0; }
    return String(h);
  };
  S.focusName = function () {
    var a = document.activeElement, g = 0;
    while (a && a.shadowRoot && a.shadowRoot.activeElement && g++ < 6) a = a.shadowRoot.activeElement;
    if (!a || a === document.body) return '';
    return a.tagName.toLowerCase() + ':' + (S.ids.get(a) || '') + ':' + name(a).slice(0, 30);
  };
  S.state = function () {
    return { url: location.href, mut: S.mut, net: S.net, fp: S.fp(), focus: S.focusName(), sy: Math.round(window.scrollY) };
  };

  // Cookie / consent banners: the button that refuses (or, if none, accepts) so the page is usable.
  S.banner = function () {
    try {
      var sel = '#onetrust-banner-sdk,#onetrust-consent-sdk,#CybotCookiebotDialog,#usercentrics-root,.cc-window,#cookie-banner,#cookiebanner,' +
        '[id*=cookie i][role=dialog],[class*=cookie i][role=dialog],[id*=consent i],[class*=consent i],[aria-label*=cookie i],[id*=gdpr i]';
      var cands = document.querySelectorAll(sel);
      for (var k = 0; k < cands.length; k++) {
        var c = cands[k], r = c.getBoundingClientRect();
        if (r.width < 100 || r.height < 30 || !shown(c)) continue;
        var root = c.shadowRoot || c;
        var bs = root.querySelectorAll('button,[role=button],a,input[type=button],input[type=submit]');
        var rej = null, acc = null;
        for (var j = 0; j < bs.length; j++) {
          var n = name(bs[j]).toLowerCase();
          if (!rej && /(reject|decline|refuse|necessary only|only necessary|essential only|deny|continue without)/.test(n)) rej = bs[j];
          if (!acc && /(accept|agree|allow all|got it|i understand|ok\b|okay)/.test(n)) acc = bs[j];
        }
        var b = rej || acc;
        if (b) return { id: idOf(b), name: name(b), kind: rej ? 'reject' : 'accept' };
      }
    } catch (e) {}
    return null;
  };

  // ---------------------------------------------------------------- actions (all bounded)
  function fire(target, x, y, doc) {
    var view = (doc && doc.defaultView) || window;
    var o = { bubbles: true, cancelable: true, composed: true, view: view, clientX: x, clientY: y, screenX: x, screenY: y,
      pointerId: 1, pointerType: 'touch', isPrimary: true, button: 0, buttons: 1, width: 1, height: 1, pressure: 0.5 };
    try { target.dispatchEvent(new view.PointerEvent('pointerover', o)); } catch (e) {}
    try { target.dispatchEvent(new view.PointerEvent('pointerdown', o)); } catch (e) {}
    try { target.dispatchEvent(new view.MouseEvent('mousedown', o)); } catch (e) {}
    o.buttons = 0; o.pressure = 0;
    try { target.dispatchEvent(new view.PointerEvent('pointerup', o)); } catch (e) {}
    try { target.dispatchEvent(new view.MouseEvent('mouseup', o)); } catch (e) {}
  }
  function docOf(el) { return el.ownerDocument || document; }
  function offsetOf(el) {
    // Offset of el's frame inside the top window.
    var ox = 0, oy = 0, d = docOf(el), g = 0;
    while (d !== document && g++ < 5) {
      var fe = null;
      try { fe = d.defaultView.frameElement; } catch (e) {}
      if (!fe) break;
      var r = fe.getBoundingClientRect(); ox += r.left + fe.clientLeft; oy += r.top + fe.clientTop; d = fe.ownerDocument;
    }
    return { ox: ox, oy: oy };
  }
  function inViewNow(el) {
    var o = offsetOf(el), r = el.getBoundingClientRect(), v = vv();
    var t = r.top + o.oy, l = r.left + o.ox;
    return t >= v.y && t + Math.min(r.height, v.h) <= v.y + v.h && l + r.width > v.x && l < v.x + v.w;
  }
  // Instant scroll (ignores the page's smooth scrolling, which made taps land mid-animation).
  function bring(el) {
    if (inViewNow(el)) return;
    try {
      var d = docOf(el), fe = null;
      try { fe = d.defaultView.frameElement; } catch (e) {}
      if (fe) fe.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'instant' });
      el.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'instant' });
    } catch (e) { try { el.scrollIntoView(true); } catch (e2) {} }
  }
  S.bring = bring;

  // Click a numbered element. Returns where the finger should go (screen fraction) and who was pressed.
  S.click = function (i, opts) {
    opts = opts || {};
    var el = S.get(i);
    if (!el) return { ok: false, err: 'element ' + i + ' is gone (the page changed)' };
    if (el.disabled || el.getAttribute('aria-disabled') === 'true') return { ok: false, err: 'element ' + i + ' is disabled' };
    bring(el);
    var o = offsetOf(el), hp = hitPoint(el, o.ox, o.oy);
    if (!hp) {
      var r = el.getBoundingClientRect(), cx = r.left + o.ox + r.width / 2, cy = r.top + o.oy + r.height / 2;
      var cover = at(Math.min(Math.max(cx, 1), window.innerWidth - 1), Math.min(Math.max(cy, 1), window.innerHeight - 1));
      return { ok: false, err: 'element ' + i + ' is covered by ' + (cover ? (cover.tagName.toLowerCase() + ' "' + name(cover) + '"') : 'something'), covered: 1 };
    }
    var f = frac(hp.x, hp.y);
    if (opts.dry) return { ok: true, fx: f.fx, fy: f.fy, tag: el.tagName.toLowerCase() };
    var target = hp.top || el;
    var lo = { x: hp.x - o.ox, y: hp.y - o.oy };
    fire(target, lo.x, lo.y, docOf(el));
    try { if (el.focus) el.focus({ preventScroll: true }); } catch (e) {}
    try {
      if (typeof target.click === 'function') target.click();
      else target.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, composed: true }));
    } catch (e) { try { el.click(); } catch (e2) {} }
    return { ok: true, fx: f.fx, fy: f.fy, tag: el.tagName.toLowerCase() };
  };
  // Where a real finger should go for element i (no event fired).
  S.point = function (i) { return S.click(i, { dry: true }); };
  // Trusted-hit bookkeeping for the native fallback.
  S.armHits = function () { S.hitLog = []; return 'ok'; };
  S.hitOn = function (i) {
    var el = S.get(i);
    if (!S.hitLog.length) return 'none';
    for (var k = 0; k < S.hitLog.length; k++) if (el && (S.hitLog[k] === el || deepContains(el, S.hitLog[k]))) return 'target';
    return 'other';
  };

  // Tap a point given as a fraction of the screen (screenshot coordinates).
  S.tapAt = function (fx, fy) {
    var p = unfrac(fx, fy), el = at(p.x, p.y);
    if (!el) return { ok: false, err: 'nothing at that point' };
    var o = offsetOf(el);
    fire(el, p.x - o.ox, p.y - o.oy, docOf(el));
    try { el.click(); } catch (e) {}
    return { ok: true, what: el.tagName.toLowerCase() + (name(el) ? ' "' + name(el) + '"' : '') };
  };
  S.whatAt = function (fx, fy) { var p = unfrac(fx, fy), el = at(p.x, p.y); return el ? el.tagName.toLowerCase() + (name(el) ? ' "' + name(el) + '"' : '') : 'nothing'; };

  function field(el) {
    var tag = el.tagName;
    if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || el.isContentEditable) return el;
    var inner = el.querySelector && el.querySelector('input:not([type=hidden]),textarea,[contenteditable=""],[contenteditable=true]');
    if (inner) return inner;
    if (el.shadowRoot) { var s = el.shadowRoot.querySelector('input,textarea'); if (s) return s; }
    return el;
  }
  function setValue(el, v) {
    var view = docOf(el).defaultView || window;
    if (el.isContentEditable) {
      el.focus();
      try { docOf(el).execCommand('selectAll', false, null); docOf(el).execCommand('insertText', false, v); } catch (e) { el.innerText = v; }
      return;
    }
    var proto = el instanceof view.HTMLTextAreaElement ? view.HTMLTextAreaElement.prototype
      : el instanceof view.HTMLSelectElement ? view.HTMLSelectElement.prototype : view.HTMLInputElement.prototype;
    var d = Object.getOwnPropertyDescriptor(proto, 'value');
    try { el.focus({ preventScroll: true }); } catch (e) {}
    try { el.dispatchEvent(new view.InputEvent('beforeinput', { bubbles: true, cancelable: true, data: v, inputType: 'insertText' })); } catch (e) {}
    if (d && d.set) d.set.call(el, v); else el.value = v;
    try { el.dispatchEvent(new view.InputEvent('input', { bubbles: true, data: v, inputType: 'insertText' })); } catch (e) { el.dispatchEvent(new Event('input', { bubbles: true })); }
    el.dispatchEvent(new Event('change', { bubbles: true }));
  }
  function valueOf(el) { return (el.isContentEditable ? el.innerText : el.value) || ''; }
  function norm(s) { return (s || '').toString().toLowerCase().replace(/[\s\-().\/]/g, ''); }
  S.valueOf = function (i) { var el = S.get(i); return el ? valueOf(field(el)) : ''; };

  // Type into a numbered field. Checks the field really holds the text afterwards.
  S.type = function (i, text, append) {
    var el0 = S.get(i);
    if (!el0) return { ok: false, err: 'element ' + i + ' is gone (the page changed)' };
    var el = field(el0);
    bring(el);
    var before = valueOf(el);
    var v = append ? before + text : text;
    setValue(el, v);
    var now = valueOf(el);
    var ok = norm(now).indexOf(norm(text).slice(0, 40)) >= 0 || (el.type === 'password' && now.length >= text.length);
    return { ok: ok, value: el.type === 'password' ? '' : now.slice(0, 80), err: ok ? '' : 'the field did not take the text (it shows "' + now.slice(0, 40) + '")' };
  };
  // Focus a field and select its content, so a real keyboard replaces it.
  S.prep = function (i, append) {
    var el0 = S.get(i); if (!el0) return 'gone';
    var el = field(el0);
    bring(el);
    try { el.focus({ preventScroll: true }); } catch (e) { try { el.focus(); } catch (e2) {} }
    try {
      if (!append) { if (el.select) el.select(); else docOf(el).execCommand('selectAll', false, null); }
      else if (el.setSelectionRange) { var L = (el.value || '').length; el.setSelectionRange(L, L); }
    } catch (e) {}
    return 'ok';
  };
  S.clear = function (i) { var el0 = S.get(i); if (!el0) return { ok: false, err: 'gone' }; setValue(field(el0), ''); return { ok: true }; };

  S.select = function (i, v) {
    var el = S.get(i);
    if (!el) return { ok: false, err: 'element ' + i + ' is gone (the page changed)' };
    if (el.tagName !== 'SELECT') { var inner = el.querySelector && el.querySelector('select'); if (inner) el = inner; }
    if (el.tagName !== 'SELECT') return { ok: false, err: 'not a real dropdown: click it, then click the option', custom: 1 };
    var lv = (v || '').toLowerCase().trim(), pick = null;
    for (var k = 0; k < el.options.length && !pick; k++) { var o = el.options[k]; if (txt(o.text).toLowerCase() === lv || o.value.toLowerCase() === lv) pick = o; }
    for (var j = 0; j < el.options.length && !pick; j++) { var o2 = el.options[j]; if (txt(o2.text).toLowerCase().indexOf(lv) >= 0) pick = o2; }
    if (!pick) return { ok: false, err: 'no option "' + v + '". Options: ' + Array.prototype.slice.call(el.options, 0, 30).map(function (o) { return txt(o.text); }).join(' | ') };
    setValue(el, pick.value);
    return { ok: el.value === pick.value, value: txt(pick.text) };
  };

  S.key = function (k) {
    var el = document.activeElement || document.body, g = 0;
    while (el && el.shadowRoot && el.shadowRoot.activeElement && g++ < 6) el = el.shadowRoot.activeElement;
    var codes = { Enter: 13, Tab: 9, Escape: 27, Backspace: 8, ArrowDown: 40, ArrowUp: 38, ArrowLeft: 37, ArrowRight: 39, Space: 32, ' ': 32 };
    ['keydown', 'keypress', 'keyup'].forEach(function (t) {
      try { el.dispatchEvent(new KeyboardEvent(t, { key: k, code: k, keyCode: codes[k] || 0, which: codes[k] || 0, bubbles: true, cancelable: true, composed: true })); } catch (e) {}
    });
    if (k === 'Enter' && el.form) { try { el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit(); } catch (e) {} }
    return { ok: true };
  };

  function scroller(el) {
    var g = 0;
    while (el && el !== document.body && g++ < 40) {
      try {
        var s = getComputedStyle(el);
        if ((/(auto|scroll)/.test(s.overflowY) && el.scrollHeight > el.clientHeight + 4) || (/(auto|scroll)/.test(s.overflowX) && el.scrollWidth > el.clientWidth + 4)) return el;
      } catch (e) {}
      el = el.parentElement;
    }
    return null;
  }
  S.scroll = function (dir, amount, id) {
    var target = null;
    if (id !== null && id !== undefined) { var el = S.get(id); if (!el) return { ok: false, err: 'element ' + id + ' is gone' }; target = scroller(el) || el; }
    if (!target) {
      try {
        var d = Array.prototype.slice.call(document.querySelectorAll('[role=dialog],[aria-modal=true],dialog[open]')).filter(function (x) { return shown(x) && x.getBoundingClientRect().height > 40; })[0];
        if (d) { var inner = d.scrollHeight > d.clientHeight + 4 ? d : Array.prototype.slice.call(d.querySelectorAll('*')).filter(function (x) { return x.scrollHeight > x.clientHeight + 4 && /(auto|scroll)/.test(getComputedStyle(x).overflowY); })[0]; if (inner) target = inner; }
      } catch (e) {}
    }
    var f = amount === 'little' ? 0.3 : amount === 'half' ? 0.5 : 0.85;
    var h = target ? target.clientHeight : window.innerHeight, w = target ? target.clientWidth : window.innerWidth;
    var dx = 0, dy = 0;
    if (dir === 'down') dy = h * f; else if (dir === 'up') dy = -h * f; else if (dir === 'right') dx = w * f; else if (dir === 'left') dx = -w * f;
    var pos = function () { return target ? target.scrollTop + target.scrollLeft * 7 : window.scrollY + window.scrollX * 7; };
    var before = pos();
    if (dir === 'top') { if (target) target.scrollTop = 0; else window.scrollTo({ top: 0, behavior: 'instant' }); }
    else if (dir === 'bottom') { if (target) target.scrollTop = target.scrollHeight; else window.scrollTo({ top: document.documentElement.scrollHeight, behavior: 'instant' }); }
    else if (target) target.scrollBy({ left: dx, top: dy, behavior: 'instant' }); else window.scrollBy({ left: dx, top: dy, behavior: 'instant' });
    if (pos() === before) return { ok: false, err: 'could not scroll ' + dir + ' (at the end, or this part does not scroll)' };
    return { ok: true };
  };

  S.find = function (t) {
    var lt = (t || '').toLowerCase().trim(); if (!lt) return { ok: false };
    var wk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null), n;
    while ((n = wk.nextNode())) {
      if (n.nodeValue.toLowerCase().indexOf(lt) < 0) continue;
      var pe = n.parentElement; if (!pe) continue;
      var r = pe.getBoundingClientRect(); if (r.width === 0 && r.height === 0) continue;
      pe.scrollIntoView({ block: 'center', behavior: 'instant' });
      return { ok: true };
    }
    return { ok: false, err: 'not on this page' };
  };
  S.text = function (i) {
    var el = S.get(i); if (!el) return '';
    if (el.type === 'password') return '';
    return txt((el.value !== undefined && el.value !== '' ? el.value : el.innerText) || el.getAttribute('href') || '');
  };
  S.readAll = function (max) { try { return (document.body ? document.body.innerText : '').slice(0, max || 16000); } catch (e) { return ''; } };

  // Smart wait: resolves when the DOM has been quiet for `quiet` ms, no request is in flight and the
  // document is not loading, or after `max` ms whatever happens.
  S.quiet = function (max, quiet) {
    max = max || 3000; quiet = quiet || 250;
    S.watch();
    return new Promise(function (res) {
      var start = Date.now();
      var iv = setInterval(function () {
        var now = Date.now();
        var calm = now - S.mutAt >= quiet && (S.net === 0 || now - S.netAt > 4000) && now - S.netAt >= 150 && document.readyState !== 'loading';
        if (calm || now - start >= max) { clearInterval(iv); res(calm ? 'calm' : 'timeout'); }
      }, 50);
    });
  };
  S.waitText = function (t, max, gone) {
    var lt = (t || '').toLowerCase();
    return new Promise(function (res) {
      var start = Date.now();
      var iv = setInterval(function () {
        var has = false;
        try { has = !!document.body && document.body.innerText.toLowerCase().indexOf(lt) >= 0; } catch (e) {}
        if (has !== !!gone) { clearInterval(iv); res('ok'); }
        else if (Date.now() - start > max) { clearInterval(iv); res('timeout'); }
      }, 120);
    });
  };


  // Finger-like drags for carousels, sliders and maps (page-script fallback when real touches cannot reach).
  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
  async function dragPoints(el, x1, y1, x2, y2, steps) {
    var view = docOf(el).defaultView || window;
    var o = function (x, y, b) { return { bubbles: true, cancelable: true, composed: true, view: view, clientX: x, clientY: y, pointerId: 1, pointerType: 'touch', isPrimary: true, button: 0, buttons: b }; };
    try { el.dispatchEvent(new view.PointerEvent('pointerdown', o(x1, y1, 1))); } catch (e) {}
    try { el.dispatchEvent(new view.MouseEvent('mousedown', o(x1, y1, 1))); } catch (e) {}
    for (var s = 1; s <= steps; s++) {
      var x = x1 + (x2 - x1) * s / steps, y = y1 + (y2 - y1) * s / steps;
      try { el.dispatchEvent(new view.PointerEvent('pointermove', o(x, y, 1))); } catch (e) {}
      try { docOf(el).dispatchEvent(new view.MouseEvent('mousemove', o(x, y, 1))); } catch (e) {}
      await sleep(16);
    }
    try { el.dispatchEvent(new view.PointerEvent('pointerup', o(x2, y2, 0))); } catch (e) {}
    try { docOf(el).dispatchEvent(new view.MouseEvent('mouseup', o(x2, y2, 0))); } catch (e) {}
  }
  // Points for a swipe on element i (or the middle of the screen), as screen fractions for a real finger.
  S.swipePoints = function (dir, i) {
    var el = i === null || i === undefined ? null : S.get(i);
    if (i !== null && i !== undefined && !el) return { ok: false, err: 'element ' + i + ' is gone' };
    var W = window.innerWidth, H = window.innerHeight, cx = W / 2, cy = H / 2, dw = W * 0.3, dh = H * 0.3;
    if (el) { bring(el); var o = offsetOf(el), r = el.getBoundingClientRect(); cx = r.left + o.ox + r.width / 2; cy = r.top + o.oy + r.height / 2; dw = Math.min(r.width, W) * 0.35; dh = Math.min(r.height, H) * 0.35; }
    var sx = cx, sy = cy, ex = cx, ey = cy;
    if (dir === 'left') { sx = cx + dw; ex = cx - dw; } else if (dir === 'right') { sx = cx - dw; ex = cx + dw; }
    else if (dir === 'up') { sy = cy + dh; ey = cy - dh; } else { sy = cy - dh; ey = cy + dh; }
    var a = frac(sx, sy), b = frac(ex, ey);
    return { ok: true, fx: a.fx, fy: a.fy, fx2: b.fx, fy2: b.fy };
  };
  S.swipe = async function (fx, fy, fx2, fy2) {
    var p = unfrac(fx, fy), q = unfrac(fx2, fy2), el = at(p.x, p.y) || document.body;
    var sc = scroller(el), before = sc ? sc.scrollLeft + sc.scrollTop : 0;
    await dragPoints(el, p.x, p.y, q.x, q.y, 12);
    await sleep(200);
    if (sc && sc.scrollLeft + sc.scrollTop === before) sc.scrollBy({ left: p.x - q.x, top: p.y - q.y, behavior: 'instant' });
    return { ok: true };
  };
  S.drag = async function (i, pct, tx, ty) {
    var el = S.get(i); if (!el) return { ok: false, err: 'element ' + i + ' is gone' };
    bring(el);
    if (el.tagName === 'INPUT' && el.type === 'range' && pct !== null) {
      var mn = parseFloat(el.min || 0), mx = parseFloat(el.max || 100), st = parseFloat(el.step || 1) || 1;
      var v = mn + (mx - mn) * pct / 100; v = Math.round(v / st) * st;
      setValue(el, String(v)); return { ok: true, value: el.value };
    }
    var r = el.getBoundingClientRect(), x1 = r.left + r.width / 2, y1 = r.top + r.height / 2, x2, y2;
    if (pct !== null) {
      var track = el, p = el.parentElement;
      for (var k = 0; k < 4 && p; k++, p = p.parentElement) { if (p.getBoundingClientRect().width > track.getBoundingClientRect().width * 1.5) { track = p; break; } }
      var tr = track.getBoundingClientRect(); x2 = tr.left + tr.width * pct / 100; y2 = y1;
    } else { var q = unfrac(tx / 100, ty / 100); x2 = q.x; y2 = q.y; }
    await dragPoints(el, x1, y1, x2, y2, 14);
    return { ok: true };
  };

  S.upload = function (i, nm, mime, b64) {
    var el = S.get(i); if (!el) return { ok: false, err: 'element ' + i + ' is gone' };
    if (!(el.tagName === 'INPUT' && el.type === 'file')) { var f = (el.querySelector && el.querySelector('input[type=file]')) || document.querySelector('input[type=file]'); if (!f) return { ok: false, err: 'no file field there' }; el = f; }
    var bin = atob(b64), arr = new Uint8Array(bin.length); for (var k = 0; k < bin.length; k++) arr[k] = bin.charCodeAt(k);
    var dt = new DataTransfer(); dt.items.add(new File([arr], nm, { type: mime }));
    el.files = dt.files;
    el.dispatchEvent(new Event('input', { bubbles: true })); el.dispatchEvent(new Event('change', { bubbles: true }));
    return { ok: true };
  };

  // Fill a sign-in form without the model ever seeing the password.
  S.login = function (u, p) {
    var vis = function (e) { var r = e.getBoundingClientRect(); return r.width > 2 && r.height > 2 && shown(e); };
    var pass = Array.prototype.slice.call(document.querySelectorAll('input[type=password]')).filter(vis)[0];
    var user = Array.prototype.slice.call(document.querySelectorAll('input[type=email],input[autocomplete=username],input[autocomplete=email],input[name*=user i],input[name*=login i],input[name*=email i],input[id*=user i],input[id*=email i],input[type=tel],input[type=text]')).filter(vis)[0];
    var did = '';
    if (user && u) { setValue(user, u); did += 'u'; }
    if (pass && p) { setValue(pass, p); did += 'p'; }
    return did === 'up' ? 'both' : did === 'u' ? 'user' : did === 'p' ? 'pass' : 'none';
  };
  S.isLogin = function () {
    var vis = function (e) { var r = e.getBoundingClientRect(); return e.offsetParent !== null && r.width > 20 && shown(e); };
    var pw = Array.prototype.slice.call(document.querySelectorAll('input[type=password]')).some(vis);
    var u = location.href.toLowerCase();
    var lu = /(accounts\.google\.|login\.|\/login|signin|sign-in|sign_in|\/auth|\/sso|identifier)/.test(u);
    var signup = /(signup|sign-up|register|create.?account|join)/.test(u);
    var em = Array.prototype.slice.call(document.querySelectorAll('input[type=email],input[autocomplete=username],input[autocomplete=email],input[name*=identifier i]')).some(vis);
    return (pw || (lu && em)) && !signup;
  };
})();
