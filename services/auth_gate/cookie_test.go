package main

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func testSecret() []byte {
	// Deterministic 32-byte secret for round-trip tests.
	s := make([]byte, secretLen)
	for i := range s {
		s[i] = byte(i * 7)
	}
	return s
}

func TestCookieRoundTrip(t *testing.T) {
	codec := NewCookieCodec(testSecret(), time.Hour)
	now := time.Unix(1_700_000_000, 0)

	token, expiry, err := codec.Sign("milosvasic", now)
	if err != nil {
		t.Fatalf("Sign error: %v", err)
	}
	if expiry != now.Add(time.Hour) {
		t.Fatalf("expiry = %v, want %v", expiry, now.Add(time.Hour))
	}

	user, err := codec.Verify(token, now)
	if err != nil {
		t.Fatalf("Verify returned error: %v", err)
	}
	if user != "milosvasic" {
		t.Fatalf("Verify user = %q, want milosvasic", user)
	}
}

func TestCookieUserWithPipe(t *testing.T) {
	// The user is base64url-encoded in the payload, so an embedded '|'
	// round-trips without confusing the field split.
	codec := NewCookieCodec(testSecret(), time.Hour)
	now := time.Unix(1_700_000_000, 0)
	token, _, err := codec.Sign("weird|name", now)
	if err != nil {
		t.Fatalf("Sign error: %v", err)
	}
	user, err := codec.Verify(token, now)
	if err != nil {
		t.Fatalf("Verify error: %v", err)
	}
	if user != "weird|name" {
		t.Fatalf("user = %q, want weird|name", user)
	}
}

// TestCookieSignRegenerates proves each Sign yields a distinct token (a fresh
// session id) even for the same user + time — the anti-fixation guarantee.
func TestCookieSignRegenerates(t *testing.T) {
	codec := NewCookieCodec(testSecret(), time.Hour)
	now := time.Unix(1_700_000_000, 0)
	t1, _, err1 := codec.Sign("milosvasic", now)
	t2, _, err2 := codec.Sign("milosvasic", now)
	if err1 != nil || err2 != nil {
		t.Fatalf("Sign errors: %v %v", err1, err2)
	}
	if t1 == t2 {
		t.Error("two Signs for the same user+time produced identical tokens (no fresh session id)")
	}
	// Both still verify to the same user.
	for _, tok := range []string{t1, t2} {
		if u, err := codec.Verify(tok, now); err != nil || u != "milosvasic" {
			t.Errorf("token did not verify: user=%q err=%v", u, err)
		}
	}
}

func TestCookieTamperRejected(t *testing.T) {
	codec := NewCookieCodec(testSecret(), time.Hour)
	now := time.Unix(1_700_000_000, 0)
	token, _, err := codec.Sign("milosvasic", now)
	if err != nil {
		t.Fatalf("Sign error: %v", err)
	}

	dot := strings.IndexByte(token, '.')
	payloadB64, sigB64 := token[:dot], token[dot+1:]

	// 1. Forge a payload claiming a different user but reuse the old signature.
	forgedPayload := base64.RawURLEncoding.EncodeToString([]byte("root")) + "|" +
		base64.RawURLEncoding.EncodeToString([]byte("sid")) + "|" +
		strconv.FormatInt(now.Add(time.Hour).Unix(), 10)
	forgedToken := base64.RawURLEncoding.EncodeToString([]byte(forgedPayload)) + "." + sigB64
	if _, err := codec.Verify(forgedToken, now); err == nil {
		t.Error("forged payload with stale signature accepted")
	}

	// 2. Corrupt the signature (guaranteed-significant char).
	badSig := corruptB64Char(sigB64)
	if _, err := codec.Verify(payloadB64+"."+badSig, now); err == nil {
		t.Error("tampered signature accepted")
	}

	// 3. Different secret must not validate a token signed by testSecret.
	other := NewCookieCodec([]byte("another-completely-different-secret!!"), time.Hour)
	if _, err := other.Verify(token, now); err == nil {
		t.Error("token validated under a different secret")
	}
}

func TestCookieExpiryRejected(t *testing.T) {
	codec := NewCookieCodec(testSecret(), time.Hour)
	issued := time.Unix(1_700_000_000, 0)
	token, _, err := codec.Sign("milosvasic", issued)
	if err != nil {
		t.Fatalf("Sign error: %v", err)
	}

	// Just before expiry: valid.
	if _, err := codec.Verify(token, issued.Add(time.Hour-time.Second)); err != nil {
		t.Errorf("token rejected before expiry: %v", err)
	}
	// Exactly at expiry: rejected (expiry is exclusive).
	if _, err := codec.Verify(token, issued.Add(time.Hour)); err == nil {
		t.Error("token accepted exactly at expiry")
	}
	// After expiry: rejected.
	if _, err := codec.Verify(token, issued.Add(2*time.Hour)); err == nil {
		t.Error("expired token accepted")
	}
}

func TestCookieMalformed(t *testing.T) {
	codec := NewCookieCodec(testSecret(), time.Hour)
	now := time.Unix(1_700_000_000, 0)
	bad := []string{
		"",
		"nodot",
		".",
		"onlypayload.",
		".onlysig",
		"@@@.@@@",  // invalid base64
		"YWJj.@@@", // valid payload b64, invalid sig b64
	}
	for _, b := range bad {
		if _, err := codec.Verify(b, now); err == nil {
			t.Errorf("malformed token %q accepted", b)
		}
	}
}

func TestLoadOrCreateSecretGenerates(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "nested", "cookie_secret")

	secret, err := loadOrCreateSecret(path)
	if err != nil {
		t.Fatalf("generate error: %v", err)
	}
	if len(secret) != secretLen {
		t.Fatalf("generated secret length = %d, want %d", len(secret), secretLen)
	}

	// File must exist with 0600 perms.
	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Errorf("secret file perm = %o, want 600", perm)
	}
	// Parent dir must be 0700.
	dinfo, err := os.Stat(filepath.Dir(path))
	if err != nil {
		t.Fatalf("stat dir: %v", err)
	}
	if perm := dinfo.Mode().Perm(); perm != 0o700 {
		t.Errorf("secret dir perm = %o, want 700", perm)
	}
}

func TestLoadOrCreateSecretLoadsExisting(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "cookie_secret")

	first, err := loadOrCreateSecret(path)
	if err != nil {
		t.Fatalf("first call error: %v", err)
	}
	second, err := loadOrCreateSecret(path)
	if err != nil {
		t.Fatalf("second call error: %v", err)
	}
	if string(first) != string(second) {
		t.Error("second load returned a different secret — must be stable")
	}
}

func TestLoadOrCreateSecretEmptyFileIsError(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "cookie_secret")
	if err := os.WriteFile(path, []byte{}, 0o600); err != nil {
		t.Fatalf("setup: %v", err)
	}
	if _, err := loadOrCreateSecret(path); err == nil {
		t.Error("empty secret file must be an error, not a silent regeneration")
	}
}

// TestLoadOrCreateSecretShortIsError proves the [NIT] fix: an existing secret
// file shorter than secretLen bytes is rejected (a weak HMAC key), not
// silently accepted.
func TestLoadOrCreateSecretShortIsError(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "cookie_secret")
	// secretLen-1 bytes → under strength → must error.
	if err := os.WriteFile(path, make([]byte, secretLen-1), 0o600); err != nil {
		t.Fatalf("setup: %v", err)
	}
	if _, err := loadOrCreateSecret(path); err == nil {
		t.Errorf("undersized (%d-byte) secret must be an error, not a weak-key accept", secretLen-1)
	}
	// A full-length existing secret is still accepted.
	full := filepath.Join(dir, "full_secret")
	if err := os.WriteFile(full, make([]byte, secretLen), 0o600); err != nil {
		t.Fatalf("setup full: %v", err)
	}
	if _, err := loadOrCreateSecret(full); err != nil {
		t.Errorf("full-length secret rejected: %v", err)
	}
}

// --- small local helpers (kept test-local) ---

// corruptB64Char flips the FIRST character of a base64url segment to a
// definitely-different valid char. The first char always maps to significant
// bits (unlike the trailing char of a no-padding blob, whose low bits are
// slack), so the decoded bytes are guaranteed to change — a robust tamper.
func corruptB64Char(s string) string {
	if s == "" {
		return "A"
	}
	b := []byte(s)
	if b[0] == 'A' {
		b[0] = 'B'
	} else {
		b[0] = 'A'
	}
	return string(b)
}
