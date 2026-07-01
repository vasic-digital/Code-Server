package main

import (
	"encoding/base64"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestChallengeMintVerifyRoundTrip(t *testing.T) {
	codec := NewChallengeCodec(testSecret(), 2*time.Minute)
	now := time.Unix(1_700_000_000, 0)

	challenge, token, expiry, err := codec.Mint(now)
	if err != nil {
		t.Fatalf("Mint error: %v", err)
	}
	if expiry != now.Add(2*time.Minute) {
		t.Fatalf("expiry = %v, want %v", expiry, now.Add(2*time.Minute))
	}
	// The token embeds the challenge as its first '|'-delimited field.
	if parts := strings.Split(token, "|"); len(parts) != 3 || parts[0] != challenge {
		t.Fatalf("token %q does not carry challenge %q as field 0", token, challenge)
	}
	// The challenge is base64url of a 32-byte nonce.
	if raw, derr := base64.RawURLEncoding.DecodeString(challenge); derr != nil || len(raw) != nonceLen {
		t.Fatalf("challenge decode: err=%v len=%d want nonceLen=%d", derr, len(raw), nonceLen)
	}

	gotChallenge, gotExpiry, verr := codec.Verify(token, now)
	if verr != nil {
		t.Fatalf("Verify error: %v", verr)
	}
	if gotChallenge != challenge {
		t.Errorf("verified challenge = %q, want %q", gotChallenge, challenge)
	}
	if !gotExpiry.Equal(expiry) {
		t.Errorf("verified expiry = %v, want %v", gotExpiry, expiry)
	}
}

func TestChallengeUnique(t *testing.T) {
	codec := NewChallengeCodec(testSecret(), time.Minute)
	now := time.Unix(1_700_000_000, 0)
	seen := map[string]bool{}
	for i := 0; i < 100; i++ {
		c, _, _, err := codec.Mint(now)
		if err != nil {
			t.Fatalf("Mint %d: %v", i, err)
		}
		if seen[c] {
			t.Fatalf("duplicate challenge nonce at iter %d: %q", i, c)
		}
		seen[c] = true
	}
}

func TestChallengeTamperRejected(t *testing.T) {
	codec := NewChallengeCodec(testSecret(), time.Minute)
	now := time.Unix(1_700_000_000, 0)
	challenge, token, expiry, _ := codec.Mint(now)
	parts := strings.Split(token, "|")

	// 1. Extend the expiry but keep the old MAC → rejected.
	forged := parts[0] + "|" + strconv.FormatInt(expiry.Add(time.Hour).Unix(), 10) + "|" + parts[2]
	if _, _, err := codec.Verify(forged, now); err == nil {
		t.Error("forged (extended-expiry) token accepted")
	}

	// 2. Swap in a different nonce but keep the old MAC → rejected.
	other, _, _, _ := codec.Mint(now)
	swapped := other + "|" + parts[1] + "|" + parts[2]
	if _, _, err := codec.Verify(swapped, now); err == nil {
		t.Error("swapped-nonce token accepted")
	}
	_ = challenge

	// 3. A different secret must not validate a token minted by testSecret.
	otherCodec := NewChallengeCodec([]byte("a-totally-different-server-secret!!!"), time.Minute)
	if _, _, err := otherCodec.Verify(token, now); err == nil {
		t.Error("token validated under a different secret")
	}
}

func TestChallengeExpiryRejected(t *testing.T) {
	codec := NewChallengeCodec(testSecret(), time.Minute)
	issued := time.Unix(1_700_000_000, 0)
	_, token, _, _ := codec.Mint(issued)

	if _, _, err := codec.Verify(token, issued.Add(time.Minute-time.Second)); err != nil {
		t.Errorf("token rejected before expiry: %v", err)
	}
	if _, _, err := codec.Verify(token, issued.Add(time.Minute)); err == nil {
		t.Error("token accepted exactly at expiry")
	}
	if _, _, err := codec.Verify(token, issued.Add(2*time.Minute)); err == nil {
		t.Error("expired token accepted")
	}
}

func TestChallengeMalformed(t *testing.T) {
	codec := NewChallengeCodec(testSecret(), time.Minute)
	now := time.Unix(1_700_000_000, 0)
	bad := []string{
		"",
		"onefield",
		"a|b",              // too few fields
		"a|b|c|d",          // too many fields
		"|123|sig",         // empty challenge
		"chal|notanum|sig", // non-numeric expiry
		"chal|123|@@@",     // invalid base64 sig
		"@@@|123|c2ln",     // invalid base64 challenge
	}
	for _, b := range bad {
		if _, _, err := codec.Verify(b, now); err == nil {
			t.Errorf("malformed token %q accepted", b)
		}
	}
}

func TestReplayGuardSingleUse(t *testing.T) {
	g := NewReplayGuard()
	now := time.Unix(1_700_000_000, 0)
	expiry := now.Add(time.Minute)

	claimed, err := g.Claim("chal-A", expiry, now)
	if err != nil || !claimed {
		t.Fatalf("first claim: claimed=%v err=%v, want true,nil", claimed, err)
	}
	// Second claim of the same challenge → replay → not claimed.
	claimed, err = g.Claim("chal-A", expiry, now)
	if err != nil || claimed {
		t.Fatalf("replay claim: claimed=%v err=%v, want false,nil", claimed, err)
	}
	// A different challenge is independent.
	claimed, err = g.Claim("chal-B", expiry, now)
	if err != nil || !claimed {
		t.Fatalf("independent claim: claimed=%v err=%v, want true,nil", claimed, err)
	}
}

func TestReplayGuardPurgesExpired(t *testing.T) {
	g := NewReplayGuard()
	now := time.Unix(1_700_000_000, 0)
	expiry := now.Add(time.Minute)

	if claimed, _ := g.Claim("chal-C", expiry, now); !claimed {
		t.Fatal("first claim should succeed")
	}
	// After the entry's expiry, a later Claim purges it — but a re-claim of the
	// SAME expired challenge is a fresh window (the token itself is already
	// unusable via the codec's expiry check, so this only bounds memory).
	later := now.Add(2 * time.Minute)
	if claimed, _ := g.Claim("chal-C", later.Add(time.Minute), later); !claimed {
		t.Error("claim after purge should succeed (entry was expired + removed)")
	}
}

// TestReplayGuardConcurrentClaimExactlyOnce proves review finding [MEDIUM]:
// when many goroutines race to claim the SAME nonce, exactly one wins (the
// single-use guarantee holds under concurrency). Race-detector target.
func TestReplayGuardConcurrentClaimExactlyOnce(t *testing.T) {
	g := NewReplayGuard()
	now := time.Unix(1_700_000_000, 0)
	expiry := now.Add(time.Minute)

	const N = 128
	var wins int64
	var wg sync.WaitGroup
	start := make(chan struct{})
	for i := 0; i < N; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start // release all goroutines together to maximise contention
			if claimed, err := g.Claim("same-nonce", expiry, now); err == nil && claimed {
				atomic.AddInt64(&wins, 1)
			}
		}()
	}
	close(start)
	wg.Wait()

	if wins != 1 {
		t.Fatalf("concurrent claims of one nonce won %d times, want exactly 1", wins)
	}
}

func TestReplayGuardFailClosed(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)

	var nilGuard *ReplayGuard
	if claimed, err := nilGuard.Claim("x", now.Add(time.Minute), now); claimed || err == nil {
		t.Errorf("nil guard: claimed=%v err=%v, want false + error (fail closed)", claimed, err)
	}

	zeroGuard := &ReplayGuard{} // used map is nil
	if claimed, err := zeroGuard.Claim("x", now.Add(time.Minute), now); claimed || err == nil {
		t.Errorf("uninitialised guard: claimed=%v err=%v, want false + error (fail closed)", claimed, err)
	}

	g := NewReplayGuard()
	if claimed, err := g.Claim("", now.Add(time.Minute), now); claimed || err == nil {
		t.Errorf("empty challenge: claimed=%v err=%v, want false + error (fail closed)", claimed, err)
	}
}
