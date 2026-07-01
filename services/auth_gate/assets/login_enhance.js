/* login_enhance.js — client-side progressive enhancement for the HelixCode
 * SSH-key login page.
 *
 * Adds accessible copy (sign command / challenge) + paste (recognize an armored
 * SSH signature) icon buttons. It is PROGRESSIVE ENHANCEMENT and degrades
 * gracefully: with JavaScript disabled, the Clipboard API absent, an insecure
 * context, or a permission denial, manual copy/paste still works and NO dead
 * button is ever shown (the buttons stay `hidden` until their capability is
 * confirmed). It NEVER auto-submits the form, and a recognized signature is set
 * as the textarea's `.value` ONLY (never as HTML), so a hostile clipboard
 * payload cannot inject markup (no XSS).
 *
 * Single source of truth / dual role:
 *   - browser: auto-initialises against `document` once the DOM is ready.
 *   - node   : `module.exports = { recognizeSignatures, init }` for the unit
 *              test (tests/types/login_recognition.test.js). NO DOM is touched
 *              when running under node, so the recognizer can be tested in
 *              isolation (mocks permitted at the unit layer, §11.4.27).
 *
 * The exact bytes of this file are embedded verbatim into the served /login
 * page (services/auth_gate/server.go `//go:embed`), so the served-page test can
 * assert the recognizer is present in the rendered HTML.
 *
 * Cross-refs: §11.4.107 (real behaviour, not a single frame) · §11.4.10 (no
 * secrets) · §11.4.162 (no overlapping labels) · §11.4.170 (host-rendered proof).
 */
(function (root, factory) {
  'use strict';
  var api = factory();
  if (typeof module === 'object' && module.exports) {
    module.exports = api; // node unit test
  } else {
    root.HelixLoginEnhance = api; // browser global (aids debugging + the visual harness)
    if (typeof document !== 'undefined') {
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', function () { api.init(document); });
      } else {
        api.init(document);
      }
    }
  }
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  var BEGIN = '-----BEGIN SSH SIGNATURE-----';

  // A FRESH regex per call so no `lastIndex` state leaks between invocations.
  // Non-greedy `*?` so several concatenated blocks are captured individually;
  // the literal armor markers bound each block and arbitrary surrounding noise
  // is ignored.
  function sigRegex() {
    return /-----BEGIN SSH SIGNATURE-----[\s\S]*?-----END SSH SIGNATURE-----/g;
  }

  // recognizeSignatures(text) -> array of full armored blocks (each trimmed).
  // Pure and side-effect-free — the unit test drives this directly. Returns []
  // for a non-string, empty string, or text with no BEGIN marker (no crash).
  function recognizeSignatures(text) {
    if (typeof text !== 'string' || text.indexOf(BEGIN) === -1) return [];
    var re = sigRegex();
    var out = [];
    var m;
    while ((m = re.exec(text)) !== null) {
      var block = m[0].trim();
      if (block) out.push(block);
      if (re.lastIndex === m.index) re.lastIndex++; // defensive: never zero-width here
    }
    return out;
  }

  // ---- capability probes (insecure context => navigator.clipboard undefined) --
  function hasClipboardWrite() {
    return typeof navigator !== 'undefined' && !!navigator.clipboard &&
      typeof navigator.clipboard.writeText === 'function';
  }
  function hasClipboardRead() {
    return typeof navigator !== 'undefined' && !!navigator.clipboard &&
      typeof navigator.clipboard.readText === 'function';
  }

  function init(doc) {
    if (!doc || typeof doc.getElementById !== 'function') return;

    var status = doc.getElementById('enhance-status');
    var setStatus = function (msg, kind) {
      if (!status) return;
      status.textContent = msg || ''; // textContent — never HTML
      status.className = 'enhance-status' + (kind ? ' ' + kind : '');
    };
    var flash = function (msg, kind) {
      setStatus(msg, kind);
      if (status && msg) {
        clearTimeout(status._t);
        status._t = setTimeout(function () { setStatus('', ''); }, 2500);
      }
    };
    var reveal = function (el) { if (el) el.hidden = false; };

    // ---- copy buttons: only revealed when clipboard write is usable ----
    if (hasClipboardWrite()) {
      wireCopy(doc.getElementById('copy-cmd-btn'), function () {
        var el = doc.getElementById('sign-command');
        return el ? el.textContent : '';
      }, 'Command copied ✓', flash);
      wireCopy(doc.getElementById('copy-challenge-btn'), function () {
        var el = doc.getElementById('challenge');
        return el ? el.value : '';
      }, 'Challenge copied ✓', flash);
      reveal(doc.getElementById('cmd-actions'));
      reveal(doc.getElementById('copy-challenge-btn'));
    }

    // ---- paste button: only revealed when clipboard read is usable ----
    if (hasClipboardRead()) {
      var pasteBtn = doc.getElementById('paste-sig-btn');
      if (pasteBtn) {
        pasteBtn.addEventListener('click', function () { handlePaste(doc, flash); });
        reveal(pasteBtn);
      }
    }
  }

  function wireCopy(btn, getText, okMsg, flash) {
    if (!btn) return;
    btn.addEventListener('click', function () {
      var text = getText();
      if (!text) { flash('Nothing to copy.', 'warn'); return; }
      navigator.clipboard.writeText(text).then(function () {
        flash(okMsg, 'ok');
      }, function () {
        flash('Clipboard blocked — select and copy manually.', 'warn');
      });
    });
  }

  function handlePaste(doc, flash) {
    navigator.clipboard.readText().then(function (text) {
      var sigs = recognizeSignatures(text);
      var picker = doc.getElementById('sig-picker');
      clearPicker(picker);
      if (sigs.length === 0) {
        flash('No SSH signature found on the clipboard — copy the full BEGIN/END block.', 'warn');
        return;
      }
      if (sigs.length === 1) {
        fillSignature(doc, sigs[0]);
        flash('Signature pasted ✓', 'ok');
        return;
      }
      buildPicker(doc, picker, sigs, flash); // more than one -> inline chooser
      flash('Multiple signatures found — choose one below.', 'warn');
    }, function () {
      flash('Clipboard read blocked — paste manually into the box.', 'warn');
    });
  }

  // Set the recognized block as the textarea VALUE ONLY (assigned as text, never
  // as markup) — and never a submit: the user still clicks "Sign in" (no
  // clipboard-driven auto-login).
  function fillSignature(doc, block) {
    var ta = doc.getElementById('signature');
    if (!ta) return;
    ta.value = block;
    ta.focus();
  }

  function clearPicker(picker) {
    if (!picker) return;
    while (picker.firstChild) picker.removeChild(picker.firstChild);
    picker.hidden = true;
  }

  function buildPicker(doc, picker, sigs, flash) {
    if (!picker) return;
    for (var i = 0; i < sigs.length; i++) {
      (function (block, idx) {
        var b = doc.createElement('button');
        b.type = 'button'; // never a submit button
        b.className = 'sig-choice';
        // textContent only — the length is derived, clipboard bytes never
        // become markup on this page.
        b.textContent = 'Use signature ' + (idx + 1) + ' (' + block.length + ' chars)';
        b.setAttribute('aria-label', 'Use SSH signature ' + (idx + 1) + ' of ' + sigs.length);
        b.addEventListener('click', function () {
          fillSignature(doc, block);
          clearPicker(picker);
          flash('Signature ' + (idx + 1) + ' pasted ✓', 'ok');
        });
        picker.appendChild(b);
      })(sigs[i], i);
    }
    picker.hidden = false;
  }

  return { recognizeSignatures: recognizeSignatures, init: init };
});
