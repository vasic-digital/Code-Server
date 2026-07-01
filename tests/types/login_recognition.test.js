/*
 * tests/types/login_recognition.test.js — §11.4.169 UNIT layer for the login
 * page's armored-SSH-signature recognizer.
 *
 * Drives services/auth_gate/assets/login_enhance.js `recognizeSignatures()`
 * directly (the SAME file embedded into the served /login page — single source
 * of truth). This is the ONLY layer where isolation is permitted (§11.4.27):
 * the module is loaded under node with NO DOM, so the pure recognizer is tested
 * standalone. All other layers (Go served-page, shell edge, §11.4.170 visual)
 * exercise the real rendered page.
 *
 * Run:  node --test tests/types/login_recognition.test.js
 * Cross-refs: §11.4.169 §11.4.27 §11.4.107 (1-vs-many-vs-none, noisy, verbatim).
 */
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

const MOD = path.resolve(__dirname, '../../services/auth_gate/assets/login_enhance.js');
const enhance = require(MOD);
const { recognizeSignatures, init } = enhance;

const BEGIN = '-----BEGIN SSH SIGNATURE-----';
const END = '-----END SSH SIGNATURE-----';

// A realistic (structurally valid armor, non-secret) fixture block.
function block(body) {
  return BEGIN + '\n' + body + '\n' + END;
}
const SIG_A = block(
  'U1NIU0lHAAAAAQAAADMAAAALc3NoLWVkMjU1MTkAAAAgQUFBQUFBQUFBQUFBQUFB\n' +
  'QUFBQUFBQUFBQUFBQUFBQUFBAAAAA2Zvbw==');
const SIG_B = block(
  'U1NIU0lHAAAAAQAAADMAAAALc3NoLWVkMjU1MTkAAAAgWlpaWlpaWlpaWlpaWlpa\n' +
  'WlpaWlpaWlpaWlpaWlpaWlpaAAAAA2Jhcg==');

test('module surface: exports the two functions', () => {
  assert.equal(typeof recognizeSignatures, 'function');
  assert.equal(typeof init, 'function');
});

test('NONE: empty / non-string / no-marker inputs yield []', () => {
  assert.deepEqual(recognizeSignatures(''), []);
  assert.deepEqual(recognizeSignatures(null), []);
  assert.deepEqual(recognizeSignatures(undefined), []);
  assert.deepEqual(recognizeSignatures(42), []);
  assert.deepEqual(recognizeSignatures({}), []);
  assert.deepEqual(recognizeSignatures('just some clipboard text, no signature here'), []);
  // a lone BEGIN with no END is not a complete block
  assert.deepEqual(recognizeSignatures(BEGIN + '\nabc\n(no end marker)'), []);
});

test('ONE: a single block is recognized (and returned verbatim, trimmed)', () => {
  const got = recognizeSignatures(SIG_A);
  assert.equal(got.length, 1);
  assert.equal(got[0], SIG_A);
  assert.ok(got[0].startsWith(BEGIN));
  assert.ok(got[0].endsWith(END));
});

test('ONE (noisy): a block embedded in surrounding log noise is extracted', () => {
  const noisy =
    'user@host:~$ printf %s ... | ssh-keygen -Y sign ...\n' +
    'wrote signature to stdout:\n' +
    SIG_A + '\n' +
    '$ # done, please paste the above\n';
  const got = recognizeSignatures(noisy);
  assert.equal(got.length, 1);
  assert.equal(got[0], SIG_A); // exactly the block, noise stripped
});

test('MANY: two concatenated blocks are recognized individually', () => {
  const got = recognizeSignatures(SIG_A + '\n\n' + SIG_B);
  assert.equal(got.length, 2);
  assert.equal(got[0], SIG_A);
  assert.equal(got[1], SIG_B);
});

test('MANY (noisy): three blocks interleaved with junk', () => {
  const got = recognizeSignatures(
    '--- key 1 ---\n' + SIG_A + '\n--- key 2 ---\n' + SIG_B + '\n--- key 3 ---\n' + SIG_A);
  assert.equal(got.length, 3);
  assert.equal(got[0], SIG_A);
  assert.equal(got[1], SIG_B);
  assert.equal(got[2], SIG_A);
});

test('SECURITY: the recognizer returns bytes verbatim and never executes/transforms them', () => {
  // A hostile payload wrapped in armor is still returned as an inert string —
  // the browser layer assigns it to textarea.value (proven in the visual driver),
  // so it can never become markup. The recognizer must not alter/strip it.
  const hostile = block('<img src=x onerror="window.__xss=1">');
  const got = recognizeSignatures(hostile);
  assert.equal(got.length, 1);
  assert.equal(got[0], hostile);
  assert.ok(got[0].includes('<img src=x onerror='));
});

test('init() is DOM-safe under node: no crash without a document', () => {
  assert.doesNotThrow(() => init());
  assert.doesNotThrow(() => init(null));
  assert.doesNotThrow(() => init({})); // object without getElementById -> no-op
});
