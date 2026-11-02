// router.ts
var EMPTY_SNAP = {
  current_route_id: null,
  since: null,
  rest: {}
};
function snapFrom(v) {
  if (!v || typeof v !== "object") return {
    ...EMPTY_SNAP,
    rest: {}
  };
  const rest = {};
  if (v.rest && typeof v.rest === "object") {
    for (const [k, u] of Object.entries(v.rest)) if (typeof u === "string") rest[k] = u;
  }
  return {
    current_route_id: typeof v.current_route_id === "string" ? v.current_route_id : null,
    since: v.since ?? null,
    rest
  };
}
var FRIENDLY = {
  busy: "SubMac is busy right now. Please try again in a moment.",
  too_long: "This is too long to send in one go. Start a new chat or send less at once.",
  limit_daily: "You've used today's replies. They reset at midnight.",
  limit_total: "You've used all the replies in your plan.",
  no_plan: "Get a plan to keep going.",
  blocked: "Your account needs attention. Please contact support.",
  server: "Something went wrong on our side. Please try again."
};
function retryAfterSecs(rand = Math.random) {
  return 15 + Math.floor(rand() * 16);
}
var GEMINI_SKIP_SIGNATURE = "skip_thought_signature_validator";
function isGeminiRoute(r) {
  return /generativelanguage\.googleapis\.com/i.test(r.base_url ?? "") || /gemini/i.test(r.provider ?? "") && /^gemini/i.test(r.model ?? "");
}
function withThoughtSignatures(messages, r) {
  if (!Array.isArray(messages) || !isGeminiRoute(r)) return messages;
  let changed = false;
  const out = messages.map((m) => {
    if (!m || m.role !== "assistant" || !Array.isArray(m.tool_calls) || !m.tool_calls.length) return m;
    const calls = m.tool_calls.map((c) => {
      if (!c || typeof c !== "object" || c.extra_content?.google?.thought_signature) return c;
      changed = true;
      return {
        ...c,
        extra_content: {
          ...c.extra_content ?? {},
          google: {
            ...c.extra_content?.google ?? {},
            thought_signature: GEMINI_SKIP_SIGNATURE
          }
        }
      };
    });
    return {
      ...m,
      tool_calls: calls
    };
  });
  return changed ? out : messages;
}
function sseError(code, retryAfter) {
  const e = {
    code,
    message: FRIENDLY[code]
  };
  if (retryAfter) e.retry_after = retryAfter;
  return `event: error
data: ${JSON.stringify({
    error: e
  })}

`;
}
var n = (v, d) => {
  const x = Number(v);
  return v !== null && v !== void 0 && v !== "" && Number.isFinite(x) && x > 0 ? x : d;
};
function budgetFrom(s = {}, internal = false) {
  const nonStream = n(s.nonstream_budget_ms, 45e3);
  return {
    headersMs: n(s.router_headers_ms, 6e3),
    firstOutputMs: n(s.router_first_output_ms, 1e4),
    lastAttemptMs: n(s.router_last_attempt_ms, 18e3),
    hardStopMs: n(s.router_hard_stop_ms, 25e3),
    heartbeatMs: n(s.heartbeat_ms, 1e4),
    idleMs: n(s.stream_idle_ms_v2, 45e3),
    // One reply must end before the platform wall clock (150 s on Free): end it cleanly with cutTail.
    replyTotalMs: n(s.reply_total_ms, 14e4),
    // bot-run gives each call 40 s: its non-streamed calls must end before that.
    nonStreamMs: internal ? Math.min(nonStream, n(s.internal_nonstream_budget_ms, 38e3)) : nonStream,
    nonStreamAttemptMs: n(s.nonstream_attempt_ms, 25e3),
    maxRoutes: n(s.router_max_routes, 3),
    maxAttempts: n(s.router_max_attempts, 6)
  };
}
function cooldownFor(status) {
  if (status === 429) return 60;
  if (status === 401 || status === 403) return 3600;
  if (status === 402) return 6 * 3600;
  if (status >= 500 || status === 0) return 20;
  return 0;
}
var localCooldown = /* @__PURE__ */ new Map();
var rr = /* @__PURE__ */ new Map();
function hashOf(s) {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}
function keysInOrder(r, chat = "", anyKey = false, now = Date.now()) {
  const usable = anyKey ? r.keys : r.keys.filter((k) => {
    const lc = localCooldown.get(k.id) ?? 0;
    const dc = k.cooldown_until ? Date.parse(k.cooldown_until) : 0;
    return lc < now && dc < now;
  });
  if (!usable.length) return [];
  let i;
  if (chat) i = hashOf(chat + "|" + r.route_id) % usable.length;
  else {
    i = (rr.get(r.route_id) ?? 0) % usable.length;
    rr.set(r.route_id, i + 1);
  }
  return [
    ...usable.slice(i),
    ...usable.slice(0, i)
  ];
}
function restedAt(snap, routeId, now) {
  const u = snap.rest[routeId];
  return !!u && Date.parse(u) > now || (localCooldown.get("route:" + routeId) ?? 0) > now;
}
function orderRoutes(routes, snap, now = Date.now()) {
  const ok = routes.filter((r) => !restedAt(snap, r.route_id, now));
  const resting = routes.filter((r) => restedAt(snap, r.route_id, now));
  const cur = ok.find((r) => r.route_id === snap.current_route_id) ?? null;
  const pointerValid = !!snap.current_route_id && routes.some((r) => r.route_id === snap.current_route_id);
  const effective = cur ?? (!pointerValid ? ok.find((r) => r.healthy) ?? ok[0] ?? null : null);
  const rest = ok.filter((r) => r !== effective);
  const list = [
    ...effective ? [
      effective
    ] : [],
    ...rest.filter((r) => r.healthy),
    ...rest.filter((r) => !r.healthy),
    ...resting
  ];
  return {
    list,
    current: effective,
    pointer: effective?.route_id ?? null
  };
}
function homeProbe(routes, snap, homeId, afterMs, now = Date.now()) {
  if (!homeId || !snap.current_route_id || snap.current_route_id === homeId) return null;
  const home = routes.find((r) => r.route_id === homeId);
  if (!home || restedAt(snap, homeId, now)) return null;
  const since = snap.since ? Date.parse(snap.since) : NaN;
  if (!Number.isFinite(since) || now - since < afterMs) return null;
  return home;
}
function modelMissing(text) {
  return /model[^\n]{0,80}(not[ _-]?found|does ?n[o']t exist|not exist|unknown|no such|not available|unsupported|is not (found|supported))|(unknown|invalid|no such|unsupported)[ _-]model|no endpoints? found|model_not_found/i.test(text ?? "");
}
function effortOf(h) {
  const v = (h ?? "").trim().toLowerCase();
  return v === "low" || v === "normal" || v === "high" ? v : null;
}
function takesEffort(r) {
  if (r.extra_body && "reasoning_effort" in r.extra_body) return true;
  return /gemini|gpt-oss|deepseek-v4|nemotron-3|o[1-9]-|gpt-5/i.test(r.model);
}
var PROVIDER_MAX_OUTPUT = {
  poolside: 32768
};
function providerOutCap(r, s = {}) {
  const extra = s.provider_max_output_tokens && typeof s.provider_max_output_tokens === "object" && !Array.isArray(s.provider_max_output_tokens) ? s.provider_max_output_tokens : {};
  const caps = {
    ...PROVIDER_MAX_OUTPUT
  };
  for (const [k, v] of Object.entries(extra)) caps[k.toLowerCase()] = Number(v);
  const hay = (String(r.provider ?? "") + " " + String(r.model ?? "")).toLowerCase();
  let cap = 0;
  for (const [k, v] of Object.entries(caps)) {
    if (!k || !Number.isFinite(v) || v <= 0 || !hay.includes(k)) continue;
    cap = cap ? Math.min(cap, Math.floor(v)) : Math.floor(v);
  }
  return cap;
}
function clampOut(room, provCap, learned) {
  let n2 = room;
  if (provCap > 0) n2 = Math.min(n2, provCap);
  if (learned && learned > 0) n2 = Math.min(n2, learned);
  return n2;
}
function effortBody(r, e) {
  if (!e || e === "normal" || !takesEffort(r)) return {};
  return {
    reasoning_effort: e
  };
}
function thinkDialect(r) {
  const host = `${r.provider ?? ""} ${r.base_url ?? ""}`.toLowerCase();
  if (host.includes("openrouter")) return "openrouter";
  if ((host.includes("nvidia") || host.includes("integrate.api")) && /nemotron/i.test(r.model)) return "nim-nemotron";
  return "openai";
}
function thinkingExtra(r, e) {
  const out = { ...(r.extra_body ?? {}) };
  const own = typeof out.reasoning_effort === "string" ? String(out.reasoning_effort) : null;
  const level = e ? (e === "normal" ? "medium" : e) : own;
  const dialect = thinkDialect(r);
  if (dialect === "openai") {
    if (e && takesEffort(r)) out.reasoning_effort = level;
    return out;
  }
  delete out.reasoning_effort;
  if (!level) return out;
  if (dialect === "openrouter") {
    const prev = out.reasoning && typeof out.reasoning === "object" ? out.reasoning : {};
    out.reasoning = { ...prev, effort: level };
    return out;
  }
  const kw = { ...(out.chat_template_kwargs ?? {}) };
  delete kw.low_effort; delete kw.medium_effort;
  const ultra = /ultra/i.test(r.model), superish = /super/i.test(r.model);
  if (level === "none" || level === "minimal" || (level === "low" && !superish)) kw.enable_thinking = false;
  else if (level === "low" || (level === "medium" && superish)) { kw.enable_thinking = true; kw.low_effort = true; }
  else if (level === "medium" && ultra) { kw.enable_thinking = true; kw.medium_effort = true; }
  else kw.enable_thinking = true;
  out.chat_template_kwargs = kw;
  return out;
}
function raceSignal(p, s) {
  if (s.aborted) return Promise.reject(new Error("aborted"));
  return new Promise((ok, bad) => {
    const on = () => bad(new Error("aborted"));
    s.addEventListener("abort", on, {
      once: true
    });
    p.then((v) => {
      s.removeEventListener("abort", on);
      ok(v);
    }, (e) => {
      s.removeEventListener("abort", on);
      bad(e);
    });
  });
}
function link(from, to, why) {
  if (from.aborted) to.abort(why);
  else from.addEventListener("abort", () => to.abort(why), {
    once: true
  });
}
var REAL = (peek) => /"(content|reasoning_content|reasoning)"\s*:\s*"[^"]/.test(peek) || /"tool_calls"\s*:\s*\[\s*\{/.test(peek) || peek.includes("[DONE]") || peek.length > 2e5;
async function runChat(o) {
  const { deps, budget } = o;
  const master = new AbortController();
  let masterWhy = "";
  const abortAll = (why) => {
    if (!master.signal.aborted) {
      masterWhy = why;
      master.abort(why);
    }
  };
  if (o.signal) {
    if (o.signal.aborted) abortAll("client");
    else o.signal.addEventListener("abort", () => abortAll("client"), {
      once: true
    });
  }
  const order = orderRoutes(o.routes, o.snap, deps.now());
  const probe = homeProbe(o.routes, o.snap, o.homeId, o.homeAfterMs ?? 15 * 6e4, deps.now());
  if (probe) order.list = [
    probe,
    ...order.list.filter((r) => r !== probe)
  ];
  const probeFrom = o.snap.current_route_id;
  const enc = new TextEncoder();
  let attempts = 0;
  const attempt = async (r, k) => {
    const ctl = new AbortController();
    let why = "";
    link(master.signal, ctl, "master");
    const tA = deps.now();
    const stopAt = (ms, w) => setTimeout(() => {
      why = w;
      ctl.abort(w);
    }, Math.max(0, ms));
    const left = o.t0 + budget.nonStreamMs - tA;
    const tHdr = o.stream ? stopAt(budget.headersMs, "timeout") : stopAt(Math.min(budget.nonStreamAttemptMs, left), "timeout");
    const failOf = (e, status = 0) => {
      if (master.signal.aborted) return {
        kind: "fail",
        why: masterWhy === "client" ? "aborted" : "hard_stop",
        status: 0,
        text: masterWhy
      };
      if (why === "timeout") return {
        kind: "fail",
        why: "timeout",
        status: 0,
        text: "timeout"
      };
      return {
        kind: "fail",
        why: "network",
        status,
        text: String(e).slice(0, 160)
      };
    };
    let res;
    try {
      res = await raceSignal(deps.fetch(r.base_url.replace(/\/$/, "") + "/chat/completions", {
        method: "POST",
        signal: ctl.signal,
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${k.key}`,
          "user-agent": "submac-proxy/1"
        },
        body: JSON.stringify(o.payloadFor(r))
      }), ctl.signal);
    } catch (e) {
      clearTimeout(tHdr);
      return failOf(e);
    }
    if (o.stream) clearTimeout(tHdr);
    if (!res.ok) {
      clearTimeout(tHdr);
      let txt = "";
      try {
        txt = (await raceSignal(res.text(), AbortSignal.any([
          ctl.signal,
          AbortSignal.timeout(2e3)
        ]))).slice(0, 300);
      } catch {
        res.body?.cancel().catch(() => {
        });
      }
      return {
        kind: "fail",
        why: "status",
        status: res.status,
        text: txt
      };
    }
    if (!o.stream) {
      try {
        const data = await raceSignal(res.json(), ctl.signal);
        clearTimeout(tHdr);
        if (!data?.choices) return {
          kind: "fail",
          why: "bad",
          status: 0,
          text: "bad response"
        };
        return {
          kind: "ok",
          res,
          ctl,
          held: [],
          data
        };
      } catch (e) {
        clearTimeout(tHdr);
        res.body?.cancel().catch(() => {
        });
        return failOf(e);
      }
    }
    const tFirst = stopAt(budget.firstOutputMs - (deps.now() - tA), "timeout");
    const reader = res.body.getReader();
    const held = [];
    const dec = new TextDecoder();
    let peek = "";
    try {
      for (; ; ) {
        const x = await raceSignal(reader.read(), ctl.signal);
        if (x.done) break;
        held.push(x.value);
        peek += dec.decode(x.value, {
          stream: true
        });
        if (/"error"\s*:/.test(peek) && !/"choices"/.test(peek)) {
          clearTimeout(tFirst);
          reader.cancel().catch(() => {
          });
          return {
            kind: "fail",
            why: "empty",
            status: 0,
            text: "error in stream"
          };
        }
        if (REAL(peek)) {
          clearTimeout(tFirst);
          return {
            kind: "ok",
            res,
            ctl,
            reader,
            held
          };
        }
      }
    } catch (e) {
      clearTimeout(tFirst);
      reader.cancel().catch(() => {
      });
      return failOf(e);
    }
    clearTimeout(tFirst);
    return {
      kind: "fail",
      why: "empty",
      status: 0,
      text: "empty stream"
    };
  };
  const findAnswer = async () => {
    let routesSpent = 0;
    let triedAny = false;
    for (let ri = 0; ri < order.list.length; ri++) {
      const r = order.list[ri];
      if (master.signal.aborted || deps.now() - o.t0 > budget.lastAttemptMs || attempts >= budget.maxAttempts) break;
      await o.ensureKeys(r);
      const probing = !!probe && r === probe && ri === 0;
      let ks = keysInOrder(r, o.chat, false, deps.now()).slice(0, probing ? 1 : 3);
      if (!ks.length && !triedAny && ri === order.list.length - 1) ks = keysInOrder(r, o.chat, true, deps.now()).slice(0, 1);
      if (!ks.length) continue;
      let n429 = 0, nHard = 0, tried = 0, auth = 0;
      let outcome = null;
      const shrunk = /* @__PURE__ */ new Set();
      for (let ki = 0; ki < ks.length; ki++) {
        const k = ks[ki];
        if (master.signal.aborted || deps.now() - o.t0 > budget.lastAttemptMs || attempts >= budget.maxAttempts) break;
        attempts++;
        tried++;
        triedAny = true;
        const a = await attempt(r, k);
        if (a.kind === "ok") {
          if (k.cooldown_until || localCooldown.has(k.id)) deps.markKey(k.id, true, null, 0);
          if (probing && probeFrom) {
            deps.log?.({
              evt: "router_home_probe",
              route: r.route_id,
              from: probeFrom,
              ok: true
            });
            deps.home?.(r.route_id, probeFrom, true, null);
          }
          return {
            a,
            r,
            k
          };
        }
        if (a.why === "aborted" || a.why === "hard_stop") return null;
        const err = a.why === "status" ? `${r.provider} ${a.status}: ${a.text}` : `${r.provider}: ${a.text}`;
        deps.attemptFailed(r, k, a.status, err);
        if (a.why === "timeout") {
          deps.markKey(k.id, false, err, 20);
          outcome = "fb_timeout";
          break;
        }
        if (a.why === "status") {
          if (a.status === 400 && o.shrink && !shrunk.has(k.id) && o.shrink(r, a.text)) {
            shrunk.add(k.id);
            ks.splice(ki + 1, 0, k);
            tried--;
            continue;
          }
          deps.markKey(k.id, false, err, cooldownFor(a.status));
          if (a.status === 429) {
            n429++;
            continue;
          }
          if (a.status === 401 || a.status === 402 || a.status === 403) {
            auth++;
            continue;
          }
          if (a.status === 400 || a.status === 422) {
            outcome = "request";
            break;
          }
          if (a.status === 404) {
            outcome = modelMissing(a.text) ? "hard" : "request";
            break;
          }
        } else deps.markKey(k.id, false, err, 20);
        nHard++;
        if (nHard >= 2) {
          outcome = "hard";
          break;
        }
      }
      if (!outcome) outcome = tried > 0 && n429 + auth === tried && n429 > 0 ? "overflow" : tried > 0 ? "hard" : null;
      if (!outcome) break;
      if (probing) {
        deps.log?.({
          evt: "router_home_probe",
          route: r.route_id,
          from: probeFrom,
          ok: false,
          outcome
        });
        if (probeFrom && (outcome === "hard" || outcome === "fb_timeout")) {
          localCooldown.set("route:" + r.route_id, deps.now() + 6e4);
          deps.home?.(r.route_id, probeFrom, false, outcome);
        }
        continue;
      }
      if (outcome === "request") {
        routesSpent++;
        deps.log?.({
          evt: "router_request_error",
          route: r.route_id
        });
        if (routesSpent >= budget.maxRoutes) break;
      } else if (outcome !== "overflow") {
        routesSpent++;
        if (order.current && r.route_id === order.current.route_id) {
          const next = order.list.slice(ri + 1).find((x) => !restedAt(o.snap, x.route_id, deps.now()));
          deps.report(r.route_id, outcome, next?.route_id ?? null);
        }
        if (routesSpent >= budget.maxRoutes) break;
      } else deps.log?.({
        evt: "router_overflow",
        route: r.route_id
      });
    }
    return null;
  };
  const hardStop = setTimeout(() => abortAll("hard_stop"), Math.max(0, o.t0 + (o.stream ? budget.hardStopMs : budget.nonStreamMs) - deps.now()));
  const fallbackOf = (r) => !!order.current && r.route_id !== order.current.route_id && r !== probe;
  if (!o.stream) {
    let got = null;
    try {
      got = await findAnswer();
    } catch (e) {
      deps.log?.({
        evt: "router_error",
        error: String(e).slice(0, 200)
      });
    }
    clearTimeout(hardStop);
    if (!got) {
      if (masterWhy === "client") return new Response(null, {
        status: 499,
        headers: o.headers
      });
      const ra = retryAfterSecs();
      return new Response(JSON.stringify({
        error: {
          code: "busy",
          message: FRIENDLY.busy,
          retry_after: ra
        }
      }), {
        status: 503,
        headers: {
          ...o.headers,
          "content-type": "application/json",
          "Retry-After": String(ra)
        }
      });
    }
    o.onUpstream?.();
    const total = deps.now() - o.t0;
    const d = {
      route: got.r,
      key: got.k,
      status: 200,
      usage: got.a.data?.usage,
      outChars: 0,
      ttft: total,
      total,
      attempts,
      fallback: fallbackOf(got.r),
      data: got.a.data
    };
    if (d.fallback) deps.log?.({
      evt: "router_fallback",
      route: got.r.route_id,
      current: order.current?.route_id ?? null
    });
    got.a.data.model = o.alias;
    for (const ch of got.a.data.choices ?? []) {
      if (typeof ch?.message?.content === "string") {
        ch.message.content = o.clean ? o.clean(ch.message.content) : ch.message.content;
        if (ch.message.tool_calls?.length && !ch.message.content.trim()) ch.message.content = null;
      }
    }
    o.onDone(d);
    return o.jsonResponse ? o.jsonResponse(got.a.data, d) : new Response(JSON.stringify(got.a.data), {
      status: 200,
      headers: {
        ...o.headers,
        "content-type": "application/json"
      }
    });
  }
  let closed = false;
  let lastSent = 0;
  let ctrl;
  let hb;
  const send = (s) => {
    if (closed) return false;
    try {
      ctrl.enqueue(typeof s === "string" ? enc.encode(s) : s);
      lastSent = deps.now();
      return true;
    } catch {
      closed = true;
      return false;
    }
  };
  const close = () => {
    if (closed) return;
    closed = true;
    if (hb) clearInterval(hb);
    clearTimeout(hardStop);
    try {
      ctrl.close();
    } catch {
    }
  };
  let onCancel = () => {
  };
  const pump = async () => {
    let got = null;
    try {
      got = await findAnswer();
    } catch (e) {
      deps.log?.({
        evt: "router_error",
        error: String(e).slice(0, 200)
      });
      if (masterWhy !== "client") send(sseError("server"));
      close();
      return;
    }
    clearTimeout(hardStop);
    if (!got) {
      if (masterWhy !== "client") send(sseError("busy", retryAfterSecs()));
      close();
      return;
    }
    o.onUpstream?.();
    const { a, r, k } = got;
    const reader = a.reader;
    const fallback = fallbackOf(r);
    if (fallback) deps.log?.({
      evt: "router_fallback",
      route: r.route_id,
      current: order.current?.route_id ?? null
    });
    const dec = new TextDecoder();
    let buf = "", usage = null, outChars = 0, ttft = 0, sawFinish = false, done = false;
    const cutTail = () => `data: ${JSON.stringify({
      id: "cut",
      object: "chat.completion.chunk",
      model: o.alias,
      choices: [
        {
          index: 0,
          delta: {},
          finish_reason: "length"
        }
      ]
    })}

data: [DONE]

`;
    const finish = (status, err) => {
      if (done) return;
      done = true;
      o.onDone({
        route: r,
        key: k,
        status,
        usage,
        outChars,
        ttft: ttft || deps.now() - o.t0,
        total: deps.now() - o.t0,
        attempts,
        error: err,
        fallback
      });
    };
    onCancel = () => {
      finish(499, "client closed");
      reader.cancel().catch(() => {
      });
      a.ctl.abort("client");
    };
    const process = (chunk) => {
      if (chunk) buf += dec.decode(chunk, {
        stream: true
      });
      else buf += "\n";
      let out = "";
      let nl;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl).trim();
        buf = buf.slice(nl + 1);
        if (!line) continue;
        if (!line.startsWith("data:")) {
          if (line.startsWith(":")) out += line + "\n\n";
          continue;
        }
        const d = line.slice(5).trim();
        if (d === "[DONE]") {
          out += "data: [DONE]\n\n";
          continue;
        }
        let j;
        try {
          j = JSON.parse(d);
        } catch {
          out += line + "\n\n";
          continue;
        }
        if (j.usage) usage = j.usage;
        if (j.choices?.[0]?.finish_reason) sawFinish = true;
        j.model = o.alias;
        const delta = j.choices?.[0]?.delta;
        if (delta) {
          if (typeof delta.content === "string" && o.clean) {
            delta.content = o.clean(delta.content);
            if (/^\s*<?\s*\/?\s*｜[^>]*>?\s*$|^\s*<\s*$/.test(delta.content) && delta.content.includes("\uFF5C")) delta.content = "";
          }
          const c = (delta.content?.length ?? 0) + (delta.reasoning_content?.length ?? 0) + (delta.reasoning?.length ?? 0) + (delta.tool_calls ? JSON.stringify(delta.tool_calls).length : 0);
          if (c > 0 && !ttft) ttft = deps.now() - o.t0;
          outChars += c;
        }
        out += "data: " + JSON.stringify(j) + "\n\n";
      }
      return out;
    };
    const joined = new Uint8Array(a.held.reduce((s, b) => s + b.length, 0));
    {
      let off = 0;
      for (const b of a.held) {
        joined.set(b, off);
        off += b.length;
      }
    }
    const before = outChars;
    const first = process(joined);
    if (first && !send(first)) {
      outChars = before;
      finish(499, "client closed");
      a.ctl.abort("client");
      return;
    }
    const tCommit = deps.now();
    try {
      for (; ; ) {
        if (closed) return;
        const left = Math.min(budget.idleMs, budget.replyTotalMs - (deps.now() - tCommit));
        if (left <= 0) throw new Error("reply too long for one call");
        const x = await raceSignal(reader.read(), AbortSignal.any([
          a.ctl.signal,
          AbortSignal.timeout(left)
        ]));
        if (x.done) {
          const tail = process(null);
          if (tail) send(tail);
          if (!sawFinish) send(cutTail());
          finish(200, sawFinish ? void 0 : "ended without finish");
          close();
          return;
        }
        const out = process(x.value);
        if (out) send(out);
      }
    } catch (e) {
      if (masterWhy === "client" || closed) {
        finish(499, "client closed");
        reader.cancel().catch(() => {
        });
        a.ctl.abort("client");
        return;
      }
      if (!sawFinish) send(cutTail());
      finish(200, "stream cut: " + String(e).slice(0, 100));
      close();
      reader.cancel().catch(() => {
      });
      a.ctl.abort("cut");
    }
  };
  const body = new ReadableStream({
    start(c) {
      ctrl = c;
      send(": ping\n\n");
      const tick = Math.max(20, Math.min(1e3, Math.floor(budget.heartbeatMs / 4)));
      hb = setInterval(() => {
        if (deps.now() - lastSent >= budget.heartbeatMs) send(": ping\n\n");
      }, tick);
      pump().catch(() => close());
    },
    cancel() {
      closed = true;
      if (hb) clearInterval(hb);
      clearTimeout(hardStop);
      abortAll("client");
      onCancel();
    }
  });
  return new Response(body, {
    status: 200,
    headers: {
      ...o.headers,
      "content-type": "text/event-stream",
      "cache-control": "no-cache"
    }
  });
}
// billing_gate.ts
function num(v, d) {
  const n2 = Number(v);
  return v !== null && v !== void 0 && v !== "" && Number.isFinite(n2) ? n2 : d;
}
var BOT_SOURCES = /* @__PURE__ */ new Set([
  "bot",
  "bot-cloud",
  "bot_cloud",
  "background",
  "office"
]);
var CHAT_LANE_SOURCES = /* @__PURE__ */ new Set([
  "bot-chat"
]);
function chatLane(source) {
  return CHAT_LANE_SOURCES.has(String(source ?? "").toLowerCase());
}
function billSource(source, background) {
  const src = (source || "agent").toLowerCase();
  if (CHAT_LANE_SOURCES.has(src)) return src;
  return background && !BOT_SOURCES.has(src) ? "background" : src;
}
function missingFn(msg) {
  return /could not find the function|PGRST202|function .* does not exist|usage_(gate|charge)[^ ]* 404/i.test(String(msg ?? ""));
}
function entFromGate(data, s = {}) {
  if (!data || typeof data !== "object") return "error";
  if (data.enabled === false) return null;
  if (typeof data.allow !== "boolean") return "error";
  const today2 = data.allow ? Math.max(0, num(data.today_left, 0)) : 0;
  const tpm = Math.max(1, num(s.billing_live_tokens_per_minute, 4e4));
  const plan = [
    "free",
    "weekly",
    "monthly",
    "payg"
  ].includes(String(data.plan)) ? String(data.plan) : "free";
  const code = data.allow ? null : [
    "limit_daily",
    "limit_total",
    "no_plan"
  ].includes(String(data.code)) ? String(data.code) : "limit_daily";
  return {
    enabled: true,
    gate: true,
    allow: data.allow,
    code,
    reason: data.reason ?? code,
    allowance: today2,
    bg_allowance: today2,
    used_today: 0,
    ratio: today2 <= 0 ? 1 : 0,
    state: today2 <= 0 ? "limit" : "ok",
    paid: plan !== "free",
    plan,
    total_left: Math.max(0, num(data.total_left, today2)),
    resets_at: typeof data.resets_at === "string" ? data.resets_at : null,
    reply_cap: Math.max(0, num(data.reply_cap, 0)),
    live_seconds_left: Math.floor(today2 * 60 / tpm),
    tokens_per_reply: num(s.billing_tokens_per_reply, 3700),
    free: null,
    pass: null,
    pass_left: 0,
    packs: [],
    pack_left: 0
  };
}
var EAT_MS = 3 * 36e5;
function eatDay(now = Date.now()) {
  return new Date(now + EAT_MS).toISOString().slice(0, 10);
}
function nextEatMidnight(now = Date.now()) {
  const eat = new Date(now + EAT_MS);
  eat.setUTCHours(24, 0, 0, 0);
  return new Date(eat.getTime() - EAT_MS).toISOString();
}
function resetsAtHeader(fromGate, now = Date.now()) {
  const t = typeof fromGate === "string" ? Date.parse(fromGate) : NaN;
  const ms = Number.isFinite(t) && t > now ? t : Date.parse(nextEatMidnight(now));
  return new Date(ms + EAT_MS).toISOString().slice(0, 19) + "+03:00";
}
// jwt_verify.ts
var b64urlBytes = (s)=>{
  const b = atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4));
  const out = new Uint8Array(b.length);
  for(let i = 0; i < b.length; i++)out[i] = b.charCodeAt(i);
  return out;
};
var b64urlJson = (s)=>JSON.parse(new TextDecoder().decode(b64urlBytes(s)));
function makeVerifier(jwksUrl, opts = {}) {
  const fetchFn = opts.fetchFn ?? fetch;
  const now = opts.now ?? (()=>Date.now());
  const ttl = opts.ttlMs ?? 6e5;
  const timeout = opts.timeoutMs ?? 1500;
  let keys = /* @__PURE__ */ new Map();
  let fetchedAt = 0;
  let failedAt = 0;
  let inflight = null;
  const warned = /* @__PURE__ */ new Set();
  const warnOnce = (why)=>{
    if (warned.has(why)) return;
    warned.add(why);
    console.warn(JSON.stringify({
      evt: "jwt_unverified",
      reason: why
    }));
  };
  async function load() {
    try {
      const r = await fetchFn(jwksUrl, {
        signal: AbortSignal.timeout(timeout)
      });
      if (!r.ok) throw new Error("jwks " + r.status);
      const j = await r.json();
      const next = /* @__PURE__ */ new Map();
      for (const k of Array.isArray(j?.keys) ? j.keys : []){
        if (k.kty !== "EC" || k.crv !== "P-256" || !k.kid) continue;
        try {
          next.set(k.kid, await crypto.subtle.importKey("jwk", {
            kty: k.kty,
            crv: k.crv,
            x: k.x,
            y: k.y
          }, {
            name: "ECDSA",
            namedCurve: "P-256"
          }, false, [
            "verify"
          ]));
        } catch  {}
      }
      keys = next;
      fetchedAt = now();
      failedAt = 0;
    } catch  {
      failedAt = now();
    }
  }
  function refresh(force = false) {
    const fresh = fetchedAt && now() - fetchedAt < ttl;
    const coolingDown = failedAt && now() - failedAt < 6e4;
    if (fresh && !force || coolingDown) return Promise.resolve();
    if (force && fetchedAt && now() - fetchedAt < 3e4) return Promise.resolve();
    if (!inflight) inflight = load().finally(()=>{
      inflight = null;
    });
    return inflight;
  }
  async function verify(authHeader) {
    const t = (authHeader ?? "").replace(/^Bearer\s+/i, "");
    const parts = t.split(".");
    if (parts.length !== 3) return {
      uid: null,
      verified: false,
      reason: "malformed"
    };
    let payload;
    try {
      payload = b64urlJson(parts[1]);
    } catch  {
      return {
        uid: null,
        verified: false,
        reason: "malformed"
      };
    }
    const uid = payload?.role === "authenticated" && typeof payload?.sub === "string" && payload.sub ? payload.sub : null;
    if (!uid) return {
      uid: null,
      verified: false,
      reason: "not_a_user"
    };
    if (typeof payload.exp === "number" && payload.exp * 1e3 < now() - 3e4) return {
      uid: null,
      verified: false,
      reason: "expired"
    };
    let header;
    try {
      header = b64urlJson(parts[0]);
    } catch  {
      header = null;
    }
    if (header?.alg !== "ES256" || typeof header?.kid !== "string") {
      warnOnce("alg:" + String(header?.alg ?? "none"));
      return {
        uid,
        verified: false,
        reason: "unverifiable"
      };
    }
    await refresh();
    let key = keys.get(header.kid);
    if (!key) {
      await refresh(true);
      key = keys.get(header.kid);
    }
    if (!key) {
      warnOnce(fetchedAt ? "unknown_kid" : "jwks_unavailable");
      return {
        uid,
        verified: false,
        reason: "unverifiable"
      };
    }
    let ok = false;
    try {
      ok = await crypto.subtle.verify({
        name: "ECDSA",
        hash: "SHA-256"
      }, key, b64urlBytes(parts[2]), new TextEncoder().encode(parts[0] + "." + parts[1]));
    } catch  {
      ok = false;
    }
    if (!ok) return {
      uid: null,
      verified: false,
      reason: "bad_signature"
    };
    return {
      uid,
      verified: true
    };
  }
  return {
    verify,
    prefetch: ()=>{
      refresh().catch(()=>{});
    }
  };
}
// index.ts
var SB_URL = Deno.env.get("SUPABASE_URL");
var SB_SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
var REST = SB_URL + "/rest/v1";
var SH = {
  apikey: SB_SERVICE,
  authorization: `Bearer ${SB_SERVICE}`,
  "content-type": "application/json"
};
async function rpc(fn, args = {}, signal) {
  try {
    const r = await fetch(`${REST}/rpc/${fn}`, {
      method: "POST",
      headers: SH,
      body: JSON.stringify(args),
      signal
    });
    const t = await r.text();
    let j = null;
    try {
      j = t ? JSON.parse(t) : null;
    } catch  {
      j = t;
    }
    if (!r.ok) return {
      data: null,
      error: {
        message: j && typeof j === "object" && j.message || `${fn} ${r.status}`
      }
    };
    return {
      data: j,
      error: null
    };
  } catch (e) {
    return {
      data: null,
      error: {
        message: String(e)
      }
    };
  }
}
async function rows(path) {
  try {
    const r = await fetch(`${REST}/${path}`, {
      headers: SH
    });
    if (!r.ok) {
      await r.body?.cancel();
      return [];
    }
    const j = await r.json();
    return Array.isArray(j) ? j : [];
  } catch  {
    return [];
  }
}
var ISO = crypto.randomUUID().slice(0, 6);
var isoHits = 0;
var CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info, x-submac-source, x-submac-chat, x-submac-lane, x-submac-effort, x-region",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Expose-Headers": "x-submac-usage, x-submac-state, x-submac-window, x-submac-bg, x-submac-today-left, x-submac-total-left, x-submac-resets-at, x-submac-plan, x-submac-error, retry-after, server-timing"
};
var CHAT_ALIAS = "submac";
var LEGACY_ALIAS = "submac-smart";
var CFG_TTL = 6e4;
var cache = null;
function warmCfg() {
  return cache && Date.now() - cache.at < CFG_TTL ? cache.cfg : null;
}
function setCfg(c) {
  if (!c || !Array.isArray(c.aliases)) return;
  for (const a of c.aliases)for (const r of a.routes ?? [])r.keys = [];
  c.key_meta = c.key_meta ?? {};
  cache = {
    at: Date.now(),
    cfg: c
  };
}
async function config() {
  const w = warmCfg();
  if (w) return w;
  const { data, error } = await rpc("ai_config_lite");
  if (error || !data) {
    if (cache) return cache.cfg;
    throw new Error("config: " + (error?.message ?? "empty"));
  }
  setCfg(data);
  return cache.cfg;
}
var SECRET_TTL = 12e4;
var secretCache = /* @__PURE__ */ new Map();
function putSecrets(data) {
  if (!data || typeof data !== "object") return;
  for (const [pid, ks] of Object.entries(data)){
    const m = /* @__PURE__ */ new Map();
    for (const k of ks ?? [])if (k?.id && k?.key) m.set(String(k.id), String(k.key));
    secretCache.set(pid, {
      at: Date.now(),
      keys: m
    });
  }
}
function secretsFresh(pid) {
  const h = secretCache.get(pid);
  return !!h && Date.now() - h.at < SECRET_TTL;
}
function fillKeys(cfg, r) {
  const sec = secretCache.get(r.provider_id)?.keys;
  r.keys = (cfg.key_meta?.[r.provider_id] ?? []).filter((m)=>sec?.has(m.id)).map((m)=>({
      id: m.id,
      key: sec.get(m.id),
      cooldown_until: m.cooldown_until
    }));
}
async function ensureKeys(cfg, rs) {
  const need = [
    ...new Set(rs.map((r)=>r.provider_id).filter((p)=>p && !secretsFresh(p)))
  ];
  if (need.length) {
    const { data } = await rpc("ai_provider_keys", {
      p_provider_ids: need
    });
    putSecrets(data);
  }
  for (const r of rs)fillKeys(cfg, r);
}
function chatAlias(cfg) {
  return cfg.aliases.find((a)=>a.alias === CHAT_ALIAS && a.routes.length) ?? cfg.aliases.find((a)=>a.alias === LEGACY_ALIAS);
}
function capFrom(data, s) {
  const dflt = Number(s.daily_cap_tokens ?? 2e5);
  if (data && Number.isFinite(Number(data.cap))) {
    return {
      cap: Number(data.cap),
      base: Number(data.base),
      bonus: Number(data.bonus ?? 0),
      earned: Number(data.earned ?? 0),
      granted: Number(data.granted ?? 0),
      max_bonus: Number(data.max_bonus ?? 0),
      override: data.override == null ? null : Number(data.override),
      active: data.active ?? {}
    };
  }
  return {
    cap: dflt,
    base: dflt,
    bonus: 0,
    earned: 0,
    granted: 0,
    max_bonus: 0,
    override: null,
    active: {}
  };
}
var GATE_MS = 2e3;
async function gate(uid, wantConfig, needTools) {
  const { data, error } = await within(rpc("ai_gate", {
    p_uid: uid,
    p_want_config: wantConfig,
    p_alias: CHAT_ALIAS,
    p_need_tools: needTools
  }, AbortSignal.timeout(GATE_MS)), GATE_MS + 100, "gate timeout");
  if (error || !data) throw new Error("gate: " + (error?.message ?? "empty"));
  if (data.config) setCfg(data.config);
  if (data.keys) putSecrets(data.keys);
  const u = data.usage ?? {};
  return {
    blocked: data.blocked === true,
    burst: Number(data.burst ?? 0),
    usage: {
      tokens: Number(u.tokens ?? 0),
      requests: Number(u.requests ?? 0),
      bg: Number(u.bg ?? 0)
    },
    cap: capFrom(data.cap, cache?.cfg.settings ?? {}),
    router: snapFrom(data.router)
  };
}
function json(body, status = 200, extra = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...CORS,
      "content-type": "application/json",
      ...extra
    }
  });
}
function errJson(status, code, legacy, message, retry = false, extra = {}) {
  const ra = retry ? retryAfterSecs() : 0;
  return json({
    error: {
      code: legacy,
      submac_code: code,
      message: message ?? FRIENDLY[code],
      ...ra ? {
        retry_after: ra
      } : {}
    }
  }, status, {
    "x-submac-error": code,
    ...ra ? {
      "Retry-After": String(ra)
    } : {},
    ...extra
  });
}
var jwt = makeVerifier(SB_URL + "/auth/v1/.well-known/jwks.json");
jwt.prefetch();
async function userFromJwt(req) {
  const r = await jwt.verify(req.headers.get("authorization"));
  if (!r.uid && (r.reason === "bad_signature" || r.reason === "expired")) console.warn(JSON.stringify({
    evt: "jwt_refused",
    reason: r.reason
  }));
  return r.uid;
}
var UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
var internalOk = /* @__PURE__ */ new Map();
async function internalUser(req) {
  const sec = req.headers.get("x-submac-internal") ?? "";
  const u = req.headers.get("x-submac-user") ?? "";
  if (!sec || !UUID_RE.test(u)) return null;
  const t = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  let service = t.length > 20 && t === SB_SERVICE;
  if (!service) {
    try {
      service = JSON.parse(atob(t.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"))).role === "service_role";
    } catch  {
      service = false;
    }
  }
  if (!service) return null;
  if ((internalOk.get(sec) ?? 0) < Date.now()) {
    const { data } = await rpc("bot_run_check", {
      p_secret: sec
    });
    if (data !== true) return null;
    if (internalOk.size > 4) internalOk.clear();
    internalOk.set(sec, Date.now() + 3e5);
  }
  return u.toLowerCase();
}
function today() {
  return eatDay();
}
var capCache = /* @__PURE__ */ new Map();
async function capOf(uid, s) {
  const hit = capCache.get(uid);
  if (hit && Date.now() - hit.at < 3e4) return hit.c;
  const dflt = Number(s.daily_cap_tokens ?? 2e5);
  let c = {
    cap: dflt,
    base: dflt,
    bonus: 0,
    earned: 0,
    granted: 0,
    max_bonus: 0,
    override: null,
    active: {}
  };
  try {
    const { data, error } = await rpc("ai_user_cap", {
      p_uid: uid
    });
    if (!error && data && Number.isFinite(Number(data.cap))) {
      c = {
        cap: Number(data.cap),
        base: Number(data.base),
        bonus: Number(data.bonus ?? 0),
        earned: Number(data.earned ?? 0),
        granted: Number(data.granted ?? 0),
        max_bonus: Number(data.max_bonus ?? 0),
        override: data.override == null ? null : Number(data.override),
        active: data.active ?? {}
      };
    }
  } catch  {}
  if (capCache.size > 2e3) capCache.clear();
  capCache.set(uid, {
    at: Date.now(),
    c
  });
  return c;
}
function withCap(s, c) {
  return {
    ...s,
    daily_cap_tokens: c.cap
  };
}
function bonusOut(c) {
  return {
    bonus_tokens: c.bonus,
    base_tokens: c.base,
    cap_tokens: c.cap,
    earned_tokens: c.earned,
    granted_tokens: c.granted,
    max_bonus: c.max_bonus,
    referral: Number(c.active.referral ?? 0),
    creator: Number(c.active.creator ?? 0),
    admin_grant: Number(c.active.admin_grant ?? 0)
  };
}
function billingOn(s) {
  return s.billing_enabled === true || s.billing_enabled === "true";
}
function num2(v, d) {
  const n2 = Number(v);
  return v !== null && v !== void 0 && v !== "" && Number.isFinite(n2) ? n2 : d;
}
function waitLater(p) {
  globalThis.EdgeRuntime?.waitUntil?.(p);
}
var preCache = /* @__PURE__ */ new Map();
var preInflight = /* @__PURE__ */ new Map();
var PRE_CACHE_MAX = 5e3;
function preKey(uid, src) {
  return BOT_SOURCES.has(src) ? uid + "|bg" : uid;
}
function rememberEnt(key, ent) {
  preCache.delete(key);
  if (preCache.size >= PRE_CACHE_MAX) preCache.delete(preCache.keys().next().value);
  preCache.set(key, {
    ent,
    at: Date.now(),
    fresh: true,
    spent: 0,
    bgSpent: 0
  });
}
function noteSpend(uid, cost, bg) {
  for (const key of [
    uid,
    uid + "|bg"
  ]){
    const e = preCache.get(key);
    if (e) {
      e.fresh = false;
      e.spent += cost;
      if (bg) e.bgSpent += cost;
    }
  }
}
var missingLogged = false;
function logMissing(fn) {
  if (missingLogged) return;
  missingLogged = true;
  console.error(JSON.stringify({
    evt: "billing_functions_missing",
    fn,
    note: "billing_enabled is on but usage_gate/usage_charge are not deployed; old allowance applies"
  }));
}
function precheckRpc(uid, s, src) {
  const key = preKey(uid, src);
  const running = preInflight.get(key);
  if (running) return running;
  const p = (async ()=>{
    try {
      const { data, error } = await within(rpc("usage_gate", {
        p_user_id: uid,
        p_source: src
      }), Math.max(300, num2(s.billing_precheck_timeout_ms, 2e3)), "gate timeout");
      if (error && missingFn(error.message)) {
        logMissing("usage_gate");
        return null;
      }
      if (error) return "error";
      return entFromGate(data, s);
    } catch  {
      return "error";
    }
  })().finally(()=>preInflight.delete(key));
  preInflight.set(key, p);
  return p;
}
async function billingPrecheck(uid, s, legacy, src = "chat") {
  const key = preKey(uid, src);
  const c = preCache.get(key);
  if (c && c.fresh && Date.now() - c.at < Math.max(0, Math.min(6e4, num2(s.billing_precheck_cache_ms, 5e3)))) return c.ent;
  const r = await precheckRpc(uid, s, src);
  if (r === null) return null;
  if (r !== "error") {
    rememberEnt(key, r);
    return r;
  }
  return await billingFallback(key, s, legacy);
}
async function billingFallback(key, s, legacy) {
  const uid = key.split("|")[0];
  const c = preCache.get(key);
  const age = c ? Date.now() - c.at : -1;
  console.error(JSON.stringify({
    evt: "usage_gate_failed",
    uid,
    last_good_age_ms: age
  }));
  if (c && age < num2(s.billing_last_good_ms, 15 * 6e4) && c.ent.paid === true) {
    const allowance2 = Math.max(0, num2(c.ent.allowance, 0) - c.spent);
    const bg = Math.max(0, Math.min(allowance2, num2(c.ent.bg_allowance, 0) - c.bgSpent));
    return {
      ...c.ent,
      allowance: allowance2,
      bg_allowance: bg,
      used_today: num2(c.ent.used_today, 0) + c.spent,
      state: allowance2 <= 0 ? "limit" : String(c.ent.state ?? "ok"),
      live_seconds_left: Math.max(0, num2(c.ent.live_seconds_left, 0) - Math.floor(age / 1e3)),
      total_left: Math.max(0, num2(c.ent.total_left, 0) - c.spent),
      degraded: "last_good"
    };
  }
  const daily = Math.max(0, num2(s.billing_free_daily_tokens, 6e4));
  const share = Math.max(0, Math.min(1, num2(s.background_share, 0.3)));
  let used = 0, bgUsed = 0, unknown = false;
  try {
    const u = legacy ? await legacy() : await usageOrThrow(uid);
    used = u.tokens;
    bgUsed = u.bg;
  } catch  {
    unknown = true;
  }
  if (c && c.ent.paid !== true) {
    used = Math.max(used, num2(c.ent.used_today, 0) + c.spent);
  }
  const allowance = unknown ? 0 : Math.max(0, daily - used);
  const bgAllow = unknown ? 0 : Math.max(0, Math.min(allowance, Math.floor(daily * share) - bgUsed));
  return {
    enabled: true,
    gate: true,
    code: allowance <= 0 ? "limit_daily" : null,
    plan: "free",
    total_left: allowance,
    resets_at: null,
    reply_cap: 0,
    degraded: "free_fallback",
    unknown,
    paid: false,
    allowance,
    bg_allowance: bgAllow,
    used_today: used,
    ratio: allowance <= 0 ? 1 : Math.round(used / Math.max(1, used + allowance) * 1e3) / 1e3,
    state: allowance <= 0 ? "limit" : "ok",
    free: {
      daily,
      left: allowance,
      bg_left: bgAllow
    },
    pass: null,
    pass_left: 0,
    pass_today_left: 0,
    packs: [],
    pack_left: 0,
    queued_passes: [],
    live_seconds_left: 0,
    tokens_per_reply: num2(c?.ent.tokens_per_reply, 3700),
    day: null
  };
}
function multipliers() {
  return Promise.resolve([]);
}
function tierOf(_model, _rows) {
  return {
    tier: "standard",
    multiplier: 1
  };
}
var unsaved = [];
var lastFlush = 0;
async function consumeOnce(a, s) {
  try {
    const { data, error } = await within(rpc("usage_charge", a), Math.max(500, num2(s.billing_consume_timeout_ms, 8e3)), "charge timeout");
    if (error && missingFn(error.message)) {
      logMissing("usage_charge");
      return null;
    }
    if (error) return String(error.message ?? error).slice(0, 200) || "error";
    if (data && data.ok === false) {
      if (data.reason === "request_id_conflict" || data.reason === "bad_request") {
        console.error(JSON.stringify({
          evt: "billing_refused",
          uid: a.p_user_id,
          request_id: a.p_request_id,
          reason: data.reason
        }));
        return null;
      }
      return String(data.reason ?? "refused");
    }
    if (Number(data?.unpaid) > 0) {
      console.warn(JSON.stringify({
        evt: "billing_unpaid",
        uid: a.p_user_id,
        request_id: a.p_request_id,
        charged: Number(data.charged ?? 0),
        unpaid: Number(data.unpaid)
      }));
    }
    return null;
  } catch (e) {
    return String(e).slice(0, 200);
  }
}
async function enqueueCharge(a, _err) {
  try {
    const { data, error } = await within(rpc("usage_charge_enqueue", a), 5e3, "enqueue timeout");
    return !error && !!data && (data.queued === true || data.reason === "already_charged");
  } catch  {
    return false;
  }
}
function keepUnsaved(a, err) {
  if (unsaved.length >= 1e3) console.error(JSON.stringify({
    evt: "billing_lost",
    ...unsaved.shift()
  }));
  unsaved.push(a);
  console.error(JSON.stringify({
    evt: "billing_unsaved",
    ...a,
    error: err
  }));
}
function flushUnsaved(s) {
  if (!unsaved.length || Date.now() - lastFlush < 1e4) return;
  lastFlush = Date.now();
  const batch = unsaved.splice(0, 20);
  waitLater((async ()=>{
    for (const a of batch){
      const err = await consumeOnce(a, s);
      if (err !== null && !await enqueueCharge(a, err)) unsaved.push(a);
    }
  })().catch(()=>{}));
}
function billingCharge(uid, rid, tokensIn, tokensOut, source, background, s = {}) {
  const tin = Math.max(0, Math.ceil(Number(tokensIn) || 0)), tout = Math.max(0, Math.ceil(Number(tokensOut) || 0));
  if (!rid || tin + tout <= 0) return;
  noteSpend(uid, tin + tout, background);
  const a = {
    p_user_id: uid,
    p_tokens_in: tin,
    p_tokens_out: tout,
    p_source: billSource(source, background),
    p_request_id: rid
  };
  waitLater((async ()=>{
    let err = "";
    for(let i = 0; i < 2; i++){
      const e = await consumeOnce(a, s);
      if (e === null) return;
      err = e;
      if (i === 0) await new Promise((ok)=>setTimeout(ok, Math.max(0, num2(s.billing_retry_delay_ms, 200))));
    }
    if (await enqueueCharge(a, err)) {
      console.warn(JSON.stringify({
        evt: "billing_queued",
        uid,
        request_id: rid,
        error: err
      }));
      return;
    }
    keepUnsaved(a, err);
  })().catch(()=>{}));
}
function billState(e, extraUsed = 0) {
  const allowance = Math.max(0, Number(e.allowance ?? 0) - extraUsed);
  const used = Number(e.used_today ?? 0) + extraUsed;
  const ratio = allowance <= 0 ? 1 : Math.min(1, used / Math.max(1, used + allowance));
  return {
    cap: used + allowance,
    used,
    ratio,
    state: allowance <= 0 ? "limit" : String(e.state ?? "ok"),
    allowance
  };
}
function eatReset() {
  return nextEatMidnight();
}
function eatMonthReset() {
  const eat = new Date(Date.now() + EAT_MS);
  return new Date(Date.UTC(eat.getUTCFullYear(), eat.getUTCMonth() + 1, 1) - EAT_MS).toISOString();
}
function inWords(iso) {
  const m = Math.max(1, Math.round((Date.parse(iso) - Date.now()) / 6e4));
  if (m >= 48 * 60) return `${Math.round(m / 1440)} days`;
  const h = Math.floor(m / 60), mm = m % 60;
  return h ? mm ? `${h} h ${mm} min` : `${h} h` : `${mm} min`;
}
function balanceHeaders(ent, st) {
  const today2 = Math.max(0, Math.floor(st.cap - st.used));
  let total = today2, plan = "free";
  if (ent?.gate) {
    const spent = Math.max(0, num2(ent.allowance, 0) - today2);
    total = Math.max(today2, Math.floor(num2(ent.total_left, today2) - spent));
    const reset = resetsAtHeader(ent.resets_at);
    return {
      "x-submac-today-left": String(today2),
      "x-submac-total-left": String(total),
      "x-submac-resets-at": reset,
      "x-submac-plan": String(ent.plan ?? "free")
    };
  }
  if (ent) {
    const parts = [
      ent.pass_left,
      ent.pack_left,
      ent.free?.left
    ].filter((v)=>v !== void 0 && v !== null).map(Number).filter(Number.isFinite);
    if (parts.length) total = Math.max(today2, Math.floor(parts.reduce((a, b)=>a + b, 0)));
    if (ent.pass) plan = /week/i.test(String(ent.pass.product ?? ent.pass.name ?? "")) ? "weekly" : "monthly";
    else if (Number(ent.pack_left ?? 0) > 0) plan = "payg";
  }
  return {
    "x-submac-today-left": String(today2),
    "x-submac-total-left": String(total),
    "x-submac-resets-at": resetsAtHeader(),
    "x-submac-plan": plan
  };
}
var BAL_EXPOSE = CORS["Access-Control-Expose-Headers"] + ", x-submac-balance";
function balHdr(n2) {
  return {
    "x-submac-balance": String(Math.max(0, Math.floor(n2))),
    "Access-Control-Expose-Headers": BAL_EXPOSE
  };
}
var BUY_OPTIONS = [
  {
    plan: "weekly",
    kind: "package",
    name: "Weekly"
  },
  {
    plan: "monthly",
    kind: "package",
    name: "Monthly"
  },
  {
    plan: "payg",
    kind: "payg",
    name: "Pay as you go"
  }
];
function billingOut(e, s = {}) {
  const month = e.paid !== true && e.free && Number(e.free.monthly) > 0 && Number(e.free.month_used ?? 0) >= Number(e.free.monthly);
  const resets = month ? eatMonthReset() : eatReset();
  return {
    enabled: true,
    allowance: Number(e.allowance ?? 0),
    bg_allowance: Number(e.bg_allowance ?? 0),
    used_today: Number(e.used_today ?? 0),
    ratio: Number(e.ratio ?? 0),
    state: e.state ?? "ok",
    paid: e.paid === true,
    free: e.free ?? null,
    pass: e.pass ?? null,
    pass_left: Number(e.pass_left ?? 0),
    pass_today_left: Number(e.pass_today_left ?? 0),
    packs: e.packs ?? [],
    pack_left: Number(e.pack_left ?? 0),
    queued_passes: e.queued_passes ?? [],
    live_seconds_left: Number(e.live_seconds_left ?? 0),
    tokens_per_reply: Number(e.tokens_per_reply ?? 3700),
    auto_exchange: e.auto_exchange === true,
    day: e.day ?? null,
    resets_at: resets,
    resets_at_eat: month ? "1st of next month, 00:00 EAT" : "00:00 EAT",
    resets_in_seconds: Math.max(0, Math.round((Date.parse(resets) - Date.now()) / 1e3)),
    degraded: e.degraded ?? null,
    buy: Array.isArray(s.billing_buy_options) ? s.billing_buy_options : BUY_OPTIONS
  };
}
function billErr(status, code, message, e, s, reason, more = {}, hdrs = {}, balance = 0) {
  return json({
    error: {
      code,
      message
    },
    message,
    billing: {
      ...billingOut(e, s),
      reason
    },
    ...more
  }, status, {
    ...balHdr(balance),
    ...hdrs
  });
}
function limitReply(e, s, hdrs = {}) {
  if (e.gate) {
    const code = e.code === "limit_total" || e.code === "no_plan" ? e.code : "limit_daily";
    let msg2 = FRIENDLY[code];
    if (e.degraded === "free_fallback") msg2 += " (We couldn't confirm your plan just now. If you have one, try again in a minute.)";
    if (typeof s.billing_limit_message === "string" && s.billing_limit_message) msg2 = s.billing_limit_message;
    return billErr(429, code, msg2, e, s, String(e.reason ?? code), {}, {
      ...hdrs,
      "x-submac-error": code
    });
  }
  const out = billingOut(e, s);
  let reason, msg;
  if (e.paid !== true && out.resets_at_eat !== "00:00 EAT") {
    reason = "free_month_used";
    msg = "You've used this month's free allowance. It comes back on the 1st at 00:00 EAT. Get a pass or a token pack to keep going now.";
  } else if (e.paid !== true) {
    reason = "free_day_used";
    msg = `You've used today's free allowance. It comes back at midnight (00:00 EAT), in about ${inWords(out.resets_at)}. Get a pass or a token pack to keep going now.`;
  } else {
    reason = "pass_day_used";
    msg = `You've reached today's limit on your ${String(e.pass?.name ?? "pass")}. It resets at midnight (00:00 EAT), in about ${inWords(out.resets_at)}. A token pack keeps you going now.`;
  }
  if (e.degraded === "free_fallback") msg += " (We couldn't confirm a pass or pack just now. If you have one, try again in a minute.)";
  if (typeof s.billing_limit_message === "string" && s.billing_limit_message) msg = s.billing_limit_message;
  return billErr(429, "daily_limit", msg, e, s, reason, {}, hdrs);
}
async function pendingPayment(uid, s) {
  try {
    const { data, error } = await within(rpc("billing_payment_pending", {
      p_older_than_minutes: 0,
      p_since_hours: 1,
      p_limit: 100
    }), 2e3, "pending timeout");
    if (error || !Array.isArray(data)) return null;
    const win = num2(s.billing_pending_window_min, 30) * 6e4;
    return data.filter((p)=>p?.user_id === uid && Date.now() - Date.parse(p.created_at) < win).pop() ?? null;
  } catch  {
    return null;
  }
}
var PENDING_MSG = "Your payment is still being confirmed. This usually takes a minute or two, and your balance updates as soon as it's confirmed. If you didn't finish paying, you can try again from your wallet.";
async function emptyReply(uid, e, s, hdrs = {}) {
  if (e.unknown) {
    return billErr(503, "busy", "Couldn't check your balance just now. Please try again in a moment.", e, s, "billing_unavailable", {}, {
      ...hdrs,
      "Retry-After": "20"
    });
  }
  const p = e.degraded ? null : await pendingPayment(uid, s);
  if (p) {
    return billErr(429, "payments_pending", PENDING_MSG, e, s, "payment_confirming", {
      pending: {
        purchase_id: p.id,
        created_at: p.created_at
      },
      retry_after_seconds: 30
    }, {
      ...hdrs,
      "Retry-After": "30"
    });
  }
  return limitReply(e, s, hdrs);
}
function replyCap(balance, mult, promptTokens, s, gateCap = 0) {
  const { wIn, wOut } = weightsOf(s);
  const room = Math.floor((balance / Math.max(0.01, mult) - promptTokens * wIn) / Math.max(0.01, wOut));
  const capped = gateCap > 0 ? Math.min(room, gateCap) : room;
  return Math.max(Math.max(1, num2(s.billing_min_reply_tokens, 512)), capped);
}
var NO_BALANCE = "You've used your allowance for now. Get a pass or a token pack to keep going, or wait for tomorrow's free allowance.";
var CALL_BALANCE = "Your call time is used up. Get a pass or a token pack to keep calling. You can still type to SubMac.";
var BG_PAUSED = "Background tasks are paused until midnight (00:00 EAT) to save your allowance. Your own chats still work.";
var liveLeftCache = /* @__PURE__ */ new Map();
function liveLeftGuess(uid, s) {
  const c = liveLeftCache.get(uid);
  const grace = Math.max(60, num2(s.billing_live_grace_seconds, 300));
  if (!c) return grace;
  return Math.max(grace, c.left - Math.floor((Date.now() - c.at) / 1e3));
}
async function usageOrThrow(uid) {
  const r = await fetch(`${REST}/ai_user_daily?select=tokens,requests,bg_tokens&user_id=eq.${uid}&day=eq.${today()}&limit=1`, {
    headers: SH
  });
  if (!r.ok) {
    await r.body?.cancel();
    throw new Error("usage " + r.status);
  }
  const j = await r.json();
  const data = Array.isArray(j) ? j[0] : null;
  return {
    tokens: Number(data?.tokens ?? 0),
    requests: Number(data?.requests ?? 0),
    bg: Number(data?.bg_tokens ?? 0)
  };
}
async function insertRow(table, row) {
  try {
    const r = await fetch(`${REST}/${table}`, {
      method: "POST",
      headers: {
        ...SH,
        prefer: "return=representation"
      },
      body: JSON.stringify(row)
    });
    const j = await r.json().catch(()=>null);
    if (!r.ok) return {
      data: null,
      error: {
        message: j && j.message || `${table} ${r.status}`
      }
    };
    return {
      data: Array.isArray(j) ? j[0] ?? null : j,
      error: null
    };
  } catch (e) {
    return {
      data: null,
      error: {
        message: String(e)
      }
    };
  }
}
var SCREEN = [
  [
    "minor_sexual",
    /\b(child|children|minor|underage|kid|kids|preteen|\d{1,2}[ -]?(?:yo|y\/o|years?[ -]old))\b[\s\S]{0,80}\b(sex|sexual|nude|naked|porn|explicit|erotic)|\b(sex|sexual|nude|naked|porn|explicit|erotic)\b[\s\S]{0,80}\b(child|children|minor|underage|kid|kids|preteen|\d{1,2}[ -]?(?:yo|y\/o|years?[ -]old))\b/i
  ],
  [
    "fraud_scam",
    /\b(phishing|scam (?:people|someone|victims|them)|fake (?:invoice|bank|id|passport|login page|receipt|reviews?)|steal (?:credit cards?|cards?|passwords?|accounts?|identit(?:y|ies))|carding|cvv|money mule|launder(?:ing)? (?:the )?money|ponzi|pump and dump|sim swap)\b/i
  ],
  [
    "illegal",
    /\b(make (?:a )?(?:bomb|explosives?|meth|methamphetamine|ricin)|buy (?:drugs|cocaine|heroin|fentanyl)|untraceable (?:gun|weapon)|ghost gun|hire (?:a )?hit ?man|human trafficking|smuggl(?:e|ing) (?:people|drugs))\b/i
  ],
  [
    "abuse_harassment",
    /\b(dox(?:x)?(?:ing)?|threaten(?:ing)? to (?:kill|hurt|rape)|i will (?:kill|hurt|rape) (?:you|him|her|them)|harass(?:ment)? campaign|revenge porn|stalk(?:ing)? (?:my ex|her|him))\b/i
  ],
  [
    "self_harm",
    /\b(kill myself|suicid(?:e|al)|end my life|self[- ]harm|cut myself|want to die)\b/i
  ],
  [
    "spam_automation",
    /\b(mass (?:dm|dms|message|messages|email|emails)|spam (?:bot|messages|people)|bulk (?:sms|email)s?|fake (?:accounts|followers|likes) (?:bot|farm))\b/i
  ]
];
var CATS = [
  "fraud_scam",
  "illegal",
  "abuse_harassment",
  "minor_sexual",
  "self_harm",
  "spam_automation"
];
var lastScreen = /* @__PURE__ */ new Map();
function lastUserText(messages) {
  for(let i = messages.length - 1; i >= 0; i--){
    const m = messages[i];
    if (m?.role !== "user") continue;
    if (typeof m.content === "string") return m.content.slice(0, 4e3);
    if (Array.isArray(m.content)) return m.content.filter((c)=>c?.type === "text").map((c)=>String(c.text ?? "")).join(" ").slice(0, 4e3);
    return "";
  }
  return "";
}
function screenLater(uid, messages, cfg) {
  const s = cfg.settings;
  if (s.moderation_enabled === false) return;
  const text = lastUserText(messages);
  if (text.length < 8) return;
  const hit = SCREEN.find(([, re])=>re.test(text));
  if (!hit) return;
  if ((lastScreen.get(uid) ?? 0) > Date.now() - 2e4) return;
  if (lastScreen.size > 5e3) lastScreen.clear();
  lastScreen.set(uid, Date.now());
  const job = (async ()=>{
    let cat = hit[0], sev = cat === "minor_sexual" ? "high" : "low", reason = "Keyword screen: possible " + cat.replace("_", " ");
    if (s.moderation_model_check !== false) {
      const v = await classify(text, cfg);
      if (v === null) {} else if (v.category === "none") return;
      else {
        cat = v.category;
        sev = v.severity;
        reason = v.reason;
      }
    }
    await rpc("flag_user", {
      p_uid: uid,
      p_category: cat,
      p_severity: sev,
      p_source: "moderation",
      p_reason: reason.slice(0, 200),
      p_meta: {
        rule: hit[0]
      }
    });
  })().catch(()=>{});
  globalThis.EdgeRuntime?.waitUntil?.(job);
}
async function classify(text, cfg) {
  const alias = chatAlias(cfg);
  if (!alias) return null;
  const sys = `You are a safety reviewer for an AI assistant app. Decide if the user's message asks for or describes: fraud_scam, illegal (serious crime, weapons, drugs), abuse_harassment, minor_sexual (any sexual content involving minors), self_harm (the user may hurt themselves), spam_automation, or none. Ordinary questions, fiction, news, safety advice and victims asking for help are none. Reply with JSON only: {"category":"<one of the labels>","severity":"low|medium|high","reason":"<at most 12 words describing the behaviour; never quote the message>"}`;
  for (const r of alias.routes.filter((x)=>x.healthy).concat(alias.routes.filter((x)=>!x.healthy)).slice(0, 2)){
    await ensureKeys(cfg, [
      r
    ]);
    for (const k of keysInOrder(r).slice(0, 1)){
      try {
        const ctl = new AbortController();
        const t = setTimeout(()=>ctl.abort(), 1e4);
        const res = await fetch(r.base_url.replace(/\/$/, "") + "/chat/completions", {
          method: "POST",
          signal: ctl.signal,
          headers: {
            "content-type": "application/json",
            authorization: `Bearer ${k.key}`,
            "user-agent": "submac-proxy/1"
          },
          body: JSON.stringify({
            ...r.extra_body ?? {},
            model: r.model,
            max_tokens: 120,
            temperature: 0,
            messages: [
              {
                role: "system",
                content: sys
              },
              {
                role: "user",
                content: text.slice(0, 1500)
              }
            ]
          })
        });
        clearTimeout(t);
        if (!res.ok) {
          markKey(k.id, false, `moderation ${res.status}`, cooldownFor(res.status));
          continue;
        }
        const j = await res.json();
        record({
          user_id: null,
          source: "moderation",
          alias: alias.alias,
          provider: r.provider,
          model: r.model,
          key_id: k.id,
          status: 200,
          prompt_tokens: j.usage?.prompt_tokens ?? 0,
          completion_tokens: j.usage?.completion_tokens ?? 0,
          quota_tokens: 0
        });
        const out = String(j.choices?.[0]?.message?.content ?? "");
        const m = out.match(/\{[\s\S]*\}/);
        if (!m) continue;
        const v = JSON.parse(m[0]);
        const category = CATS.includes(v.category) ? v.category : "none";
        const severity = [
          "low",
          "medium",
          "high"
        ].includes(v.severity) ? v.severity : "low";
        return {
          category,
          severity: category === "minor_sexual" ? "high" : severity,
          reason: String(v.reason ?? "").replace(/["“”]/g, "").slice(0, 120) || category
        };
      } catch  {}
    }
  }
  return null;
}
async function usageOf(uid) {
  const data = (await rows(`ai_user_daily?select=tokens,requests,bg_tokens&user_id=eq.${uid}&day=eq.${today()}&limit=1`))[0];
  return {
    tokens: Number(data?.tokens ?? 0),
    requests: Number(data?.requests ?? 0),
    bg: Number(data?.bg_tokens ?? 0)
  };
}
function backgroundFor(used, bgUsed, s) {
  const cap = Number(s.daily_cap_tokens ?? 2e5);
  let share = Number(s.background_share ?? 0.3);
  if (!Number.isFinite(share)) share = 0.3;
  share = Math.max(0, Math.min(1, share));
  const shareCap = Math.floor(cap * share);
  const left = Math.max(0, Math.min(shareCap - bgUsed, cap - used));
  return {
    share,
    cap: shareCap,
    used: bgUsed,
    left,
    ratio: shareCap > 0 ? Math.min(1, bgUsed / shareCap) : 1,
    paused: left <= 0
  };
}
function stateFor(used, s) {
  const cap = Number(s.daily_cap_tokens ?? 2e5);
  const grace = Number(s.grace_tokens ?? 0);
  const soft = Number(s.soft_notice_ratio ?? 0.8);
  const ratio = cap > 0 ? used / cap : 0;
  const state = used >= cap + grace ? "limit" : used >= cap ? "light" : ratio >= soft ? "notice" : "ok";
  return {
    cap,
    used,
    ratio: Math.min(1, ratio),
    state
  };
}
function hasImages(messages) {
  return messages?.some((m)=>Array.isArray(m?.content) && m.content.some((c)=>c?.type === "image_url" || c?.type === "input_image"));
}
var JUNK = /<\s*\/?\s*｜[^>]{0,80}>|<\|(?:tool_call|im_start|im_end|end)[^>\n]{0,40}\|>/g;
function clean(t) {
  return t.replace(JUNK, "");
}
function estimateTokens(v) {
  return Math.ceil(JSON.stringify(v ?? "").length / 4);
}
function cachedOf(usage) {
  const u = usage ?? {};
  const v = [
    u.prompt_tokens_details?.cached_tokens,
    u.input_tokens_details?.cached_tokens,
    u.cached_tokens,
    u.prompt_cache_hit_tokens,
    u.cachedContentTokenCount,
    u.cached_content_token_count,
    u.cache_read_input_tokens
  ].map(Number).find((x)=>Number.isFinite(x) && x > 0);
  return v ? Math.floor(v) : 0;
}
function weightsOf(s) {
  const w = (v, d)=>{
    const n2 = Number(v);
    return v !== null && v !== void 0 && v !== "" && Number.isFinite(n2) && n2 >= 0 ? n2 : d;
  };
  return {
    wIn: w(s.input_weight, 0.3),
    wOut: w(s.output_weight, 1),
    wCache: w(s.cached_weight, 0.1)
  };
}
function quotaOf(s, pt, ct, usage) {
  const { wIn, wOut, wCache } = weightsOf(s);
  const p = Math.max(0, Number(pt) || 0), c = Math.max(0, Number(ct) || 0);
  const cached = Math.min(p, cachedOf(usage));
  return Math.ceil((p - cached) * wIn + cached * wCache + c * wOut);
}
function chargeSplit(s, w, ct) {
  const total = Math.max(1, Math.ceil(Number(w) || 0));
  const out = Math.min(total, Math.ceil(Math.max(0, Number(ct) || 0) * weightsOf(s).wOut));
  return {
    tin: total - out,
    tout: out,
    total
  };
}
function record(p) {
  const job = rpc("ai_record_usage", {
    p
  }).then(()=>{}, ()=>{});
  globalThis.EdgeRuntime?.waitUntil?.(job);
}
function markKey(id, ok, error, cooldown) {
  if (!ok && cooldown > 0) localCooldown.set(id, Date.now() + cooldown * 1e3);
  if (ok) localCooldown.delete(id);
  const job = rpc("ai_mark_key", {
    p_key_id: id,
    p_ok: ok,
    p_error: error ?? "",
    p_cooldown_seconds: cooldown
  }).then(()=>{}, ()=>{});
  globalThis.EdgeRuntime?.waitUntil?.(job);
}
function cleanHistory(list) {
  const out = [];
  for(let i = 0; i < list.length; i++){
    const m = list[i];
    if (!m || typeof m !== "object") continue;
    if (m.role === "assistant" && Array.isArray(m.tool_calls) && m.tool_calls.length) {
      const calls = m.tool_calls.filter((c)=>c && c.id && c.function?.name).map((c)=>{
        let a = c.function.arguments;
        if (typeof a !== "string") a = JSON.stringify(a ?? {});
        try {
          const v = JSON.parse(a.trim() || "{}");
          if (!v || typeof v !== "object" || Array.isArray(v)) a = "{}";
          else if (!a.trim()) a = "{}";
        } catch  {
          a = "{}";
        }
        return {
          ...c,
          type: "function",
          function: {
            ...c.function,
            arguments: a
          }
        };
      });
      if (!calls.length) {
        const { tool_calls: _t, ...rest } = m;
        if (rest.content) out.push(rest);
        continue;
      }
      out.push({
        ...m,
        tool_calls: calls
      });
      const ids = new Set(calls.map((c)=>c.id));
      const results = [];
      let j = i + 1;
      while(j < list.length && list[j]?.role === "tool"){
        if (ids.has(list[j].tool_call_id)) {
          results.push(list[j]);
          ids.delete(list[j].tool_call_id);
        }
        j++;
      }
      out.push(...results);
      for (const id of ids)out.push({
        role: "tool",
        tool_call_id: id,
        content: "Not run."
      });
      i = j - 1;
      continue;
    }
    if (m.role === "tool") continue;
    out.push(m);
  }
  return out;
}
var routeCap = /* @__PURE__ */ new Map();
function within(p, ms, what) {
  let t;
  return Promise.race([
    p,
    new Promise((_, rej)=>{
      t = setTimeout(()=>rej(new Error(what)), ms);
    })
  ]).finally(()=>clearTimeout(t));
}
function features(cfg) {
  const s = cfg.settings;
  const has = (a)=>!!cfg.aliases.find((x)=>x.alias === a && x.routes.length);
  return {
    live: s.live_enabled !== false && !!s.live_provider,
    transcribe: s.transcribe_enabled !== false && !!s.live_provider,
    image: has("submac-image"),
    video: false,
    live_voices: [
      "Kore",
      "Puck",
      "Charon",
      "Aoede",
      "Fenrir",
      "Leda",
      "Orus",
      "Zephyr"
    ]
  };
}
async function providerKeys(name) {
  const p = (await rows(`ai_providers?select=id&name=eq.${encodeURIComponent(name)}&enabled=eq.true&limit=1`))[0];
  if (!p) return [];
  const ks = await rows(`ai_keys?select=id,cooldown_until&provider_id=eq.${p.id}&enabled=eq.true`);
  const now = Date.now();
  const usable = (ks ?? []).filter((k)=>!(k.cooldown_until && Date.parse(k.cooldown_until) > now) && (localCooldown.get(k.id) ?? 0) < now);
  usable.sort(()=>Math.random() - 0.5);
  const out = [];
  for (const k of usable.slice(0, 4)){
    const { data } = await rpc("ai_key_secret", {
      p_key_id: k.id
    });
    if (data?.key) out.push({
      id: k.id,
      key: data.key
    });
  }
  return out;
}
async function liveRoutes() {
  const lrows = await rows("live_routes?select=id,provider,model,priority,cooldown_until,created_at&enabled=eq.true&order=priority.asc,created_at.asc");
  const now = Date.now();
  return (lrows ?? []).filter((r)=>r.provider === "Google Gemini" && !(r.cooldown_until && Date.parse(r.cooldown_until) > now) && (localCooldown.get("live:" + r.id) ?? 0) < now).slice(0, 6).map((r)=>({
      id: r.id,
      model: r.model ?? null,
      provider: r.provider
    }));
}
function liveCooldown(status, text) {
  if (status === 429) return /quota|exhaust|per day|daily/i.test(text) ? 3600 : 60;
  if (status === 400 && /api key|API_KEY/i.test(text)) return 3600;
  return cooldownFor(status);
}
function markLive(id, ok, error, cooldown) {
  if (!ok && cooldown > 0) localCooldown.set("live:" + id, Date.now() + cooldown * 1e3);
  if (ok) localCooldown.delete("live:" + id);
  const job = rpc("live_mark_route", {
    p_id: id,
    p_ok: ok,
    p_error: error ?? "",
    p_cooldown_seconds: cooldown
  }).then(()=>{}, ()=>{});
  globalThis.EdgeRuntime?.waitUntil?.(job);
}
var HEARTBEAT_S = 30;
function numOrNull(v) {
  const n2 = Number(v);
  return Number.isFinite(n2) && n2 >= 0 ? Math.floor(Math.min(n2, 86400)) : null;
}
function minutesUsedMessage() {
  return "Today's call minutes are used up. They come back at midnight UTC. You can still type to SubMac.";
}
function minsOut(m) {
  return {
    minutes_left: Number(m.minutes_left ?? 0),
    seconds_left: Number(m.seconds_left ?? 0),
    limit_minutes: Number(m.limit_minutes ?? 0),
    used_seconds: Number(m.used_seconds ?? 0),
    live_enabled: m.enabled !== false,
    resets_at: m.resets_at ?? null
  };
}
async function minutesOf(uid) {
  const { data } = await rpc("live_minutes_left", {
    p_uid: uid
  });
  return data ?? {};
}
async function liveUsage(uid, body, billing = false, s = {}) {
  const cid = typeof body?.call_id === "string" ? body.call_id : "";
  if (!cid) return json({
    error: {
      code: "bad_request",
      message: "call_id needed"
    }
  }, 400);
  const { data, error } = await rpc("live_call_beat", {
    p_uid: uid,
    p_call: cid,
    p_reported: numOrNull(body.seconds),
    p_kind: body?.end === true ? "end" : "beat"
  });
  if (error) return json({
    error: {
      code: "busy",
      message: "Couldn't save call time just now."
    }
  }, 503);
  const m = data;
  if (billing) {
    const charged = m.reason === "no_call" ? null : await liveCharge(uid, cid, m, s);
    if (charged === "error") {
      const guess = liveLeftGuess(uid, s);
      return json({
        ok: m.ok !== false,
        reason: m.reason ?? null,
        call_id: cid,
        call_seconds: Number(m.call_seconds ?? 0),
        added_seconds: Number(m.added_seconds ?? 0),
        stop: m.enabled === false && body?.end !== true,
        ...liveMinsOut(m, guess),
        billing_degraded: true,
        message: m.enabled === false && body?.end !== true ? minutesUsedMessage() : null
      }, 200, balHdr(guess));
    }
    const left = charged;
    if (left !== null) {
      const ending = body?.end === true;
      const stop = !ending && (m.enabled === false || left <= 0);
      return json({
        ok: m.ok !== false,
        reason: m.reason ?? null,
        call_id: cid,
        call_seconds: Number(m.call_seconds ?? 0),
        added_seconds: Number(m.added_seconds ?? 0),
        stop,
        ...liveMinsOut(m, left),
        message: stop ? m.enabled === false ? minutesUsedMessage() : CALL_BALANCE : null
      }, 200, balHdr(left));
    }
    return json({
      ok: m.ok !== false,
      reason: m.reason ?? null,
      call_id: cid,
      call_seconds: Number(m.call_seconds ?? 0),
      added_seconds: Number(m.added_seconds ?? 0),
      stop: m.enabled === false && body?.end !== true,
      ...minsOut(m),
      message: null
    }, m.reason === "no_call" ? 404 : 200);
  }
  return json({
    ok: m.ok !== false,
    reason: m.reason ?? null,
    call_id: cid,
    call_seconds: Number(m.call_seconds ?? 0),
    added_seconds: Number(m.added_seconds ?? 0),
    stop: m.stop === true || m.enabled === false && body?.end !== true,
    ...minsOut(m),
    message: m.stop ? minutesUsedMessage() : null
  }, m.reason === "no_call" ? 404 : 200);
}
async function liveCharge(uid, callId, m, s = {}) {
  const added = Math.max(0, Math.floor(Number(m.added_seconds ?? 0)));
  const tpm = Math.max(1, num2(s.billing_live_tokens_per_minute, 4e4));
  const a = {
    p_user_id: uid,
    p_tokens_in: added,
    p_tokens_out: 0,
    p_source: "live",
    p_request_id: `live:${callId}:${Number(m.call_seconds ?? 0)}`
  };
  let lastErr = "";
  for(let i = 0; i < 2; i++){
    let data = null, error = null;
    if (added > 0) {
      ({ data, error } = await within(rpc("usage_charge", a), 5e3, "live charge timeout").then((x)=>x, (e)=>({
          data: null,
          error: {
            message: String(e)
          }
        })));
    } else {
      ({ data, error } = await within(rpc("usage_gate", {
        p_user_id: uid,
        p_source: "live"
      }), 3e3, "live gate timeout").then((x)=>x, (e)=>({
          data: null,
          error: {
            message: String(e)
          }
        })));
      if (data && typeof data === "object" && data.allow === false) data = {
        ...data,
        today_left: 0
      };
    }
    if (error && missingFn(error.message)) {
      logMissing("usage_charge");
      return null;
    }
    if (!error && data && data.enabled === false) return null;
    if (!error && data && data.ok !== false && Number.isFinite(Number(data.today_left))) {
      const left = Math.max(0, Math.floor(Number(data.today_left) * 60 / tpm));
      liveLeftCache.delete(uid);
      if (liveLeftCache.size >= PRE_CACHE_MAX) liveLeftCache.delete(liveLeftCache.keys().next().value);
      liveLeftCache.set(uid, {
        left,
        at: Date.now()
      });
      return left;
    }
    lastErr = error ? String(error.message ?? error).slice(0, 200) : String(data?.reason ?? "refused");
  }
  if (added > 0) {
    if (await enqueueCharge(a, lastErr)) console.warn(JSON.stringify({
      evt: "billing_queued",
      uid,
      request_id: a.p_request_id,
      error: lastErr
    }));
    else keepUnsaved(a, lastErr);
  }
  return "error";
}
function liveMinsOut(m, left) {
  return {
    ...minsOut(m),
    minutes_left: Math.floor(left / 60),
    seconds_left: left,
    limit_minutes: Math.floor(left / 60),
    billing: true
  };
}
async function mediaRoute(req, url, uid, cfg) {
  const s = cfg.settings;
  if (s.kill_switch === true) return json({
    error: {
      code: "paused",
      message: "SubMac is taking a short break. Please try again in a few minutes."
    }
  }, 503);
  const blocked = (await rows(`ai_blocked_users?select=user_id&user_id=eq.${uid}&limit=1`)).length > 0;
  if (blocked) return json({
    error: {
      code: "blocked",
      message: "Your account needs attention. Please contact support."
    }
  }, 403);
  const feat = features(cfg);
  const t0 = Date.now();
  let body = {};
  try {
    body = await req.json();
  } catch  {}
  const bill = billingOn(s);
  if (url.pathname.endsWith("/live-usage")) return await liveUsage(uid, body, bill, s);
  if (url.pathname.endsWith("/live-token")) {
    if (!feat.live) return json({
      error: {
        code: "unavailable",
        message: "Live voice isn't available right now."
      }
    }, 503);
    const resume = body?.resume === true && typeof body?.call_id === "string" && body.call_id.length > 0;
    let mins;
    let billLeft = null;
    let liveEnt = null;
    if (resume) {
      const { data, error } = await rpc("live_call_beat", {
        p_uid: uid,
        p_call: body.call_id,
        p_reported: numOrNull(body.seconds),
        p_kind: "resume"
      });
      if (error) return json({
        error: {
          code: "busy",
          message: "Live voice is busy right now. Please try again in a moment."
        }
      }, 503);
      mins = data;
      if (!mins.ok) return json({
        error: {
          code: "call_ended",
          message: "This call has ended. Tap Call again to start a new one."
        },
        ...minsOut(mins)
      }, 409);
      if (bill) {
        const c = await liveCharge(uid, String(body.call_id), mins, s);
        billLeft = c === "error" ? liveLeftGuess(uid, s) : c;
      }
    } else {
      const [{ data, error }, ent0] = await Promise.all([
        rpc("live_call_start", {
          p_uid: uid
        }),
        bill ? billingPrecheck(uid, s, void 0, "live") : Promise.resolve(null)
      ]);
      if (error) return json({
        error: {
          code: "busy",
          message: "Live voice is busy right now. Please try again in a moment."
        }
      }, 503);
      mins = data;
      const ent2 = ent0 && ent0.degraded === "free_fallback" ? null : ent0;
      liveEnt = ent2;
      if (ent2) {
        billLeft = Math.max(0, Number(ent2.live_seconds_left ?? 0));
        if (mins.ok === false && mins.reason === "minutes_used" && mins.enabled !== false && billLeft > 0) {
          const { data: row, error: e2 } = await insertRow("live_calls", {
            user_id: uid
          });
          if (e2 || !row?.id) return json({
            error: {
              code: "busy",
              message: "Live voice is busy right now. Please try again in a moment."
            }
          }, 503);
          mins = {
            ...mins,
            ok: true,
            call_id: row.id
          };
        }
      }
    }
    if (mins.enabled === false) return json({
      error: {
        code: "live_off",
        message: "Calls are switched off for your account. You can still type to SubMac."
      },
      ...minsOut(mins),
      minutes_left: 0,
      seconds_left: 0
    }, 429);
    if (billLeft !== null) {
      if (billLeft <= 0) {
        if (!resume && mins.call_id) await rpc("live_call_beat", {
          p_uid: uid,
          p_call: mins.call_id,
          p_reported: 0,
          p_kind: "end"
        });
        if (liveEnt) {
          const p = liveEnt.degraded ? null : await pendingPayment(uid, s);
          if (p) return billErr(429, "payments_pending", PENDING_MSG, liveEnt, s, "payment_confirming", {
            ...liveMinsOut(mins, 0),
            pending: {
              purchase_id: p.id,
              created_at: p.created_at
            },
            retry_after_seconds: 30
          }, {
            "Retry-After": "30"
          });
          return billErr(429, "call_minutes", CALL_BALANCE, liveEnt, s, "live_balance_used", liveMinsOut(mins, 0));
        }
        return json({
          error: {
            code: "call_minutes",
            message: CALL_BALANCE
          },
          message: CALL_BALANCE,
          ...liveMinsOut(mins, 0)
        }, 429, balHdr(0));
      }
      mins = {
        ...mins,
        seconds_left: billLeft,
        minutes_left: Math.floor(billLeft / 60)
      };
    } else if (Number(mins.seconds_left) <= 0) return json({
      error: {
        code: "call_minutes",
        message: minutesUsedMessage()
      },
      ...minsOut(mins),
      minutes_left: 0,
      seconds_left: 0
    }, 429);
    const callId = String(mins.call_id ?? body.call_id ?? "");
    const defModel = String(s.live_model ?? "gemini-3.8-live");
    const sessionMins = Number(s.live_session_minutes ?? 15);
    const passSecs = Math.max(60, Math.min(sessionMins * 60, Number(mins.seconds_left) + 60));
    const tLive = Date.now();
    for (const lr of (await liveRoutes())){
      const left = 12e3 - (Date.now() - tLive);
      if (left < 500 || req.signal.aborted) break;
      const sec = await within(rpc("live_route_secret", {
        p_id: lr.id
      }, AbortSignal.timeout(Math.min(3e3, left))), Math.min(3e3, left) + 100, "secret timeout").catch(()=>null);
      const key = sec?.data?.key ? String(sec.data.key) : "";
      if (!key) continue;
      const model = lr.model || defModel;
      const exp = new Date(Date.now() + passSecs * 1e3).toISOString();
      const start = new Date(Date.now() + 3 * 6e4).toISOString();
      const per = Math.max(500, Math.min(5e3, 12e3 - (Date.now() - tLive)));
      let r = null;
      try {
        r = await fetch("https://generativelanguage.googleapis.com/v1alpha/auth_tokens", {
          method: "POST",
          headers: {
            "content-type": "application/json",
            "x-goog-api-key": key
          },
          body: JSON.stringify({
            uses: 1,
            expireTime: exp,
            newSessionExpireTime: start
          }),
          signal: AbortSignal.any([
            req.signal,
            AbortSignal.timeout(per)
          ])
        });
      } catch (e) {
        if (req.signal.aborted) break;
        markLive(lr.id, false, `live token: ${String(e).slice(0, 120)}`, 20);
        continue;
      }
      if (!r.ok) {
        const t = (await r.text().catch(()=>"")).slice(0, 200);
        markLive(lr.id, false, `live token ${r.status} ${t}`, liveCooldown(r.status, t));
        continue;
      }
      const j = await r.json();
      if (localCooldown.has("live:" + lr.id)) markLive(lr.id, true, null, 0);
      record({
        user_id: uid,
        source: "live",
        alias: resume ? "live-resume" : "live",
        provider: lr.provider,
        model,
        key_id: lr.id,
        status: 200,
        prompt_tokens: 0,
        completion_tokens: 0,
        quota_tokens: 0,
        total_ms: Date.now() - t0
      });
      return json({
        token: j.name,
        model,
        expires_at: exp,
        minutes: Math.ceil(passSecs / 60),
        call_id: callId,
        ...billLeft !== null ? liveMinsOut(mins, billLeft) : minsOut(mins),
        heartbeat_seconds: HEARTBEAT_S,
        ws_url: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained"
      }, 200, billLeft !== null ? balHdr(billLeft) : {});
    }
    if (!resume && callId) await rpc("live_call_beat", {
      p_uid: uid,
      p_call: callId,
      p_reported: 0,
      p_kind: "end"
    });
    record({
      user_id: uid,
      source: "live",
      alias: "live",
      provider: "live-pool",
      status: 503,
      error: "no usable live route"
    });
    return json({
      error: {
        code: "busy",
        message: "Live voice is busy right now. Please try again in a moment."
      }
    }, 503);
  }
  if (bill) flushUnsaved(s);
  const mediaSrc = url.pathname.endsWith("/image") ? "image" : "transcribe";
  const [ent, mrows] = bill ? await Promise.all([
    billingPrecheck(uid, s, void 0, mediaSrc),
    multipliers()
  ]) : [
    null,
    []
  ];
  const rid = bill ? "media:" + crypto.randomUUID() : "";
  if (ent) {
    if (Number(ent.allowance ?? 0) <= 0) return await emptyReply(uid, ent, s);
  } else {
    const used = await usageOf(uid);
    const st = stateFor(used.tokens, withCap(s, await capOf(uid, s)));
    if (st.state === "limit") return json({
      error: {
        code: "daily_limit",
        message: s.limit_message
      }
    }, 429);
  }
  if (url.pathname.endsWith("/transcribe")) {
    if (!feat.transcribe) return json({
      error: {
        code: "unavailable",
        message: "Transcription isn't available right now."
      }
    }, 503);
    const audio = String(body.audio_base64 ?? "");
    const mime = String(body.mime ?? "audio/mp4");
    if (!audio) return json({
      error: {
        message: "No audio"
      }
    }, 400);
    if (audio.length > Number(s.transcribe_max_b64 ?? 26e6)) return json({
      error: {
        code: "too_large",
        message: "This recording is too long to turn into text in one go. Try a shorter one (about 30 minutes or less)."
      }
    }, 413);
    const models = Array.isArray(s.transcribe_models) ? s.transcribe_models : [
      "gemini-3.5-flash-lite",
      "gemini-3-flash-preview"
    ];
    const prompt = String(body.prompt ?? "Transcribe this recording word for word in the language spoken. Label speakers as Speaker 1, Speaker 2... when the voice changes. No summary, transcript only.");
    let attempts = 0;
    for (const model of models){
      for (const k of (await providerKeys(String(s.live_provider)))){
        if (attempts++ >= 5) break;
        const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
          method: "POST",
          headers: {
            "content-type": "application/json",
            "x-goog-api-key": k.key
          },
          body: JSON.stringify({
            contents: [
              {
                parts: [
                  {
                    text: prompt
                  },
                  {
                    inline_data: {
                      mime_type: mime,
                      data: audio
                    }
                  }
                ]
              }
            ]
          })
        }).catch((e)=>null);
        if (!r || !r.ok) {
          const st2 = r?.status ?? 0;
          markKey(k.id, false, `transcribe ${st2}`, cooldownFor(st2));
          if (st2 === 404 || st2 === 400) break;
          continue;
        }
        const j = await r.json();
        const text = (j.candidates?.[0]?.content?.parts ?? []).map((p)=>p.text ?? "").join("").trim();
        const um = j.usageMetadata ?? {};
        record({
          user_id: uid,
          source: "transcribe",
          alias: "transcribe",
          provider: String(s.live_provider),
          model,
          key_id: k.id,
          status: 200,
          prompt_tokens: um.promptTokenCount ?? Math.ceil(audio.length / 1e3),
          completion_tokens: (um.totalTokenCount ?? 0) - (um.promptTokenCount ?? 0),
          total_ms: Date.now() - t0,
          ttft_ms: Date.now() - t0
        });
        if (rid) {
          const w = Number(um.promptTokenCount ?? Math.ceil(audio.length / 1e3)) + Number((um.totalTokenCount ?? 0) - (um.promptTokenCount ?? 0));
          const cost = Math.ceil(w * tierOf(model, mrows).multiplier);
          billingCharge(uid, rid, w, 0, "transcribe", false, s);
          if (ent && text) return json({
            text
          }, 200, balHdr(Number(ent.allowance) - cost));
        }
        if (text) return json({
          text
        });
      }
    }
    return json({
      error: {
        code: "busy",
        message: "Couldn't turn the recording into text right now. Please try again in a moment."
      }
    }, 503);
  }
  const alias = cfg.aliases.find((a)=>a.alias === "submac-image");
  if (!alias?.routes.length) return json({
    error: {
      code: "unavailable",
      message: "Image creation isn't available yet."
    }
  }, 503);
  const imgRoutes = alias.routes;
  for (const r of imgRoutes){
    await ensureKeys(cfg, [
      r
    ]);
    for (const k of keysInOrder(r)){
      const res = await fetch(r.base_url.replace(/\/$/, "") + "/images/generations", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${k.key}`
        },
        body: JSON.stringify({
          ...r.extra_body ?? {},
          model: r.model,
          prompt: String(body.prompt ?? ""),
          n: 1,
          size: String(body.size ?? "1024x1024"),
          response_format: "b64_json"
        })
      }).catch(()=>null);
      if (!res || !res.ok) {
        markKey(k.id, false, `image ${res?.status ?? 0}`, cooldownFor(res?.status ?? 0));
        break;
      }
      const j = await res.json();
      record({
        user_id: uid,
        source: "image",
        alias: "submac-image",
        provider: r.provider,
        model: r.model,
        key_id: k.id,
        status: 200,
        prompt_tokens: Number(s.image_tokens ?? 4e3),
        completion_tokens: 0,
        total_ms: Date.now() - t0
      });
      if (rid) {
        const icost = Math.ceil(Number(s.image_tokens ?? 4e3) * tierOf(r.model, mrows).multiplier);
        billingCharge(uid, rid, Number(s.image_tokens ?? 4e3), 0, "image", false, s);
        if (ent) return json(j, 200, balHdr(Number(ent.allowance) - icost));
      }
      return json(j);
    }
  }
  return json({
    error: {
      code: "busy",
      message: "Image creation is busy right now. Please try again in a moment."
    }
  }, 503);
}
Deno.serve(async (req)=>{
  const t0 = performance.now();
  const tm = {};
  let res;
  try {
    res = await handle(req, tm);
  } catch (e) {
    console.error(JSON.stringify({
      evt: "ai_chat_error",
      error: String(e).slice(0, 300)
    }));
    res = errJson(500, "server", "server");
  }
  tm.total = performance.now() - t0;
  try {
    isoHits++;
    res.headers.set("Server-Timing", Object.entries(tm).map(([k, v])=>`${k};dur=${v.toFixed(1)}`).join(", ") + `, iso;desc="${ISO}-${isoHits}"`);
  } catch  {}
  return res;
});
function billCtx(ent, mrows, background) {
  const st = billState(ent);
  const bgLeft = Math.max(0, Number(ent.bg_allowance ?? 0));
  const balance = background ? Math.min(bgLeft, st.cap - st.used) : st.cap - st.used;
  const bx = {
    ent,
    mrows,
    balance,
    hdrs: {
      "x-submac-usage": st.ratio.toFixed(3),
      "x-submac-state": st.state
    }
  };
  return {
    st,
    bgLeft,
    balance,
    bx
  };
}
var TOO_LONG_MSG = "Request too large to send in one go. Start a new chat or send less at once.";
function makePlan(cfg, body, state, bx, effort = null) {
  const s = cfg.settings;
  const alias = chatAlias(cfg);
  const empty = {
    alias,
    routes: [],
    messages: [],
    max_tokens: 0,
    stream: false,
    needTools: false,
    promptEstimate: 0,
    smallestWindow: "",
    roomOf: ()=>0,
    passthrough: {},
    effort
  };
  if (!alias) return {
    ...empty,
    error: errJson(503, "busy", "no_alias", void 0, true)
  };
  let maxOut = alias.max_output_tokens;
  if (state === "light") maxOut = Math.min(maxOut, Number(s.grace_max_output_tokens ?? 400));
  const requested = Number(body.max_tokens ?? body.max_completion_tokens ?? 0);
  const max_tokens = requested > 0 ? Math.min(requested, maxOut) : maxOut;
  const messages = cleanHistory(Array.isArray(body.messages) ? [
    ...body.messages
  ] : []);
  if (alias.system_hint) {
    const i = messages.findIndex((m)=>m.role === "system");
    if (i >= 0 && typeof messages[i].content === "string") messages[i] = {
      ...messages[i],
      content: messages[i].content + "\n\n" + alias.system_hint
    };
    else messages.unshift({
      role: "system",
      content: alias.system_hint
    });
  }
  const needTools = Array.isArray(body.tools) && body.tools.length > 0;
  const stream = body.stream === true;
  const promptEstimate = estimateTokens(messages.map((m)=>typeof m.content === "string" ? m.content : Array.isArray(m.content) ? m.content.filter((c)=>c?.type === "text") : m)) + (needTools ? estimateTokens(body.tools) : 0);
  if (promptEstimate > Number(s.max_prompt_tokens ?? 12e4)) {
    return {
      ...empty,
      error: errJson(413, "too_long", "too_long", TOO_LONG_MSG)
    };
  }
  const images = hasImages(messages);
  const routes = alias.routes.filter((r)=>(!needTools || r.tools) && (!images || r.vision));
  const windowOf = (r)=>Number(r.context_window) || 128e3;
  const promptNeed = Math.ceil(promptEstimate * 1.15);
  const need = promptNeed + Math.min(max_tokens, 4096);
  const roomW = (r)=>Math.max(1024, Math.min(max_tokens, windowOf(r) - promptNeed - 256));
  const roomOf = bx ? (r)=>Math.min(roomW(r), replyCap(bx.balance, tierOf(r.model, bx.mrows).multiplier, promptEstimate, s, num2(bx.ent.reply_cap, 0))) : roomW;
  const healthyWindows = alias.routes.filter((r)=>r.healthy).map(windowOf);
  const smallestWindow = String(Math.min(...healthyWindows.length ? healthyWindows : alias.routes.map(windowOf), 1e6));
  const fitting = routes.filter((r)=>need <= windowOf(r));
  if (routes.length && !fitting.length) {
    return {
      ...empty,
      error: errJson(413, "too_long", "too_long", TOO_LONG_MSG, false, {
        "x-submac-window": smallestWindow
      })
    };
  }
  if (bx) {
    const minMult = fitting.length ? Math.min(...fitting.map((r)=>tierOf(r.model, bx.mrows).multiplier)) : 1;
    const needIn = Math.max(1, Math.ceil(promptEstimate * weightsOf(s).wIn * minMult));
    if (needIn > bx.balance + Math.max(0, num2(s.billing_overrun_tokens, 8e3))) {
      return {
        ...empty,
        error: billErr(429, "limit_daily", `This message is too big for what's left of your allowance (it needs about ${needIn.toLocaleString("en-US")} tokens, ${Math.max(0, Math.floor(bx.balance)).toLocaleString("en-US")} left). Start a new chat or send less at once.`, bx.ent, s, "too_big_for_balance", {
          needed: needIn
        }, {
          ...bx.hdrs,
          "x-submac-error": "limit_daily"
        }, bx.balance)
      };
    }
  }
  const passthrough = {};
  for (const k of [
    "temperature",
    "top_p",
    "tools",
    "tool_choice",
    "response_format",
    "stop",
    "parallel_tool_calls",
    "seed"
  ]){
    if (body[k] !== void 0) passthrough[k] = body[k];
  }
  return {
    alias,
    routes: fitting,
    messages,
    max_tokens,
    stream,
    needTools,
    promptEstimate,
    smallestWindow,
    roomOf,
    passthrough,
    effort
  };
}
function payloadFor(p, r, s = {}) {
  return {
    ...p.passthrough,
    ...thinkingExtra(r, p.effort),
    model: r.model,
    messages: withThoughtSignatures(p.messages, r),
    max_tokens: clampOut(p.roomOf(r), providerOutCap(r, s), routeCap.get(r.route_id)),
    stream: p.stream,
    ...p.stream ? {
      stream_options: {
        include_usage: true
      }
    } : {}
  };
}
function shrinkFor(p, s = {}) {
  return (r, txt)=>{
    if (!/max_tokens|max_completion|max_output|output tokens|maximum.{0,40}tokens|tokens.{0,40}(exceed|too large|limit)/i.test(txt)) return false;
    const was = clampOut(p.roomOf(r), providerOutCap(r, s), routeCap.get(r.route_id));
    const m = txt.match(/(?:at most|maximum(?: value)?(?: is| of)?|up to|<=|less than or equal to)\s*(\d{3,6})/i);
    const n2 = m ? Number(m[1]) : 0;
    const next = n2 >= 1024 && n2 < was ? n2 : was > 8192 ? 8192 : 4096;
    if (next < was) {
      routeCap.set(r.route_id, next);
      return true;
    }
    return false;
  };
}
function routerReport(routeId, kind, next) {
  waitLater(rpc("ai_router_report", {
    p_route_id: routeId,
    p_kind: kind,
    p_next_route_id: next
  }).then(({ data, error })=>{
    if (error) {
      console.error(JSON.stringify({
        evt: "router_report_failed",
        error: error.message.slice(0, 200)
      }));
      return;
    }
    if (data?.swapped) {
      localCooldown.set("route:" + routeId, Date.now() + Number(data.rest_seconds ?? 60) * 1e3);
      console.log(JSON.stringify({
        evt: "router_swap",
        from: routeId,
        to: data.current_route_id ?? null,
        kind,
        rest_seconds: data.rest_seconds ?? null
      }));
    }
  }, ()=>{}));
}
function routerHome(homeId, from, ok, kind) {
  waitLater(rpc("ai_router_home", {
    p_home: homeId,
    p_from: from,
    p_ok: ok,
    p_kind: kind
  }).then(({ data, error })=>{
    if (error) {
      console.error(JSON.stringify({
        evt: "router_home_failed",
        error: error.message.slice(0, 200)
      }));
      return;
    }
    if (data?.swapped) {
      localCooldown.delete("route:" + homeId);
      console.log(JSON.stringify({
        evt: "router_swap",
        from,
        to: homeId,
        kind: "home"
      }));
    } else if (data?.rested) localCooldown.set("route:" + homeId, Date.now() + Number(data.rest_seconds ?? 60) * 1e3);
  }, ()=>{}));
}
function homeOf(alias) {
  return alias?.routes.find((r)=>r.healthy)?.route_id ?? null;
}
async function handle(req, tm) {
  const tReq = Date.now();
  if (req.method === "OPTIONS") return new Response("ok", {
    headers: CORS
  });
  const url = new URL(req.url);
  const internal = req.headers.has("x-submac-internal") ? await internalUser(req) : null;
  const uid = internal ?? await userFromJwt(req);
  if (!uid) return json({
    error: {
      code: "auth",
      message: "Please sign in again."
    }
  }, 401);
  if (url.pathname.endsWith("/status")) {
    const tG2 = performance.now();
    const cold = !warmCfg();
    tm.warm = cold ? 0 : 1;
    let g2, m;
    const gP = gate(uid, cold, false);
    gP.catch(()=>{});
    const entP0 = !cold && billingOn(warmCfg().settings) ? billingPrecheck(uid, warmCfg().settings, ()=>gP.then((x)=>x.usage)) : null;
    entP0?.catch(()=>{});
    try {
      [g2, m] = await Promise.all([
        gP,
        minutesOf(uid)
      ]);
    } catch (e) {
      console.error(JSON.stringify({
        evt: "status_gate_failed",
        error: String(e).slice(0, 200)
      }));
      return errJson(503, "busy", "busy", void 0, true);
    }
    tm.gate = performance.now() - tG2;
    const cfg2 = cache?.cfg;
    if (!cfg2) return errJson(503, "busy", "busy", void 0, true);
    const s3 = cfg2.settings;
    const c = capFrom(g2.cap, s3);
    const sc = withCap(s3, c);
    const bgs2 = backgroundFor(g2.usage.tokens, g2.usage.bg, sc);
    const ent2 = billingOn(s3) ? await (entP0 ?? billingPrecheck(uid, s3, ()=>Promise.resolve(g2.usage))) : null;
    if (ent2) {
      tm.billing = performance.now() - tG2;
      const bst = billState(ent2);
      const left = Math.max(0, Number(ent2.live_seconds_left ?? 0));
      const calls = ent2.degraded === "free_fallback" ? {
        ...minsOut(m),
        billing: true
      } : liveMinsOut(m, left);
      return json({
        cap: bst.cap,
        used: bst.used,
        ratio: bst.ratio,
        state: bst.state,
        requests: g2.usage.requests,
        bonus: bonusOut(c),
        resets: "daily (00:00 EAT)",
        message: s3.billing_limit_message ?? NO_BALANCE,
        features: features(cfg2),
        calls,
        background_left: Number(ent2.bg_allowance ?? 0),
        background: {
          share: bgs2.share,
          cap: bgs2.cap,
          used: bgs2.used,
          left: Number(ent2.bg_allowance ?? 0),
          ratio: Number(bgs2.ratio.toFixed(3)),
          paused: Number(ent2.bg_allowance ?? 0) <= 0
        },
        billing: billingOut(ent2, s3)
      }, 200, {
        ...balHdr(bst.allowance),
        ...balanceHeaders(ent2, bst)
      });
    }
    const stx = stateFor(g2.usage.tokens, sc);
    return json({
      ...stx,
      requests: g2.usage.requests,
      bonus: bonusOut(c),
      resets: "daily (00:00 EAT)",
      message: s3.limit_message,
      features: features(cfg2),
      calls: minsOut(m),
      background_left: bgs2.left,
      background: {
        share: bgs2.share,
        cap: bgs2.cap,
        used: bgs2.used,
        left: bgs2.left,
        ratio: Number(bgs2.ratio.toFixed(3)),
        paused: bgs2.paused
      }
    }, 200, balanceHeaders(null, stx));
  }
  const media = req.method === "POST" && /\/(live-token|live-usage|transcribe|image)$/.test(url.pathname);
  if (url.pathname.endsWith("/models") || media || req.method !== "POST") {
    let cfg2;
    const tCfg = performance.now();
    try {
      cfg2 = await config();
    } catch (e) {
      console.error(JSON.stringify({
        evt: "config_failed",
        error: String(e).slice(0, 200)
      }));
      return errJson(503, "busy", "busy", void 0, true);
    }
    tm.cfg = performance.now() - tCfg;
    if (url.pathname.endsWith("/models")) {
      return json({
        object: "list",
        data: [
          {
            id: CHAT_ALIAS,
            object: "model",
            owned_by: "submac"
          }
        ]
      });
    }
    if (media) return await mediaRoute(req, url, uid, cfg2);
    return json({
      error: {
        message: "POST only"
      }
    }, 405);
  }
  const BAD = Symbol("bad json");
  const parsed = await req.json().catch(()=>BAD);
  const body = parsed === BAD || !parsed || typeof parsed !== "object" ? {} : parsed;
  const source = internal ? "bot-cloud" : (req.headers.get("x-submac-source") ?? "agent").slice(0, 20);
  const background = !!internal || ((req.headers.get("x-submac-lane") ?? "").toLowerCase() === "background" && !chatLane(source));
  const lane = background ? "background" : "user";
  const chatHdr = (req.headers.get("x-submac-chat") ?? "").slice(0, 64);
  const chat = chatHdr ? uid + ":" + chatHdr : "";
  const effort = effortOf(req.headers.get("x-submac-effort"));
  const needTools0 = Array.isArray(body.tools) && body.tools.length > 0;
  const warm = warmCfg();
  tm.warm = warm ? 1 : 0;
  const tG = performance.now();
  const gateP = gate(uid, !warm, needTools0);
  gateP.catch(()=>{});
  const bill0 = !!warm && billingOn(warm.settings);
  const billP = bill0 ? Promise.all([
    billingPrecheck(uid, warm.settings, ()=>gateP.then((x)=>x.usage), billSource(source, background)),
    multipliers()
  ]) : null;
  billP?.catch(()=>{});
  let g;
  try {
    g = await gateP;
  } catch (e) {
    console.error(JSON.stringify({
      evt: "gate_failed",
      error: String(e).slice(0, 200),
      ms: Math.round(performance.now() - tG)
    }));
    return errJson(503, "busy", "busy", void 0, true);
  }
  tm.gate = performance.now() - tG;
  const cfg = cache?.cfg;
  if (!cfg) return errJson(503, "busy", "busy", void 0, true);
  const s = cfg.settings;
  if (s.kill_switch === true) return errJson(503, "busy", "paused", "SubMac is taking a short break. Please try again in a few minutes.", true);
  if (g.blocked) return errJson(403, "blocked", "blocked");
  if (parsed === BAD) return errJson(400, "server", "bad_request", "Invalid JSON");
  const rpm = Number(s.user_rpm ?? 40);
  if (rpm > 0 && g.burst >= rpm) {
    return errJson(429, "busy", "slow_down", "That's a lot of requests at once. Give it a few seconds and try again.", false, {
      "retry-after": "10"
    });
  }
  const used = g.usage;
  const s2 = withCap(s, capFrom(g.cap, s));
  const bill = billingOn(s);
  let ent = null, mrows = [];
  if (bill) {
    [ent, mrows] = await (billP ?? Promise.all([
      billingPrecheck(uid, s, ()=>Promise.resolve(used), billSource(source, background)),
      multipliers()
    ]));
    tm.billing = performance.now() - tG;
    flushUnsaved(s);
  }
  const ctx = ent ? billCtx(ent, mrows, background) : null;
  const st = ctx ? ctx.st : stateFor(used.tokens, s2);
  const bgLeft = ctx ? ctx.bgLeft : 0;
  const balance = ctx ? ctx.balance : 0;
  const balHdrs = balanceHeaders(ent, st);
  const stHdrs = {
    "x-submac-usage": st.ratio.toFixed(3),
    "x-submac-state": st.state
  };
  const withBal = (r)=>{
    for (const [k, v] of Object.entries(balHdrs)){
      try {
        r.headers.set(k, v);
      } catch  {}
    }
    return r;
  };
  if (ctx && st.state === "limit") {
    const r = withBal(await emptyReply(uid, ent, s, stHdrs));
    try {
      if (!r.headers.get("x-submac-error")) r.headers.set("x-submac-error", r.status === 503 ? "busy" : "limit_daily");
    } catch  {}
    return r;
  }
  if (st.state === "limit") return withBal(errJson(429, "limit_daily", "daily_limit", s.limit_message ?? FRIENDLY.limit_daily, false, stHdrs));
  const bgs = backgroundFor(used.tokens, used.bg, s2);
  if (ctx && background && bgLeft <= 0) {
    return withBal(billErr(429, "background_paused", BG_PAUSED, ent, s, "background_share_used", {
      background_left: 0,
      resets_at: eatReset()
    }, {
      ...stHdrs,
      "x-submac-bg": "1.000",
      "x-submac-error": "limit_daily"
    }));
  }
  if (!ctx && background && (bgs.paused || st.state === "light")) {
    return withBal(json({
      error: {
        code: "background_paused",
        submac_code: "limit_daily",
        message: "Paused until tomorrow to save your daily allowance."
      },
      background_left: 0,
      resets_at: eatReset()
    }, 429, {
      ...stHdrs,
      "x-submac-bg": bgs.ratio.toFixed(3),
      "x-submac-error": "limit_daily"
    }));
  }
  if (!background && !internal) screenLater(uid, Array.isArray(body.messages) ? body.messages : [], cfg);
  const plan = makePlan(cfg, body, st.state, ctx?.bx, effort);
  if (plan.error) return withBal(plan.error);
  if (!plan.routes.length) {
    console.error(JSON.stringify({
      evt: "no_route",
      images: hasImages(body.messages),
      tools: plan.needTools
    }));
    return withBal(errJson(503, "busy", "busy", void 0, true));
  }
  const { stream, promptEstimate, smallestWindow } = plan;
  const rid = bill ? "chat:" + crypto.randomUUID() : "";
  const bilHdrs = (cost)=>ent ? balHdr(balance - cost) : {};
  const baseHeaders = {
    ...CORS,
    ...stHdrs,
    "x-submac-window": smallestWindow,
    "x-submac-bg": bgs.ratio.toFixed(3),
    ...bilHdrs(0),
    ...balHdrs
  };
  const costOf = (d)=>{
    const delivered = d.status === 200 || d.outChars > 0;
    if (!delivered) return {
      delivered,
      pt: 0,
      ct: 0,
      w: 0
    };
    const pt = d.usage?.prompt_tokens ?? promptEstimate;
    const est = d.data ? estimateTokens(d.data.choices?.[0]?.message) : Math.ceil(d.outChars / 4);
    const ct = Math.max(d.usage?.completion_tokens ?? est, (d.usage?.total_tokens ?? 0) - pt);
    return {
      delivered,
      pt,
      ct,
      w: pt + ct > 0 ? Math.max(1, quotaOf(s, pt, ct, d.usage)) : 0
    };
  };
  return await runChat({
    routes: plan.routes,
    snap: g.router,
    homeId: homeOf(plan.alias),
    homeAfterMs: Math.max(60, num2(s.router_home_after_s, 900)) * 1e3,
    chat,
    stream,
    alias: CHAT_ALIAS,
    payloadFor: (r)=>payloadFor(plan, r, s),
    ensureKeys: (r)=>ensureKeys(cfg, [
        r
      ]),
    shrink: shrinkFor(plan, s),
    clean,
    signal: req.signal,
    t0: tReq,
    budget: budgetFrom(s, !!internal),
    headers: baseHeaders,
    deps: {
      fetch: (i, init)=>fetch(i, init),
      now: ()=>Date.now(),
      report: routerReport,
      home: routerHome,
      markKey,
      attemptFailed: (r, k, status, err)=>record({
          user_id: uid,
          source,
          lane,
          alias: CHAT_ALIAS,
          provider: r.provider,
          model: r.model,
          key_id: k.id,
          status,
          error: err.slice(0, 300),
          total_ms: Date.now() - tReq
        }),
      log: (e)=>console.log(JSON.stringify(e))
    },
    onUpstream: ()=>{
      tm.upstream = performance.now() - tG;
    },
    onDone: (d)=>{
      const c = costOf(d);
      const g2 = (Date.now() - (d.ttft ? tReq + d.ttft : tReq)) / 1e3;
      const genSecs = g2 < 0.25 ? Math.max(0.05, d.total / 1e3) : g2;
      record({
        user_id: uid,
        source,
        lane,
        alias: CHAT_ALIAS,
        provider: d.route.provider,
        model: d.route.model,
        key_id: d.key.id,
        status: d.status,
        prompt_tokens: c.pt,
        completion_tokens: c.ct,
        ttft_ms: d.ttft || d.total,
        total_ms: d.total,
        tps: c.ct / genSecs,
        attempts: d.attempts,
        error: d.error,
        quota_tokens: c.w,
        cached_tokens: cachedOf(d.usage)
      });
      if (rid && c.delivered && c.pt + c.ct > 0) {
        const sp = chargeSplit(s, c.w, c.ct);
        billingCharge(uid, rid, sp.tin, sp.tout, source.toLowerCase() === "live" ? "live-chat" : source, background, s);
      }
    },
    jsonResponse: (data, d)=>{
      const c = costOf(d);
      if (ent) {
        const cost = c.delivered ? c.w : 0;
        const after2 = billState(ent, cost);
        return json(data, 200, {
          ...balHdrs,
          "x-submac-usage": after2.ratio.toFixed(3),
          "x-submac-state": after2.state,
          "x-submac-window": smallestWindow,
          "x-submac-bg": (background && bgLeft - cost <= 0 ? 1 : bgs.ratio).toFixed(3),
          ...bilHdrs(cost),
          ...balanceHeaders(ent, after2)
        });
      }
      const after = stateFor(used.tokens + c.w, s2);
      return json(data, 200, {
        ...balanceHeaders(null, after),
        "x-submac-usage": after.ratio.toFixed(3),
        "x-submac-state": after.state,
        "x-submac-window": smallestWindow,
        "x-submac-bg": backgroundFor(after.used, used.bg + (background ? c.w : 0), s2).ratio.toFixed(3)
      });
    }
  });
}
