package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"
)

// nonceLen is the number of random bytes in a login challenge.
const nonceLen = 32

// challengeDomain domain-separates the challenge HMAC from the cookie HMAC so
// the two token families (which share the same secret) can never be confused
// for one another.
const challengeDomain = "helixcode-challenge-v1"

// Sentinel errors from challenge verification. Callers map them to a single
// generic failure response (no oracle for an attacker probing token shapes).
var (
	errChallengeMalformed = errors.New("challenge token malformed")
	errChallengeBadSig    = errors.New("challenge token signature mismatch")
	errChallengeExpired   = errors.New("challenge token expired")
)

// ChallengeCodec mints and verifies login challenges. A challenge is a random
// nonce the user signs with their SSH key; the codec binds the nonce to a
// short expiry with an HMAC so the server can later confirm it issued the
// challenge and it has not expired, WITHOUT storing per-challenge state.
//
// Token wire form (three '|'-separated fields; base64url never contains '|'):
//
//	base64url(nonce) "|" expiryUnix "|" base64url(HMAC(domain | challenge | expiry))
//
// The first field, base64url(nonce), is BOTH the value shown to the user to
// sign AND the value carried in the token. It is called the "challenge".
type ChallengeCodec struct {
	secret []byte
	ttl    time.Duration
}

// NewChallengeCodec returns a codec signing with secret and issuing challenges
// that live for ttl.
func NewChallengeCodec(secret []byte, ttl time.Duration) *ChallengeCodec {
	return &ChallengeCodec{secret: secret, ttl: ttl}
}

// mac computes HMAC-SHA256 over the domain-separated (challenge|expiry) prefix.
func (c *ChallengeCodec) mac(challenge string, expiryUnix int64) []byte {
	m := hmac.New(sha256.New, c.secret)
	m.Write([]byte(challengeDomain))
	m.Write([]byte{0})
	m.Write([]byte(challenge))
	m.Write([]byte{'|'})
	m.Write([]byte(strconv.FormatInt(expiryUnix, 10)))
	return m.Sum(nil)
}

// Mint issues a fresh challenge. It returns the challenge string (base64url of
// a random nonce — the exact bytes the user signs) and the full token (the
// hidden form field carried back on POST) plus the absolute expiry.
func (c *ChallengeCodec) Mint(now time.Time) (challenge, token string, expiry time.Time, err error) {
	nonce := make([]byte, nonceLen)
	if _, rErr := rand.Read(nonce); rErr != nil {
		return "", "", time.Time{}, fmt.Errorf("generate challenge nonce: %w", rErr)
	}
	challenge = base64.RawURLEncoding.EncodeToString(nonce)
	expiry = now.Add(c.ttl)
	sig := c.mac(challenge, expiry.Unix())
	token = challenge + "|" +
		strconv.FormatInt(expiry.Unix(), 10) + "|" +
		base64.RawURLEncoding.EncodeToString(sig)
	return challenge, token, expiry, nil
}

// Verify validates a token and returns the embedded challenge string and its
// expiry. It rejects a malformed token, a signature mismatch (constant-time),
// or an expired token relative to now. The returned challenge's bytes are the
// signed message the SSH verifier must check.
func (c *ChallengeCodec) Verify(token string, now time.Time) (challenge string, expiry time.Time, err error) {
	parts := strings.Split(token, "|")
	if len(parts) != 3 {
		return "", time.Time{}, errChallengeMalformed
	}
	challenge = parts[0]
	if challenge == "" {
		return "", time.Time{}, errChallengeMalformed
	}
	if _, dErr := base64.RawURLEncoding.DecodeString(challenge); dErr != nil {
		return "", time.Time{}, errChallengeMalformed
	}
	expUnix, pErr := strconv.ParseInt(parts[1], 10, 64)
	if pErr != nil {
		return "", time.Time{}, errChallengeMalformed
	}
	sig, dErr := base64.RawURLEncoding.DecodeString(parts[2])
	if dErr != nil {
		return "", time.Time{}, errChallengeMalformed
	}

	// Constant-time MAC check FIRST — never trust an unverified expiry/nonce.
	expected := c.mac(challenge, expUnix)
	if !hmac.Equal(sig, expected) {
		return "", time.Time{}, errChallengeBadSig
	}

	expiry = time.Unix(expUnix, 0)
	if !now.Before(expiry) {
		return "", time.Time{}, errChallengeExpired
	}
	return challenge, expiry, nil
}

// errReplayGuardUnavailable is the fail-closed sentinel returned when the
// replay guard cannot make a positive single-use decision (nil / uninitialised
// receiver). Callers MUST deny on it.
var errReplayGuardUnavailable = errors.New("replay guard unavailable")

// ReplayGuard enforces single-use of challenge nonces within their TTL. Once a
// challenge is claimed it cannot be claimed again until it is purged (which
// happens no earlier than its expiry), so a captured (token, signature) pair
// cannot be replayed. Safe for concurrent use.
type ReplayGuard struct {
	mu   sync.Mutex
	used map[string]time.Time // challenge -> expiry (purge-after)
}

// NewReplayGuard returns an empty guard.
func NewReplayGuard() *ReplayGuard {
	return &ReplayGuard{used: make(map[string]time.Time)}
}

// Claim atomically records challenge as used until expiry. It returns
// (true, nil) when this is the first use (the caller may proceed) and
// (false, nil) when the challenge was already claimed (a replay → deny). It
// returns (false, errReplayGuardUnavailable) — the fail-closed path — when the
// guard is nil or uninitialised. Expired entries are purged opportunistically.
func (g *ReplayGuard) Claim(challenge string, expiry, now time.Time) (bool, error) {
	if g == nil || g.used == nil {
		return false, errReplayGuardUnavailable
	}
	if challenge == "" {
		return false, errReplayGuardUnavailable
	}

	g.mu.Lock()
	defer g.mu.Unlock()

	// Opportunistic purge so the map cannot grow without bound.
	for k, exp := range g.used {
		if !now.Before(exp) {
			delete(g.used, k)
		}
	}

	if _, seen := g.used[challenge]; seen {
		return false, nil
	}
	g.used[challenge] = expiry
	return true, nil
}
