package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// secretLen is the length in bytes of a freshly generated HMAC secret.
const secretLen = 32

// sessionIDLen is the length in bytes of the random per-login session id
// embedded in each cookie. It makes every issued session token unique even for
// the same user + issue time, which is the anti-session-fixation guarantee:
// each successful login regenerates the session identifier, so a value an
// attacker could have pre-set (and which would fail the HMAC check anyway) can
// never become the post-login session (§A5-1).
const sessionIDLen = 16

// Sentinel errors returned by cookie verification. Callers map all of them to
// a single generic "not authenticated" response (no user enumeration).
var (
	errCookieMalformed = errors.New("cookie malformed")
	errCookieBadSig    = errors.New("cookie signature mismatch")
	errCookieExpired   = errors.New("cookie expired")
	errCookieEmptyUser = errors.New("cookie has empty user")
)

// CookieCodec signs and verifies session tokens with HMAC-SHA256. The token
// wire form is:
//
//	base64url(payload) "." base64url(hmac(payload))
//
// where payload is the literal bytes:
//
//	base64url(user) "|" base64url(sessionID) "|" expiryUnix
//
// The user is base64url-encoded so it can contain any byte (including '|')
// without ambiguity; sessionID is a fresh random value per Sign (anti-fixation,
// §A5-1). Verification uses a constant-time MAC compare (hmac.Equal) and rejects
// tampered or expired tokens.
type CookieCodec struct {
	secret []byte
	ttl    time.Duration
}

// NewCookieCodec returns a codec using secret for signing and ttl for the
// lifetime applied by Sign.
func NewCookieCodec(secret []byte, ttl time.Duration) *CookieCodec {
	return &CookieCodec{secret: secret, ttl: ttl}
}

// mac computes HMAC-SHA256(secret, payload).
func (c *CookieCodec) mac(payload []byte) []byte {
	m := hmac.New(sha256.New, c.secret)
	m.Write(payload)
	return m.Sum(nil)
}

// Sign issues a fresh token for user that expires at now+ttl. Every call embeds
// a NEW random session id, so two logins never yield the same token — the
// session identifier is regenerated on each successful login (anti-fixation,
// §A5-1). It returns the token, the absolute expiry (for the cookie
// Expires/Max-Age), and an error only if the CSPRNG fails (fail closed — no
// session is issued).
func (c *CookieCodec) Sign(user string, now time.Time) (token string, expiry time.Time, err error) {
	sid := make([]byte, sessionIDLen)
	if _, rErr := rand.Read(sid); rErr != nil {
		return "", time.Time{}, fmt.Errorf("generate session id: %w", rErr)
	}
	expiry = now.Add(c.ttl)
	payload := base64.RawURLEncoding.EncodeToString([]byte(user)) + "|" +
		base64.RawURLEncoding.EncodeToString(sid) + "|" +
		strconv.FormatInt(expiry.Unix(), 10)
	sig := c.mac([]byte(payload))
	token = base64.RawURLEncoding.EncodeToString([]byte(payload)) + "." +
		base64.RawURLEncoding.EncodeToString(sig)
	return token, expiry, nil
}

// Verify validates token and returns the embedded user. It returns an error
// if the token is malformed, the signature does not match (constant-time),
// the user is empty, or the token has expired relative to now.
func (c *CookieCodec) Verify(token string, now time.Time) (string, error) {
	dot := strings.IndexByte(token, '.')
	if dot <= 0 || dot == len(token)-1 {
		return "", errCookieMalformed
	}
	payload, err := base64.RawURLEncoding.DecodeString(token[:dot])
	if err != nil {
		return "", errCookieMalformed
	}
	sig, err := base64.RawURLEncoding.DecodeString(token[dot+1:])
	if err != nil {
		return "", errCookieMalformed
	}

	// Constant-time signature check FIRST — never trust unverified payload.
	expected := c.mac(payload)
	if !hmac.Equal(sig, expected) {
		return "", errCookieBadSig
	}

	// Payload is trusted now: base64url(user) "|" base64url(sid) "|" expiryUnix.
	parts := strings.Split(string(payload), "|")
	if len(parts) != 3 {
		return "", errCookieMalformed
	}
	userBytes, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return "", errCookieMalformed
	}
	user := string(userBytes)
	if user == "" {
		return "", errCookieEmptyUser
	}
	// parts[1] is the opaque session id — its integrity is already covered by
	// the MAC over the whole payload; we do not need to decode it to trust it.
	expUnix, err := strconv.ParseInt(parts[2], 10, 64)
	if err != nil {
		return "", errCookieMalformed
	}
	if !now.Before(time.Unix(expUnix, 0)) {
		return "", errCookieExpired
	}
	return user, nil
}

// loadOrCreateSecret reads the HMAC secret from path. If the file is absent it
// generates secretLen cryptographically-random bytes, writes them with 0600
// permissions (creating the parent directory 0700 if needed), and returns
// them. An existing file that is empty or unreadable is an error rather than a
// silent regeneration (§11.4.6) — regenerating would silently invalidate all
// live sessions.
func loadOrCreateSecret(path string) ([]byte, error) {
	b, err := os.ReadFile(path)
	if err == nil {
		if len(b) == 0 {
			return nil, fmt.Errorf("cookie secret %q is empty", path)
		}
		// An existing-but-undersized secret is a misconfiguration (truncated
		// file, wrong file, hand-edited): an HMAC key below secretLen bytes
		// weakens every session + challenge token. Reject it rather than
		// silently accepting a weak key (§11.4.6 — fail closed, no guessing).
		if len(b) < secretLen {
			return nil, fmt.Errorf("cookie secret %q is too short: %d bytes, need >= %d", path, len(b), secretLen)
		}
		return b, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("read cookie secret %q: %w", path, err)
	}

	// Absent: generate and persist atomically-ish with tight perms.
	if dir := filepath.Dir(path); dir != "" && dir != "." {
		if mkErr := os.MkdirAll(dir, 0o700); mkErr != nil {
			return nil, fmt.Errorf("create secret dir %q: %w", dir, mkErr)
		}
	}
	secret := make([]byte, secretLen)
	if _, rErr := rand.Read(secret); rErr != nil {
		return nil, fmt.Errorf("generate cookie secret: %w", rErr)
	}
	if wErr := os.WriteFile(path, secret, 0o600); wErr != nil {
		return nil, fmt.Errorf("write cookie secret %q: %w", path, wErr)
	}
	return secret, nil
}
