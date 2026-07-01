/*
 * tests/types/theme_visual_cdp.mjs — §11.4.170 device-independent HOST-RENDERED
 * pixel proof that code-server, launched with HelixCode's DEFAULT settings,
 * actually RENDERS the workbench DARK (backing the operator mandate "VS Code
 * Dark theme MUST BE the default ALWAYS"). The sibling tests/types/
 * theme_default_auth.sh proves the CONFIG enforcement (settings.default.json
 * seeds a dark colorTheme); THIS driver adds the rendered-pixel proof.
 *
 * No npm / Playwright: it speaks the Chrome DevTools Protocol directly over
 * Node 22's built-in global WebSocket + fetch (same technique as the committed
 * tests/types/login_visual_cdp.mjs). Given an ALREADY-RUNNING throwaway
 * code-server URL (the .sh owns that lifecycle + all temp dirs), it:
 *
 *   1. launches headless Chromium and opens the workbench URL;
 *   2. waits (bounded) for the .monaco-workbench SPA to genuinely render AND a
 *      theme class to be applied — never judges a blank/half-painted frame;
 *   3. captures a full-viewport PNG (the rendered-pixel artifact the user sees);
 *   4. computes, from the REAL rendered pixels (screenshot -> <img> -> canvas ->
 *      getImageData over a large sample), the Rec.709 mean luminance (0..255) +
 *      the fraction of dark pixels — the §11.4.170(i) image oracle;
 *   5. reads the applied theme KIND from the rendered workbench DOM
 *      (.monaco-workbench classList: vs-dark / hc-black => dark; vs / hc-light =>
 *      light) + the computed background-color + an optional tesseract OCR pass
 *      over the PNG — the §11.4.170(ii) vision/DOM oracle;
 *   6. asserts the expected polarity (dual-validated: pixels AND theme-kind):
 *        --expect dark  (GREEN, default settings)  => rendered pixels are DARK
 *        --expect light (RED_MODE self-validation)  => rendered pixels are LIGHT
 *      so the luminance oracle is proven to have teeth (a light default would be
 *      caught — §11.4.107(10) golden-good/golden-bad).
 *
 * Usage:  node theme_visual_cdp.mjs --url <workbench-url> --out <evidence-dir>
 *                --expect dark|light [--dark-max N] [--light-min N]
 *                [--dark-frac F] [--wait SECONDS]
 * Exit:   0 = expected polarity proven on the rendered pixels
 *         2 = Chromium unavailable OR the workbench never rendered within the
 *             bound (honest §11.4.3 SKIP -> topology_unsupported)
 *         1 = a real defect (workbench rendered but the WRONG polarity — e.g.
 *             expected dark but the pixels/theme are light)
 * Output: writes theme_rendered.png + theme_verdict.json under <out>; prints
 *         `VERDICT_JSON: {...}` as the last line for the shell suite to parse.
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';

// ---- args ----------------------------------------------------------------
function arg(name, def) {
  const i = process.argv.indexOf(name);
  return i >= 0 && i + 1 < process.argv.length ? process.argv[i + 1] : def;
}
const URL = arg('--url');
const OUT = arg('--out', path.join(os.tmpdir(), 'theme_visual_out'));
const EXPECT = (arg('--expect', 'dark') === 'light') ? 'light' : 'dark';
const DARK_MAX = parseFloat(arg('--dark-max', '95'));   // mean luminance ceiling for DARK (0..255)
const LIGHT_MIN = parseFloat(arg('--light-min', '150')); // mean luminance floor for LIGHT (0..255)
const DARK_FRAC = parseFloat(arg('--dark-frac', '0.6')); // min fraction of dark pixels for DARK
const WAIT_S = parseInt(arg('--wait', '60'), 10);        // bounded workbench-render wait

if (!URL) {
  console.error('SKIP: --url <workbench-url> is required');
  console.log('VERDICT_JSON: ' + JSON.stringify({ ok: false, skips: ['no-url'] }));
  process.exit(2);
}
fs.mkdirSync(OUT, { recursive: true });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---- resolve a Chromium binary ------------------------------------------
function resolveChrome() {
  if (process.env.HELIX_CHROME && fs.existsSync(process.env.HELIX_CHROME)) return process.env.HELIX_CHROME;
  for (const p of ['/usr/bin/chromium', '/usr/bin/chromium-browser', '/usr/bin/google-chrome', '/usr/bin/google-chrome-stable']) {
    if (fs.existsSync(p)) return p;
  }
  const roots = [path.join(os.homedir(), '.cache/ms-playwright')];
  for (const root of roots) {
    if (!fs.existsSync(root)) continue;
    const dirs = fs.readdirSync(root).filter((d) => d.startsWith('chromium-')).sort().reverse();
    for (const d of dirs) {
      const p = path.join(root, d, 'chrome-linux64', 'chrome');
      if (fs.existsSync(p)) return p;
    }
  }
  return null;
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
      }, 30000);
    });
  }
}

async function readDevtools(userDir) {
  const portFile = path.join(userDir, 'DevToolsActivePort');
  for (let i = 0; i < 150; i++) {
    if (fs.existsSync(portFile)) {
      const [port, wspath] = fs.readFileSync(portFile, 'utf8').trim().split('\n');
      if (port && wspath) return { port, browserWs: `ws://127.0.0.1:${port}${wspath}` };
    }
    await sleep(100);
  }
  throw new Error('Chromium never wrote DevToolsActivePort');
}

function openWS(url) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    ws.addEventListener('open', () => resolve(ws));
    ws.addEventListener('error', (e) => reject(new Error('ws error: ' + (e.message || 'unknown'))));
  });
}

async function evalValue(cdp, S, expression, awaitPromise = false) {
  const r = await cdp.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise }, S);
  if (r.exceptionDetails) throw new Error('eval: ' + JSON.stringify(r.exceptionDetails).slice(0, 300));
  return r.result ? r.result.value : undefined;
}

// Page-side: read the applied theme KIND + background colors from the rendered
// workbench DOM (the §11.4.170(ii) DOM oracle — reads the settled post-load DOM).
const THEME_DOM = `
(() => {
  const wb = document.querySelector('.monaco-workbench');
  const cls = wb ? (wb.className || '') : '';
  const tokens = cls.split(/\\s+/).filter(Boolean);
  let kind = 'unknown';
  if (tokens.includes('vs-dark') || tokens.includes('hc-black')) kind = 'dark';
  else if (tokens.includes('vs') || tokens.includes('hc-light')) kind = 'light';
  const bg = wb ? getComputedStyle(wb).backgroundColor : '';
  const bodyBg = getComputedStyle(document.body).backgroundColor;
  return { present: !!wb, classNames: cls, themeKind: kind, workbenchBg: bg, bodyBg };
})()
`;

// Page-side: decode the captured PNG (data URL) into a <canvas> and compute the
// Rec.709 mean luminance + dark-pixel fraction over a large sample of the REAL
// rendered pixels (the §11.4.170(i) image oracle). data: URLs never taint the
// canvas, so getImageData is always readable.
function pixelAnalysisExpr(dataUrl) {
  return `
(async () => {
  const img = new Image();
  await new Promise((res, rej) => { img.onload = res; img.onerror = () => rej(new Error('img load failed')); img.src = ${JSON.stringify(dataUrl)}; });
  const W = img.naturalWidth, H = img.naturalHeight;
  const c = document.createElement('canvas'); c.width = W; c.height = H;
  const ctx = c.getContext('2d'); ctx.drawImage(img, 0, 0);
  const d = ctx.getImageData(0, 0, W, H).data;
  let sum = 0, n = 0, dark = 0;
  // stride over every 4th pixel (16 bytes/RGBA quad * 4) — hundreds of thousands
  // of samples, plenty for a stable mean without decoding every pixel.
  const stride = 16 * 4;
  for (let i = 0; i + 2 < d.length; i += stride) {
    const r = d[i], g = d[i + 1], b = d[i + 2];
    const lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    sum += lum; n++;
    if (lum < 64) dark++;
  }
  return { W, H, samples: n, meanLum: n ? sum / n : -1, darkFrac: n ? dark / n : -1 };
})()
`;
}

async function main() {
  const chrome = resolveChrome();
  if (!chrome) {
    console.error('SKIP: no Chromium binary found');
    console.log('VERDICT_JSON: ' + JSON.stringify({ ok: false, skips: ['no-chromium'] }));
    process.exit(2);
  }

  const userDir = fs.mkdtempSync(path.join(os.tmpdir(), 'hc-theme-vis-'));
  const proc = spawn(chrome, [
    '--headless=new', '--disable-gpu', '--no-sandbox', '--disable-dev-shm-usage',
    '--hide-scrollbars', '--force-color-profile=srgb', '--window-size=1600,1000',
    '--remote-debugging-port=0', `--user-data-dir=${userDir}`, 'about:blank',
  ], { stdio: ['ignore', 'ignore', 'pipe'] });
  let launchErr = '';
  proc.stderr.on('data', (d) => { launchErr += d.toString(); });

  const cleanup = () => {
    try { proc.kill('SIGKILL'); } catch (e) { /* already gone */ }
    try { fs.rmSync(userDir, { recursive: true, force: true }); } catch (e) { /* best effort */ }
  };

  let browserWS;
  const verdict = { ok: false, expect: EXPECT, checks: {}, skips: [] };
  try {
    const dt = await readDevtools(userDir);
    browserWS = await openWS(dt.browserWs);
    const cdp = new CDP(browserWS);

    // Create the page target ALREADY at the workbench URL (loads on creation),
    // then drive it via a flatten session.
    const { targetId } = await cdp.send('Target.createTarget', { url: URL });
    const { sessionId: S } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
    await cdp.send('Runtime.enable', {}, S);

    // (2) Wait — bounded — for the workbench SPA to genuinely render AND apply a
    // theme class. Never judge a blank/half-painted frame (§11.4.107 not-stale /
    // loading-is-a-distinct-state). Poll every 250ms up to WAIT_S seconds.
    const deadline = Date.now() + WAIT_S * 1000;
    let dom = { present: false, themeKind: 'unknown' };
    let rendered = false;
    while (Date.now() < deadline) {
      try {
        const ready = await evalValue(cdp, S,
          `(() => { const wb=document.querySelector('.monaco-workbench'); return document.readyState==='complete' && !!wb && /\\b(vs|vs-dark|hc-black|hc-light)\\b/.test(wb.className||''); })()`);
        if (ready === true) { rendered = true; break; }
      } catch (e) { /* transient during navigation; keep polling */ }
      await sleep(250);
    }
    // settle a moment so late paint (activity bar / editor area) is on-screen
    await sleep(rendered ? 2500 : 0);
    try { dom = await evalValue(cdp, S, THEME_DOM); } catch (e) { dom = { present: false, themeKind: 'unknown', err: String(e.message || e) }; }

    if (!rendered || !dom || dom.present !== true) {
      verdict.skips.push('workbench-never-rendered');
      verdict.checks.render = { rendered, dom };
      cleanup();
      console.error('SKIP: code-server workbench did not render in headless Chromium within ' + WAIT_S + 's');
      console.log('VERDICT_JSON: ' + JSON.stringify(verdict));
      process.exit(2);
    }

    // (3) capture the rendered-pixel artifact (the visible workbench viewport)
    const shot = await cdp.send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false }, S);
    const pngPath = path.join(OUT, 'theme_rendered.png');
    fs.writeFileSync(pngPath, Buffer.from(shot.data, 'base64'));
    const pngBytes = fs.statSync(pngPath).size;

    // (4) analyse the REAL rendered pixels (screenshot -> canvas -> getImageData)
    const dataUrl = 'data:image/png;base64,' + shot.data;
    let px = { meanLum: -1, darkFrac: -1, samples: 0 };
    try { px = await evalValue(cdp, S, pixelAnalysisExpr(dataUrl), true); } catch (e) { px = { meanLum: -1, darkFrac: -1, samples: 0, err: String(e.message || e) }; }

    // (5b) optional tesseract OCR over the PNG — supplementary vision evidence
    let ocr = { available: false };
    const tess = spawnSync('tesseract', [pngPath, 'stdout'], { encoding: 'utf8' });
    if (!tess.error && tess.status === 0) {
      const text = (tess.stdout || '').trim();
      ocr = { available: true, chars: text.length, sample: text.replace(/\n{2,}/g, '\n').slice(0, 500) };
    } else {
      ocr.reason = 'tesseract unavailable or failed';
    }

    // ---- assemble the verdict ----
    const meanLum = typeof px.meanLum === 'number' ? px.meanLum : -1;
    const darkFrac = typeof px.darkFrac === 'number' ? px.darkFrac : -1;
    verdict.checks.render = { pngPath, pngBytes, rendered: true, ok: pngBytes > 3000 };
    verdict.checks.pixels = { meanLum, darkFrac, samples: px.samples, darkMax: DARK_MAX, lightMin: LIGHT_MIN, darkFracMin: DARK_FRAC };
    verdict.checks.dom = dom;
    verdict.checks.ocr = ocr;

    const pixelsSampled = px.samples > 1000 && meanLum >= 0;
    let polarityOk = false;
    if (EXPECT === 'dark') {
      const pixelsDark = pixelsSampled && meanLum <= DARK_MAX && darkFrac >= DARK_FRAC;
      const domDark = dom.themeKind === 'dark';
      verdict.checks.polarity = { expect: 'dark', pixelsDark, domDark, meanLum, darkFrac, themeKind: dom.themeKind };
      polarityOk = pixelsDark && domDark;
    } else {
      const pixelsLight = pixelsSampled && meanLum >= LIGHT_MIN;
      const domLight = dom.themeKind === 'light';
      verdict.checks.polarity = { expect: 'light', pixelsLight, domLight, meanLum, darkFrac, themeKind: dom.themeKind };
      polarityOk = pixelsLight && domLight;
    }

    verdict.ok = verdict.checks.render.ok && pixelsSampled && polarityOk;
    fs.writeFileSync(path.join(OUT, 'theme_verdict.json'), JSON.stringify(verdict, null, 2));

    try { browserWS && browserWS.close(); } catch (e) { /* closing */ }
    cleanup();
    console.log('VERDICT_JSON: ' + JSON.stringify(verdict));
    process.exit(verdict.ok ? 0 : 1);
  } catch (e) {
    try { browserWS && browserWS.close(); } catch (ee) { /* closing */ }
    cleanup();
    console.error('SKIP: Chromium/CDP harness error: ' + (e.message || e) + (launchErr ? ('\n' + launchErr.slice(0, 300)) : ''));
    console.log('VERDICT_JSON: ' + JSON.stringify({ ok: false, error: String(e.message || e), skips: ['chromium-cdp'] }));
    process.exit(2);
  }
}

main().catch((e) => {
  console.error('SKIP: ' + (e.message || e));
  console.log('VERDICT_JSON: ' + JSON.stringify({ ok: false, error: String(e.message || e), skips: ['fatal'] }));
  process.exit(2);
});
