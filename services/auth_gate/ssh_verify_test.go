package main

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// This file is the §11.4.98 autonomous, real-evidence proof of the SSH-key
// challenge-response: it drives the REAL `ssh-keygen` tool (a genuine system
// binary, not a mock — allowed at any test level per §11.4.27) end to end. It
// generates throwaway keys, builds an allowed-signers set from a pubkey, mints
// a real challenge, signs it, and asserts: valid → accepted; tampered → reject;
// non-authorized key → reject; expired challenge → reject; replay → reject.
//
// It is SKIP-with-reason ONLY when ssh-keygen is absent (§11.4.3), never a
// silent pass.

// requireSSHKeygen skips the test if ssh-keygen is not on PATH.
func requireSSHKeygen(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("ssh-keygen"); err != nil {
		t.Skipf("ssh-keygen not available (%v) — SKIP with reason per §11.4.3", err)
	}
}

// genEd25519Key generates a passphrase-less ed25519 keypair at path (path +
// ".pub" is the public key). It fails the test on error (setup, not the SUT).
func genEd25519Key(t *testing.T, path string) {
	t.Helper()
	cmd := exec.Command("ssh-keygen", "-t", "ed25519", "-N", "", "-C", "helix-auth-test", "-f", path)
	var errb bytes.Buffer
	cmd.Stderr = &errb
	if err := cmd.Run(); err != nil {
		t.Fatalf("ssh-keygen keygen failed: %v: %s", err, errb.String())
	}
}

// signChallenge signs challenge with the private key at keyPath using the
// service namespace, returning the armored signature (ssh-keygen writes it to
// stdout when the data is read from stdin). This is exactly what a real user
// runs: `printf %s '<challenge>' | ssh-keygen -Y sign -n <ns> -f <key>`.
func signChallenge(t *testing.T, keyPath, challenge string) string {
	return signChallengeNS(t, keyPath, challenge, sshSigNamespace)
}

// signChallengeNS is signChallenge with an explicit namespace, used to prove a
// signature made under a different namespace is rejected.
func signChallengeNS(t *testing.T, keyPath, challenge, namespace string) string {
	t.Helper()
	cmd := exec.Command("ssh-keygen", "-Y", "sign", "-n", namespace, "-f", keyPath)
	cmd.Stdin = strings.NewReader(challenge)
	var out, errb bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errb
	if err := cmd.Run(); err != nil {
		t.Fatalf("ssh-keygen sign failed: %v: %s", err, errb.String())
	}
	sig := out.String()
	if !strings.Contains(sig, "BEGIN SSH SIGNATURE") {
		t.Fatalf("signature output not armored: %q", sig)
	}
	return sig
}

// tamperSignature flips one character inside the base64 body of an armored
// signature, corrupting it while keeping the armor structure.
func tamperSignature(t *testing.T, sig string) string {
	t.Helper()
	lines := strings.Split(sig, "\n")
	for i, ln := range lines {
		if strings.Contains(ln, "SSH SIGNATURE") || len(ln) < 8 {
			continue
		}
		b := []byte(ln)
		mid := len(b) / 2
		if b[mid] == 'A' {
			b[mid] = 'B'
		} else {
			b[mid] = 'A'
		}
		lines[i] = string(b)
		return strings.Join(lines, "\n")
	}
	t.Fatal("could not find a base64 body line to tamper")
	return sig
}

// sshTestFixture wires a real sshSigVerifier + Server over a throwaway key and
// authorized_keys, plus a second (non-authorized) key.
type sshTestFixture struct {
	srv           *Server
	authKeyPath   string // authorized private key
	otherKeyPath  string // NOT in authorized_keys
	authorizedKey string // path to authorized_keys file
}

func newSSHTestFixture(t *testing.T) *sshTestFixture {
	t.Helper()
	dir := t.TempDir()

	authKey := filepath.Join(dir, "id_ed25519")
	genEd25519Key(t, authKey)
	otherKey := filepath.Join(dir, "other_ed25519")
	genEd25519Key(t, otherKey)

	pub, err := os.ReadFile(authKey + ".pub")
	if err != nil {
		t.Fatalf("read pubkey: %v", err)
	}
	ak := filepath.Join(dir, "authorized_keys")
	if err := os.WriteFile(ak, pub, 0o600); err != nil {
		t.Fatalf("write authorized_keys: %v", err)
	}

	cfg := Config{
		Mode:            modeSSHKey,
		Account:         "milosvasic",
		Principal:       "milosvasic",
		AuthorizedKeys:  ak,
		SessionTTL:      time.Hour,
		ChallengeTTL:    2 * time.Minute,
		RateLimitMax:    50,
		RateLimitWindow: time.Minute,
	}
	v := newSSHSigVerifier(ak, "milosvasic", 5*time.Second)
	srv, err := NewServer(cfg, testSecret(), v, func() time.Time { return fixedNow })
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}
	return &sshTestFixture{srv: srv, authKeyPath: authKey, otherKeyPath: otherKey, authorizedKey: ak}
}

// postSigned runs POST /login with the given token/signature and returns the
// recorder.
func (f *sshTestFixture) postSigned(token, signature, ip string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	f.srv.Handler().ServeHTTP(rec, loginForm(token, "milosvasic", signature, ip))
	return rec
}

// TestSSHVerifierDirect exercises the sshSigVerifier against real ssh-keygen:
// valid accepted, tampered rejected, non-authorized key rejected.
func TestSSHVerifierDirect(t *testing.T) {
	requireSSHKeygen(t)
	f := newSSHTestFixture(t)
	v := f.srv.verifier

	challenge, _, _, err := f.srv.challenge.Mint(fixedNow)
	if err != nil {
		t.Fatalf("Mint: %v", err)
	}

	// Valid signature by the authorized key → accepted.
	sig := signChallenge(t, f.authKeyPath, challenge)
	if err := v.Verify([]byte(challenge), sig); err != nil {
		t.Errorf("valid signature rejected: %v", err)
	}

	// Tampered signature → rejected.
	if err := v.Verify([]byte(challenge), tamperSignature(t, sig)); err == nil {
		t.Error("tampered signature accepted")
	}

	// Signature over a DIFFERENT challenge (wrong message) → rejected.
	otherChallenge, _, _, _ := f.srv.challenge.Mint(fixedNow)
	sigOtherMsg := signChallenge(t, f.authKeyPath, otherChallenge)
	if err := v.Verify([]byte(challenge), sigOtherMsg); err == nil {
		t.Error("signature over a different challenge accepted")
	}

	// Non-authorized key signing the right challenge → rejected.
	sigUnauth := signChallenge(t, f.otherKeyPath, challenge)
	if err := v.Verify([]byte(challenge), sigUnauth); err == nil {
		t.Error("signature by a non-authorized key accepted")
	}

	// A signature in the WRONG namespace → rejected (the user must sign with
	// -n helixcode-login; a git/other-namespace signature must not log in).
	sigWrongNS := signChallengeNS(t, f.authKeyPath, challenge, "git")
	if err := v.Verify([]byte(challenge), sigWrongNS); err == nil {
		t.Error("signature in a different namespace accepted")
	}
}

// TestSSHVerifierTimeout proves review finding [MEDIUM]: when the ssh-keygen
// exec exceeds its timeout, Verify returns the generic auth failure (fail
// closed on the timeout path) — never a spurious accept. A 1ns timeout forces
// the exec context to expire.
func TestSSHVerifierTimeout(t *testing.T) {
	requireSSHKeygen(t)
	f := newSSHTestFixture(t)

	challenge, _, _, err := f.srv.challenge.Mint(fixedNow)
	if err != nil {
		t.Fatalf("Mint: %v", err)
	}
	sig := signChallenge(t, f.authKeyPath, challenge)

	v := newSSHSigVerifier(f.authorizedKey, "milosvasic", time.Nanosecond)
	if err := v.Verify([]byte(challenge), sig); err == nil {
		t.Error("expected timeout-path rejection, got accept")
	}
}

// TestSSHLoginEndToEnd drives the full POST /login handler with real signatures.
func TestSSHLoginEndToEnd(t *testing.T) {
	requireSSHKeygen(t)
	f := newSSHTestFixture(t)

	// --- valid → 303 + session cookie ---
	challenge, token, _, err := f.srv.challenge.Mint(fixedNow)
	if err != nil {
		t.Fatalf("Mint: %v", err)
	}
	sig := signChallenge(t, f.authKeyPath, challenge)
	rec := f.postSigned(token, sig, "127.0.0.1:5001")
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("valid login status = %d, want 303 (body: %s)", rec.Code, rec.Body.String())
	}
	cookie := sessionCookieFrom(rec)
	if cookie == nil {
		t.Fatal("valid login issued no session cookie")
	}
	if user, verr := f.srv.codec.Verify(cookie.Value, fixedNow); verr != nil || user != "milosvasic" {
		t.Errorf("session cookie invalid: user=%q err=%v", user, verr)
	}

	// --- replay same token+sig → 401 ---
	rec = f.postSigned(token, sig, "127.0.0.1:5001")
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("replay status = %d, want 401", rec.Code)
	}

	// --- tampered signature (fresh challenge) → 401 ---
	c2, tok2, _, _ := f.srv.challenge.Mint(fixedNow)
	sig2 := signChallenge(t, f.authKeyPath, c2)
	rec = f.postSigned(tok2, tamperSignature(t, sig2), "127.0.0.1:5002")
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("tampered status = %d, want 401", rec.Code)
	}

	// --- non-authorized key (fresh challenge) → 401 ---
	c3, tok3, _, _ := f.srv.challenge.Mint(fixedNow)
	sig3 := signChallenge(t, f.otherKeyPath, c3)
	rec = f.postSigned(tok3, sig3, "127.0.0.1:5003")
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("non-authorized key status = %d, want 401", rec.Code)
	}

	// --- expired challenge (minted 5m in the past, TTL 2m) → 401 ---
	c4, tok4, _, _ := f.srv.challenge.Mint(fixedNow.Add(-5 * time.Minute))
	sig4 := signChallenge(t, f.authKeyPath, c4)
	rec = f.postSigned(tok4, sig4, "127.0.0.1:5004")
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("expired challenge status = %d, want 401", rec.Code)
	}
}
