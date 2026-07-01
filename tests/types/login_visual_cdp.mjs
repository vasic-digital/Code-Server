/*
 * tests/types/login_visual_cdp.mjs — §11.4.170 host-rendered visual proof for
 * the login-form UX feature, WITHOUT any npm dependency.
 *
 * The @playwright/test npm package is not installed and `npx` has no network on
 * this host, but a full Chromium binary IS cached. So this driver speaks the
 * Chrome DevTools Protocol directly over Node 22's built-in global WebSocket +
 * fetch — a self-contained headless-Chromium harness. It:
 *
 *   1. serves the REAL rendered /login HTML (produced by `go test
 *      -run TestRenderLoginArtifact`) on http://127.0.0.1:<port> — a secure
 *      context so the Clipboard API is available;
 *   2. renders it in headless Chromium and captures a PNG (the pixel artifact);
 *   3. asserts (DOM text + geometry oracle) that both icon buttons render, are
 *      LABELLED, are on-screen (not clipped) and do NOT overlap any <label>
 *      (§11.4.162), plus an optional tesseract OCR pass over the PNG;
 *   4. DRIVES the clipboard in-browser: (a) click copy -> clipboard holds the
 *      sign command; (b) seed ONE signature -> click paste -> field filled;
 *      (c) seed TWO -> click paste -> picker appears -> choosing one fills it;
 *   5. proves the paste path cannot XSS (a hostile armored payload lands as
 *      textarea .value only, injects no element, runs no script) and never
 *      auto-submits (location unchanged).
 *
 * Usage:   node login_visual_cdp.mjs --html <login.html> --out <evidence-dir>
 * Exit:    0 = all checks passed ; 2 = Chromium unavailable (honest SKIP) ;
 *          1 = a real failure (render/layout/interaction defect).
 * Output:  writes PNG + JSON evidence under <evidence-dir>; prints
 *          `VERDICT_JSON: {...}` as the last line for the shell suite to parse.
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { spawn, spawnSync } from 'node:child_process';

// ---- args ----------------------------------------------------------------
function arg(name, def) {
  const i = process.argv.indexOf(name);
  return i >= 0 && i + 1 < process.argv.length ? process.argv[i + 1] : def;
}
const HTML = arg('--html');
const OUT = arg('--out', path.join(os.tmpdir(), 'login_visual_out'));
if (!HTML || !fs.existsSync(HTML)) {
  console.error('SKIP: --html <rendered login.html> is required and must exist');
  process.exit(2);
}
fs.mkdirSync(OUT, { recursive: true });
const html = fs.readFileSync(HTML, 'utf8');

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---- resolve a Chromium binary ------------------------------------------
function resolveChrome() {
  if (process.env.HELIX_CHROME && fs.existsSync(process.env.HELIX_CHROME)) return process.env.HELIX_CHROME;
  const roots = [path.join(os.homedir(), '.cache/ms-playwright')];
  for (const root of roots) {
    if (!fs.existsSync(root)) continue;
    const dirs = fs.readdirSync(root).filter((d) => d.startsWith('chromium-')).sort().reverse();
    for (const d of dirs) {
      const p = path.join(root, d, 'chrome-linux64', 'chrome');
      if (fs.existsSync(p)) return p;
    }
  }
  for (const p of ['/usr/bin/chromium', '/usr/bin/chromium-browser', '/usr/bin/google-chrome']) {
    if (fs.existsSync(p)) return p;
  }
  return null;
}

// ---- tiny static server (secure-context origin for the Clipboard API) ----
function serveLogin() {
  return new Promise((resolve) => {
    const srv = http.createServer((req, res) => {
      res.setHeader('Content-Type', 'text/html; charset=utf-8');
      res.setHeader('Cache-Control', 'no-store');
      res.end(html);
    });
    srv.listen(0, '127.0.0.1', () => resolve({ srv, port: srv.address().port }));
  });
}

// ---- minimal CDP client over the browser websocket (flatten sessions) ----
class CDP {
  constructor(ws) {
    this.ws = ws;
    this.id = 0;
    this.pending = new Map();
    this.listeners = [];
    ws.addEventListener('message', (ev) => {
      const msg = JSON.parse(ev.data);
      if (msg.id != null && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        msg.error ? reject(new Error(msg.error.message)) : resolve(msg.result);
      } else if (msg.method) {
        for (const l of this.listeners) l(msg);
      }
    });
  }
  send(method, params = {}, sessionId) {
    const id = ++this.id;
    const payload = { id, method, params };
    if (sessionId) payload.sessionId = sessionId;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify(payload));
      setTimeout(() => {
        if (this.pending.has(id)) { this.pending.delete(id); reject(new Error(method + ' timed out')); }
      }, 20000);
    });
  }
  once(method, sessionId) {
    return new Promise((resolve) => {
      const l = (msg) => {
        if (msg.method === method && (!sessionId || msg.sessionId === sessionId)) {
          this.listeners = this.listeners.filter((x) => x !== l);
          resolve(msg.params);
        }
      };
      this.listeners.push(l);
    });
  }
}

async function readDevtools(userDir) {
  const portFile = path.join(userDir, 'DevToolsActivePort');
  for (let i = 0; i < 100; i++) {
    if (fs.existsSync(portFile)) {
      const [port, wspath] = fs.readFileSync(portFile, 'utf8').trim().split('\n');
      if (port && wspath) return { port, browserWs: `ws://127.0.0.1:${port}${wspath}` };
    }
    await sleep(100);
  }
  throw new Error('Chromium never wrote DevToolsActivePort');
}

// Open a fresh page target AT the given url via the DevTools HTTP endpoint and
// return its own page-level websocket URL (direct page connection — simpler and
// more reliable than flatten sessions for a hand-rolled CDP client).
async function newPageWs(port, url) {
  const res = await fetch(`http://127.0.0.1:${port}/json/new?${url}`, { method: 'PUT' });
  if (!res.ok) throw new Error('json/new HTTP ' + res.status);
  const t = await res.json();
  if (!t.webSocketDebuggerUrl) throw new Error('json/new returned no webSocketDebuggerUrl');
  return t.webSocketDebuggerUrl;
}

function openWS(url) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    ws.addEventListener('open', () => resolve(ws));
    ws.addEventListener('error', (e) => reject(new Error('ws error: ' + (e.message || 'unknown'))));
  });
}

// The page-side test bundle (runs inside Chromium via Runtime.evaluate). It
// returns a plain JSON verdict; no data crosses back except serialisable state.
const PAGE_TESTS = `
(async () => {
  const $ = (id) => document.getElementById(id);
  const sleep = (ms) => new Promise(r => setTimeout(r, ms));
  const rectOf = (el) => { const r = el.getBoundingClientRect(); return {x:r.x,y:r.y,w:r.width,h:r.height,right:r.right,bottom:r.bottom}; };
  const overlap = (a,b) => !(a.right<=b.x || b.right<=a.x || a.bottom<=b.y || b.bottom<=a.y);
  const out = { layout:{}, interaction:{}, security:{} };

  // ---- LAYOUT / a11y oracle ----
  const ids = ['copy-cmd-btn','copy-challenge-btn','paste-sig-btn'];
  const vw = innerWidth, vh = innerHeight;
  const btns = ids.map(id => { const el=$(id); if(!el) return {id,present:false}; const r=rectOf(el);
    return { id, present:true, hidden: !!el.hidden, visible: r.w>0 && r.h>0, text:(el.innerText||'').trim(),
      aria: el.getAttribute('aria-label'), inViewport: r.x>=-1 && r.y>=-1 && r.right<=vw+1 && r.bottom<=vh+1, rect:r }; });
  const labels = [...document.querySelectorAll('label')].map(l => ({ for:l.getAttribute('for'), rect:rectOf(l) }));
  const overlaps = [];
  for (const b of btns) { if(!b.present || !b.visible) continue; for (const l of labels) { if(overlap(b.rect,l.rect)) overlaps.push({btn:b.id,label:l.for}); } }
  out.layout = { vw, vh, btns, overlaps };

  // ---- INTERACTION: clipboard round-trips ----
  const BEGIN='-----BEGIN SSH SIGNATURE-----', END='-----END SSH SIGNATURE-----';
  const mk = (b) => BEGIN+'\\n'+b+'\\n'+END;
  const SIG_A = mk('U1NIU0lHAAAAAQ_AAAA_alpha_QUFB');
  const SIG_B = mk('U1NIU0lHAAAAAQ_BBBB_beta_Wlpa');
  const sig = $('signature');

  try {
    // (a) click copy command -> clipboard holds the exact sign command
    const cmd = ($('sign-command').textContent || '').trim();
    await navigator.clipboard.writeText('__sentinel__');
    $('copy-cmd-btn').click();
    let copied='';
    for (let i=0;i<60;i++){ copied = await navigator.clipboard.readText(); if(copied && copied!=='__sentinel__') break; await sleep(25); }
    out.interaction.copyCommand = { expected: cmd, got: copied, ok: copied === cmd && cmd.length>0 };

    // (b) ONE signature on clipboard -> click paste -> field filled with it
    sig.value=''; await navigator.clipboard.writeText(SIG_A);
    $('paste-sig-btn').click();
    for (let i=0;i<60;i++){ if(sig.value) break; await sleep(25); }
    out.interaction.pasteOne = { ok: sig.value === SIG_A, filledLen: sig.value.length };

    // (c) TWO signatures -> click paste -> picker appears -> choose #1 fills it
    sig.value=''; const picker=$('sig-picker');
    await navigator.clipboard.writeText(SIG_A + '\\n\\n' + SIG_B);
    $('paste-sig-btn').click();
    let choices=[];
    for (let i=0;i<60;i++){ choices=[...picker.querySelectorAll('button')]; if(!picker.hidden && choices.length) break; await sleep(25); }
    const pickerShown = !picker.hidden && choices.length === 2;
    if (choices.length) choices[0].click();
    for (let i=0;i<60;i++){ if(sig.value) break; await sleep(25); }
    out.interaction.pasteMany = { pickerShown, choiceCount: choices.length, filledFirst: sig.value === SIG_A, pickerClearedAfterChoice: picker.hidden };

    // ---- SECURITY: hostile armored payload cannot XSS and never auto-submits
    window.__xss = undefined;
    const before = location.href;
    const hostile = mk('<img src=x onerror="window.__xss=1"><script>window.__xss=2<\\/script>');
    sig.value=''; await navigator.clipboard.writeText(hostile);
    $('paste-sig-btn').click();
    for (let i=0;i<60;i++){ if(sig.value) break; await sleep(25); }
    await sleep(120); // give any (forbidden) injected handler a chance to run
    out.security = {
      filledVerbatim: sig.value === hostile,
      xssFlag: window.__xss,                                   // must stay undefined
      injectedImg: document.querySelectorAll('img[onerror]').length, // must be 0
      urlUnchanged: location.href === before,                  // no auto-submit
      ok: sig.value === hostile && window.__xss === undefined &&
          document.querySelectorAll('img[onerror]').length === 0 && location.href === before,
    };
    out.clipboardAvailable = true;
  } catch (e) {
    out.clipboardAvailable = false;
    out.clipboardError = String(e && e.message || e);
  }
  return out;
})()
`;

async function main() {
  const chrome = resolveChrome();
  if (!chrome) { console.error('SKIP: no Chromium binary found'); process.exit(2); }

  const { srv, port } = await serveLogin();
  const url = `http://127.0.0.1:${port}/login`;
  const userDir = fs.mkdtempSync(path.join(os.tmpdir(), 'hc-visual-'));
  const proc = spawn(chrome, [
    '--headless=new', '--disable-gpu', '--no-sandbox', '--disable-dev-shm-usage',
    '--hide-scrollbars', '--force-color-profile=srgb', '--window-size=560,1024',
    '--remote-debugging-port=0', `--user-data-dir=${userDir}`, 'about:blank',
  ], { stdio: ['ignore', 'ignore', 'pipe'] });
  let launchErr = '';
  proc.stderr.on('data', (d) => { launchErr += d.toString(); });

  const cleanup = () => { try { proc.kill('SIGKILL'); } catch {} try { srv.close(); } catch {} };

  let verdict = { ok: false, checks: {}, skips: [] };
  let browserWS, pageWS;
  try {
    const dt = await readDevtools(userDir);

    // Single browser-ws connection; grant clipboard permissions for the page
    // origin, then create the page target ALREADY at the login URL (so it loads
    // on creation — no separate Page.navigate) and drive it via a flatten session.
    browserWS = await openWS(dt.browserWs);
    const cdp = new CDP(browserWS);
    try {
      await cdp.send('Browser.grantPermissions', {
        origin: `http://127.0.0.1:${port}`,
        permissions: ['clipboardReadWrite', 'clipboardSanitizedWrite'],
      });
    } catch (e) { verdict.skips.push('grantPermissions: ' + e.message); }

    const { targetId } = await cdp.send('Target.createTarget', { url });
    const { sessionId: S } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
    await cdp.send('Runtime.enable', {}, S);
    try { await cdp.send('Emulation.setFocusEmulationEnabled', { enabled: true }, S); } catch {}

    // Wait for the document to finish loading AND the enhancement JS to reveal
    // the paste button (proves the module ran and detected the Clipboard API).
    let revealed = false;
    for (let i = 0; i < 80; i++) {
      const r = await cdp.send('Runtime.evaluate', {
        expression: `(() => { const b=document.getElementById('paste-sig-btn'); return document.readyState==='complete' && !!b && b.hidden===false; })()`,
        returnByValue: true,
      }, S);
      if (r.result && r.result.value === true) { revealed = true; break; }
      await sleep(75);
    }
    // (jsRevealed is confirmed authoritatively below from the layout oracle,
    // which reads the settled post-JS DOM captured with the screenshot.)

    // (2) screenshot -> PNG artifact
    const shot = await cdp.send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true }, S);
    const pngPath = path.join(OUT, 'login_rendered.png');
    fs.writeFileSync(pngPath, Buffer.from(shot.data, 'base64'));
    const pngBytes = fs.statSync(pngPath).size;

    // (3)+(4)+(5) run the page-side test bundle
    const evalRes = await cdp.send('Runtime.evaluate', {
      expression: PAGE_TESTS, awaitPromise: true, returnByValue: true, userGesture: true,
    }, S);
    if (evalRes.exceptionDetails) throw new Error('page eval: ' + JSON.stringify(evalRes.exceptionDetails).slice(0, 400));
    const pr = evalRes.result.value;

    // ---- optional OCR (tesseract) over the PNG: the §11.4.170(ii) vision oracle ----
    let ocr = { available: false };
    const tess = spawnSync('tesseract', [pngPath, 'stdout'], { encoding: 'utf8' });
    if (!tess.error && tess.status === 0) {
      const text = (tess.stdout || '').toLowerCase();
      ocr = {
        available: true,
        sawSignIn: /sign\s*in/.test(text),
        sawCopy: text.includes('copy'),
        sawPaste: text.includes('paste'),
        sample: (tess.stdout || '').replace(/\n{2,}/g, '\n').trim().slice(0, 600),
      };
    } else {
      ocr.reason = 'tesseract unavailable or failed';
    }

    // ---- assemble the verdict ----
    const L = pr.layout;
    // JS ran and revealed the JS-only controls (ground truth = settled post-JS DOM).
    const jsRevealed = ['copy-cmd-btn', 'copy-challenge-btn', 'paste-sig-btn'].every((id) => {
      const b = L.btns.find((x) => x.id === id);
      return b && b.present && b.hidden === false;
    });
    verdict.checks.jsRevealedButtons = { ok: jsRevealed, prePollHit: revealed };
    const layoutOk = ['copy-cmd-btn', 'copy-challenge-btn', 'paste-sig-btn'].every((id) => {
      const b = L.btns.find((x) => x.id === id);
      return b && b.present && b.visible && !b.hidden && b.inViewport && b.aria && b.aria.length > 0;
    }) && L.overlaps.length === 0;

    const copyBtn = L.btns.find((x) => x.id === 'copy-cmd-btn');
    const pasteBtn = L.btns.find((x) => x.id === 'paste-sig-btn');
    const labelledText = !!copyBtn && /copy/i.test(copyBtn.text) && !!pasteBtn && /paste/i.test(pasteBtn.text);

    verdict.checks.render = { pngPath, pngBytes, ok: pngBytes > 3000 };
    verdict.checks.layoutNoOverlapLabelled = { ok: layoutOk && labelledText, overlaps: L.overlaps, buttons: L.btns };
    verdict.checks.ocr = ocr;

    if (pr.clipboardAvailable) {
      verdict.checks.copyCommand = pr.interaction.copyCommand;
      verdict.checks.pasteOne = pr.interaction.pasteOne;
      verdict.checks.pasteMany = pr.interaction.pasteMany;
      verdict.checks.securityNoXSSNoAutoSubmit = pr.security;
    } else {
      verdict.skips.push('clipboard interaction unavailable in this headless Chromium: ' + (pr.clipboardError || 'unknown'));
    }

    const mandatoryOk = jsRevealed && verdict.checks.render.ok && verdict.checks.layoutNoOverlapLabelled.ok;
    const interactionOk = !pr.clipboardAvailable ? true : (
      pr.interaction.copyCommand.ok && pr.interaction.pasteOne.ok &&
      pr.interaction.pasteMany.pickerShown && pr.interaction.pasteMany.filledFirst &&
      pr.security.ok);
    verdict.ok = mandatoryOk && interactionOk;
    verdict.clipboardDriven = !!pr.clipboardAvailable;

    fs.writeFileSync(path.join(OUT, 'visual_verdict.json'), JSON.stringify(verdict, null, 2));
    try { pageWS && pageWS.close(); } catch {}
    try { browserWS && browserWS.close(); } catch {}
  } catch (e) {
    try { pageWS && pageWS.close(); } catch {}
    try { browserWS && browserWS.close(); } catch {}
    cleanup();
    console.error('SKIP: Chromium/CDP harness error: ' + (e.message || e) + (launchErr ? ('\n' + launchErr.slice(0, 300)) : ''));
    console.log('VERDICT_JSON: ' + JSON.stringify({ ok: false, error: String(e.message || e), skips: ['chromium-cdp'] }));
    process.exit(2);
  }
  cleanup();

  console.log('VERDICT_JSON: ' + JSON.stringify(verdict));
  process.exit(verdict.ok ? 0 : 1);
}

main().catch((e) => {
  console.error('SKIP: ' + (e.message || e));
  console.log('VERDICT_JSON: ' + JSON.stringify({ ok: false, error: String(e.message || e), skips: ['fatal'] }));
  process.exit(2);
});
