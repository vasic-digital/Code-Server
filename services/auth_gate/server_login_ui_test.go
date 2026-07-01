package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

// renderLoginBody renders GET /login with an accept-all verifier and returns the
// body. It shares the server_test.go test helpers (same package).
func renderLoginBody(t *testing.T) string {
	t.Helper()
	srv := newTestServer(t, acceptAllVerifier{})
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/login", nil)
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /login status = %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}
	return rec.Body.String()
}

// TestLoginPageServesEnhancementControls proves the served /login HTML carries
// the copy + paste icon buttons AND the inlined recognizer module — the
// served-page half of §11.4.170. It also confirms the buttons ship HIDDEN
// (progressive enhancement: no dead button without JS) and are accessible.
func TestLoginPageServesEnhancementControls(t *testing.T) {
	body := renderLoginBody(t)

	// --- the two icon buttons the feature adds are present ---
	wantMarkers := []string{
		`id="copy-cmd-btn"`,       // copy the ready-to-run sign command
		`id="copy-challenge-btn"`, // copy the bare challenge
		`id="paste-sig-btn"`,      // paste + recognize an armored signature
		`id="sign-command"`,       // the command the copy button reads
		`id="sig-picker"`,         // the >1-signature inline chooser mount
		`id="enhance-status"`,     // the aria-live feedback line
	}
	for _, m := range wantMarkers {
		if !strings.Contains(body, m) {
			t.Errorf("served /login is missing enhancement marker %q", m)
		}
	}

	// --- accessibility: every icon button carries an aria-label + a visible
	// focus target; the status region is a polite live region ---
	wantA11y := []string{
		`aria-label="Copy the ssh-keygen sign command to the clipboard"`,
		`aria-label="Copy the challenge value to the clipboard"`,
		`aria-label="Paste an SSH signature from the clipboard"`,
		`role="status"`,
		`aria-live="polite"`,
	}
	for _, m := range wantA11y {
		if !strings.Contains(body, m) {
			t.Errorf("served /login is missing accessibility marker %q", m)
		}
	}

	// --- graceful degradation: the JS-only controls ship hidden and are
	// type="button" so they never submit the form / show as dead buttons ---
	if !strings.Contains(body, `class="cmd-actions" id="cmd-actions" hidden`) {
		t.Error("copy-command action row must ship hidden (revealed by JS only)")
	}
	if !strings.Contains(body, `id="paste-sig-btn" hidden`) {
		t.Error("paste button must ship hidden (revealed by JS only)")
	}
	if strings.Contains(body, `id="copy-cmd-btn" type="submit"`) ||
		strings.Contains(body, `id="paste-sig-btn" type="submit"`) {
		t.Error("enhancement buttons must be type=button, never submit")
	}
	if n := strings.Count(body, `type="button"`); n < 3 {
		t.Errorf("expected >=3 type=button controls, found %d", n)
	}
}

// TestLoginPageEmbedsRecognizer proves the recognizer module is inlined verbatim
// into the served page (the served-page test the task requires can grep the JS),
// and that it is the SAME source the node unit test imports.
func TestLoginPageEmbedsRecognizer(t *testing.T) {
	body := renderLoginBody(t)

	wantJS := []string{
		"function recognizeSignatures(",                                      // the recognizer entry point
		"-----BEGIN SSH SIGNATURE-----[\\s\\S]*?-----END SSH SIGNATURE-----", // the armor-block regex
		"HelixLoginEnhance",                                                  // the browser global it installs
		"navigator.clipboard",                                                // clipboard-driven behaviour
	}
	for _, m := range wantJS {
		if !strings.Contains(body, m) {
			t.Errorf("served /login does not inline recognizer marker %q", m)
		}
	}
	// The embedded module and the served page MUST be byte-identical for the
	// recognizer (single source of truth with the node unit test).
	if !strings.Contains(body, loginEnhanceJS) {
		t.Error("served /login does not contain the embedded assets/login_enhance.js verbatim")
	}
}

// TestLoginEnhancementCannotXSSorAutoSubmit is the STATIC security guard for the
// paste path (the behavioural proof lives in the §11.4.170 visual driver). The
// recognized clipboard text is only ever assigned to a textarea's .value — never
// innerHTML — and the module never programmatically submits the form.
func TestLoginEnhancementCannotXSSorAutoSubmit(t *testing.T) {
	js := loginEnhanceJS

	// It MUST insert the signature as textarea .value (text), never HTML.
	if !strings.Contains(js, "ta.value = block") {
		t.Error("recognizer must set the signature as textarea .value (text, not HTML)")
	}
	// It MUST NOT use innerHTML anywhere (would let clipboard bytes become markup).
	if strings.Contains(js, "innerHTML") {
		t.Error("enhancement JS must never use innerHTML (XSS vector for clipboard content)")
	}
	// It MUST NOT auto-submit — the user always clicks Sign in (no clipboard-driven login).
	for _, bad := range []string{".submit()", ".submit(", "form.submit", "requestSubmit"} {
		if strings.Contains(js, bad) {
			t.Errorf("enhancement JS must never auto-submit the form (found %q)", bad)
		}
	}
	// Picker choices are built via createElement + textContent, not markup strings.
	if !strings.Contains(js, "createElement('button')") || !strings.Contains(js, "b.textContent =") {
		t.Error("signature picker must be built with createElement + textContent (no HTML injection)")
	}
}

// TestRenderLoginArtifact is a harness helper (NOT a standalone assertion): when
// HELIX_LOGIN_ARTIFACT names a path it writes the REAL rendered /login HTML there
// so the §11.4.170 host-render visual-proof driver can serve the genuine page.
// It Skips (no-op) otherwise, keeping `go test ./...` fast + hermetic.
func TestRenderLoginArtifact(t *testing.T) {
	out := os.Getenv("HELIX_LOGIN_ARTIFACT")
	if out == "" {
		t.Skip("HELIX_LOGIN_ARTIFACT unset — visual-proof artifact not requested")
	}
	body := renderLoginBody(t)
	if err := os.WriteFile(out, []byte(body), 0o644); err != nil {
		t.Fatalf("write login artifact to %s: %v", out, err)
	}
	t.Logf("wrote rendered /login (%d bytes) to %s", len(body), out)
}
