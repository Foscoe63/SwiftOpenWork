import Foundation

/// The script every mod's JavaScriptCore context runs before the mod's own code: the `$` object,
/// the hook chain, JSX, the `claude-code` module and a loader that turns TypeScript into
/// JavaScript. It talks to the app through one native object, `__native`:
/// `post(json)`, `readFile(path)`, `resolve(from, spec)`, `setTimer(id, ms, repeat)`,
/// `clearTimer(id)` and `log(text)`. Everything a mod can do to the app is a message through
/// `post`, so the app decides what is allowed.
enum ModBootstrap {
    static let script = #"""
(function () {
'use strict';
const G = globalThis;
const native = G.__native; delete G.__native;
const cfg = JSON.parse(G.__cfg); delete G.__cfg;
const sucrase = G.__sucrase; delete G.__sucrase;
const indirectEval = G.eval;
const PLUGIN = cfg.name, ROOT = cfg.root, PLUGIN_ROOT = cfg.pluginRoot || cfg.root, OPTIONS = cfg.options || {};
const post = (m) => native.post(JSON.stringify(m));
const log = (msg) => post({ t: 'log', msg: String(msg).slice(0, 2000) });

// ---------- small platform pieces JavaScriptCore does not ship ----------
const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
G.btoa = (s) => { s = String(s); let o = ''; for (let i = 0; i < s.length; i += 3) { const a = s.charCodeAt(i), b = s.charCodeAt(i + 1), c = s.charCodeAt(i + 2); o += B64[a >> 2] + B64[((a & 3) << 4) | (b >> 4 || 0)] + (isNaN(b) ? '=' : B64[((b & 15) << 2) | (c >> 6 || 0)]) + (isNaN(c) ? '=' : B64[c & 63]); } return o; };
G.atob = (s) => { s = String(s).replace(/=+$/, ''); let o = '', bits = 0, acc = 0; for (const ch of s) { const v = B64.indexOf(ch); if (v < 0) continue; acc = (acc << 6) | v; bits += 6; if (bits >= 8) { bits -= 8; o += String.fromCharCode((acc >> bits) & 255); } } return o; };
G.queueMicrotask = (f) => { Promise.resolve().then(f); };
G.structuredClone = (v) => (v === undefined ? undefined : JSON.parse(JSON.stringify(v)));
G.TextEncoder = class { encode(s) { const u = unescape(encodeURIComponent(String(s))); const a = new Uint8Array(u.length); for (let i = 0; i < u.length; i++) a[i] = u.charCodeAt(i); return a; } };
G.TextDecoder = class { decode(a) { let s = ''; for (const b of a || []) s += String.fromCharCode(b); try { return decodeURIComponent(escape(s)); } catch (e) { return s; } } };
G.URLSearchParams = class {
  constructor(init) { this.p = []; if (typeof init === 'string') { for (const kv of init.replace(/^\?/, '').split('&')) if (kv) { const [k, v = ''] = kv.split('='); this.p.push([decodeURIComponent(k.replace(/\+/g, ' ')), decodeURIComponent(v.replace(/\+/g, ' '))]); } } else if (init) for (const [k, v] of Array.isArray(init) ? init : Object.entries(init)) this.p.push([String(k), String(v)]); }
  get(k) { const f = this.p.find((x) => x[0] === k); return f ? f[1] : null; } getAll(k) { return this.p.filter((x) => x[0] === k).map((x) => x[1]); } has(k) { return this.p.some((x) => x[0] === k); }
  append(k, v) { this.p.push([String(k), String(v)]); } set(k, v) { this.delete(k); this.append(k, v); } delete(k) { this.p = this.p.filter((x) => x[0] !== k); }
  toString() { return this.p.map(([k, v]) => encodeURIComponent(k) + '=' + encodeURIComponent(v)).join('&'); } [Symbol.iterator]() { return this.p[Symbol.iterator](); }
};
G.console = { log: (...a) => log(a.join(' ')), warn: (...a) => log(a.join(' ')), error: (...a) => log(a.join(' ')), info: () => {}, debug: () => {} };

// ---------- timers (the app runs the clock; the callback comes back as a message) ----------
const timerFns = new Map(); let timerSeq = 0;
function startTimer(ms, repeat, fn) { const id = ++timerSeq; timerFns.set(id, { fn, repeat }); native.setTimer(id, Math.max(0, +ms || 0), !!repeat); return id; }
function stopTimer(id) { if (timerFns.delete(id)) native.clearTimer(id); }
G.setTimeout = (fn, ms) => startTimer(ms, false, fn); G.setInterval = (fn, ms) => startTimer(Math.max(16, ms || 0), true, fn);
G.clearTimeout = G.clearInterval = stopTimer;
const fireTimer = (id) => { const t = timerFns.get(id); if (!t) return; if (!t.repeat) timerFns.delete(id); try { t.fn(); } catch (e) { log('timer callback failed: ' + (e && e.message || e)); } };

// ---------- RPC to the app ----------
let rpcId = 0; const rpcPending = new Map();
const rpc = (noun, method, args) => new Promise((resolve, reject) => { const id = ++rpcId; rpcPending.set(id, { resolve, reject }); post({ t: 'rpc', id, noun, method, args: args.map((a) => (a === undefined ? null : a)) }); });
const rpcVoid = (noun, method, args) => { post({ t: 'rpc', id: 0, noun, method, args: args.map((a) => (a === undefined ? null : a)) }); };

// ---------- elements and JSX ----------
const handles = new Map(); let handleSeq = 0;
function addHandle(fn) { const id = ++handleSeq; handles.set(id, fn); if (handles.size > 4000) handles.delete(handles.keys().next().value); return id; }
const flatten = (c) => (Array.isArray(c) ? c.flatMap(flatten) : c === null || c === undefined || c === false || c === true ? [] : [typeof c === 'number' ? String(c) : c]);
function el(type) {
  return (props) => {
    const { children, onPress, onInput, onSelect, onSubmit, ...rest } = props || {};
    const node = { type, props: rest, children: flatten(children) };
    for (const [k, f] of [['onPress', onPress], ['onInput', onInput], ['onSelect', onSelect], ['onSubmit', onSubmit]]) if (typeof f === 'function') { node.press = node.press || { plugin: PLUGIN, handle: addHandle(f) }; if (k !== 'onPress') node.on = { ...(node.on || {}), [k]: addHandle(f) }; }
    return node;
  };
}
const TABLE = Object.freeze(Object.fromEntries(['Box', 'Text', 'Button', 'Input', 'Select', 'Svg', 'Link', 'Code', 'Markdown', 'Client', 'Raster', 'Image'].map((n) => [n, el(n)])));
function h(type, props, ...children) {
  if (typeof type === 'function') return type({ ...(props || {}), children: children.length ? children : (props && props.children) });
  return { type, props: props || {}, children: flatten(children) };
}
const Fragment = (p) => flatten(p.children);
G.h = h; G.Fragment = Fragment;
const safe = (v) => JSON.parse(JSON.stringify(v === undefined ? null : v, (k, x) => (typeof x === 'function' ? undefined : x)));

// ---------- hooks ----------
const hooks = [];
const isRe = (v) => Object.prototype.toString.call(v) === '[object RegExp]';
const globToRe = (g) => new RegExp('^' + String(g).replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*') + '$');
function matches(m, input) {
  if (!m) return true;
  for (const [k, exp] of Object.entries(m)) {
    const act = input ? input[k] : undefined; const s = act === undefined ? '' : String(act);
    if (isRe(exp)) { if (!exp.test(s)) return false; }
    else if (Array.isArray(exp)) { if (!exp.some((x) => (isRe(x) ? x.test(s) : String(x).includes('*') ? globToRe(x).test(s) : String(x) === s))) return false; }
    else if (typeof exp === 'string' && exp.includes('*')) { if (!globToRe(exp).test(s)) return false; }
    else if (exp !== undefined && String(exp) !== s) return false;
  }
  return true;
}
const isGenFn = (f) => Object.prototype.toString.call(f) === '[object AsyncGeneratorFunction]';
function on(event, a, b) {
  const [matcher, fn] = typeof a === 'function' ? [undefined, a] : [a, b];
  if (typeof fn !== 'function') throw new Error('on(' + event + '): a hook function is required');
  const rec = { event, matcher, fn, catchFn: null, isStream: isGenFn(fn) };
  hooks.push(rec);
  return { catch(f) { rec.catchFn = f; return this; } };
}
const summary = () => hooks.map((x) => ({ event: x.event, matcher: x.matcher ? Object.fromEntries(Object.entries(x.matcher).map(([k, v]) => [k, isRe(v) ? String(v) : v])) : null }));

async function runChain(event, input, mainNext) {
  const list = hooks.filter((x) => x.event === event && matches(x.matcher, input));
  const step = async (i, e) => {
    if (i >= list.length) return mainNext(e);
    const rec = list[i]; let called = false; let settled;
    const cont = async (e2 = e) => { called = true; settled = step(i + 1, e2); return settled; };
    const next = rec.isStream ? (e2 = e) => (async function* () { return await cont(e2); })() : cont;
    Object.defineProperty(next, 'called', { get: () => called });
    try {
      let out;
      if (rec.isStream) { const gen = rec.fn($, e, next); for (;;) { const r = await gen.next(); if (r.done) { out = r.value; break; } } }
      else out = await rec.fn($, e, next);
      if (out === undefined) return called ? settled : step(i + 1, e);
      return out;
    } catch (err) {
      log(event + ' hook failed: ' + (err && err.message || err));
      if (rec.catchFn) { try { return await rec.catchFn($, e, next); } catch (e2) { log(event + ' catch handler failed: ' + (e2 && e2.message || e2)); } }
      return called ? settled : step(i + 1, e);
    }
  };
  return step(0, input);
}

// ---------- the `$` object ----------
const noun = (n, methods) => Object.fromEntries(methods.map((m) => [m, (...args) => rpc(n, m, args)]));
const timerHandle = (id) => ({ cancel() { stopTimer(id); } });
const guard = (fn) => () => { Promise.resolve().then(fn).catch((e) => log('timer callback failed: ' + (e && e.message || e))); };
const $ = Object.freeze({
  plugin: Object.freeze({ name: PLUGIN, root: PLUGIN_ROOT }),
  ui: Object.freeze({
    ...noun('ui', ['ask', 'notify', 'open', 'close', 'panes', 'scroll', 'focus', 'copy', 'selection', 'view', 'blit']),
    status: (text) => { rpcVoid('ui', 'status', [text]); },
    toast: (text, o) => { rpcVoid('ui', 'toast', [text, o]); },
    log: (text, o) => { rpcVoid('ui', 'log', [text, o]); },
    notice: () => {},
    invalidate: (ev) => { rpcVoid('ui', 'invalidate', [ev]); },
    resolve: () => TABLE,
  }),
  model: Object.freeze(noun('model', ['complete', 'fork', 'classify'])),
  audio: Object.freeze(noun('audio', ['play', 'speak'])),
  mcp: Object.freeze(noun('mcp', ['call', 'connect'])),
  session: Object.freeze(noun('session', ['messages', 'cwd', 'root', 'model', 'turns', 'id', 'repo', 'surfaces', 'surface', 'usage', 'version', 'compact', 'send', 'append', 'authorize', 'identity'])),
  turn: Object.freeze(noun('turn', ['abort'])),
  prompt: Object.freeze(noun('prompt', ['submit', 'read', 'media', 'fill', 'suggest', 'compose'])),
  tool: Object.freeze(noun('tool', ['list', 'call', 'check', 'register'])),
  command: Object.freeze(noun('command', ['list', 'run', 'register'])),
  config: Object.freeze(noun('config', ['list', 'set'])),
  telemetry: Object.freeze({ log: async () => {}, mark: async () => {} }),
  agent: Object.freeze(noun('agent', ['spawn', 'list', 'register'])),
  fs: Object.freeze(noun('fs', ['read', 'write', 'list', 'exists', 'stat', 'ancestors', 'remove', 'mkdir'])),
  store: Object.freeze(noun('store', ['get', 'set', 'delete', 'keys'])),
  state: Object.freeze(noun('state', ['get', 'set'])),
  clock: Object.freeze({
    now: async () => Date.now(),
    sleep: (ms) => new Promise((r) => { startTimer(ms, false, r); }),
    after: (ms, fn) => timerHandle(startTimer(ms, false, guard(fn))),
    every: (ms, fn) => timerHandle(startTimer(Math.max(16, ms), true, guard(fn))),
  }),
  http: Object.freeze(noun('http', ['fetch'])),
  process: Object.freeze(noun('process', ['run', 'spawn'])),
  settings: Object.freeze(noun('settings', ['read'])),
  env: Object.freeze(noun('env', ['get', 'set'])),
});

// ---------- the `claude-code` module's runtime exports: state atoms ----------
const freeze = Object.freeze;
const atom = (ref, initial, options) => freeze({ ref: freeze({ ...ref }), initial, ...(options && options.shape ? { shape: options.shape } : {}) });
const derive = (sources, compute) => freeze({ sources: freeze([...sources]), compute });
const memberOf = (a, e) => freeze({ ...a, ref: freeze({ ...a.ref, id: e && e.requestId }) });
async function read($$, src) {
  if (src && Array.isArray(src.sources)) return src.compute(...(await Promise.all(src.sources.map((x) => read($$, x)))));
  if (src && 'initial' in src && src.ref) { const r = await $$.state.get(src.ref); return r.value === undefined ? src.initial : r.value; }
  return (await $$.state.get(src)).value;
}
async function update($$, target, change) {
  const ref = target.ref || target; const initial = target.initial;
  for (let i = 0; i < 8; i++) {
    const r = await $$.state.get(ref); const cur = r.value === undefined ? initial : r.value; const next = change(cur);
    const w = await $$.state.set(ref, next, { ifVersion: r.version });
    if (w && w.isApplied === false) continue;
    return next;
  }
  throw new Error('update: the value kept changing');
}
const CLAUDE_CODE = freeze({ atom, derive, memberOf, read, update, tier: () => {} });

// ---------- module loader (TypeScript/JSX/ES modules -> CommonJS) ----------
const cache = new Map();
function load(file) {
  if (cache.has(file)) return cache.get(file).exports;
  const src = native.readFile(file);
  if (src === null || src === undefined) throw new Error("Cannot read module " + file);
  const code = sucrase.transform(src, { transforms: ['typescript', 'jsx', 'imports'], jsxPragma: 'h', jsxFragmentPragma: 'Fragment', production: true, filePath: file }).code;
  const mod = { exports: {} }; cache.set(file, mod);
  const req = (spec) => {
    if (spec === 'claude-code') return CLAUDE_CODE;
    if (spec.startsWith('claude-code/')) return {};
    if (!spec.startsWith('.')) throw new Error('Imports of packages are not available to a mod: ' + spec);
    const target = native.resolve(file, spec);
    if (!target) throw new Error("Cannot find module '" + spec + "' from " + file);
    return load(target);
  };
  const fn = indirectEval('(function (exports, require, module, __filename, __dirname) {' + code + '\n})\n//# sourceURL=' + file);
  fn(mod.exports, req, mod, file, file.replace(/\/[^\/]*$/, ''));
  return mod.exports;
}

// ---------- messages from the app ----------
const nextPending = new Map(); let nextSeq = 0;
G.__deliver = async (json) => {
  const m = JSON.parse(json);
  try {
    if (m.t === 'ret') { const p = rpcPending.get(m.id); if (p) { rpcPending.delete(m.id); m.error ? p.reject(new Error(m.error)) : p.resolve(m.value === null ? undefined : m.value); } }
    else if (m.t === 'nextRet') { const p = nextPending.get(m.id); if (p) { nextPending.delete(m.id); m.error ? p.reject(new Error(m.error)) : p.resolve(m.value); } }
    else if (m.t === 'event') {
      const mainNext = (e) => new Promise((resolve, reject) => { const id = ++nextSeq; nextPending.set(id, { resolve, reject }); post({ t: 'next', chain: m.chain, id, input: safe(e) }); });
      try { const value = await runChain(m.event, m.input, mainNext); post({ t: 'eventRet', chain: m.chain, value: safe(value) }); }
      catch (err) { post({ t: 'eventRet', chain: m.chain, error: String(err && err.message || err) }); }
    }
    else if (m.t === 'press') {
      const f = handles.get(m.handle);
      if (f) { try { await f(m.arg); post({ t: 'pressRet', id: m.id }); } catch (err) { log('press handler failed: ' + (err && err.message || err)); post({ t: 'pressRet', id: m.id, error: String(err && err.message || err) }); } }
      else post({ t: 'pressRet', id: m.id, error: 'stale' });
    }
  } catch (err) { log('message failed: ' + (err && err.message || err)); }
};
G.__fireTimer = fireTimer;

(async () => {
  try {
    for (const file of cfg.entries) {
      const mod = load(file);
      const register = mod.register || mod.default;
      if (typeof register !== 'function') throw new Error('The hooks module ' + file.replace(/^.*\//, '') + ' does not export register()');
      await register(on, OPTIONS);
    }
    // Code is loaded: from here a mod cannot build more code from strings.
    try { Object.defineProperty(G, 'eval', { value: undefined, configurable: false, writable: false }); } catch (e) {}
    post({ t: 'ready', hooks: summary() });
  } catch (err) { post({ t: 'failed', error: (String((err && err.message) || err) + (err && err.stack ? '\n' + err.stack : '')).slice(0, 2000) }); }
})();
})();
"""#
}
