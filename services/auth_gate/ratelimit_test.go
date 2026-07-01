package main

import (
	"errors"
	"strconv"
	"sync"
	"testing"
	"time"
)

func TestRateLimiterAllowsUnderLimit(t *testing.T) {
	rl := NewRateLimiter(3, time.Minute)
	now := time.Unix(1_700_000_000, 0)
	ip := "10.0.0.1"

	// 3 failures allowed; the 4th attempt is blocked.
	for i := 0; i < 3; i++ {
		allowed, err := rl.Allow(ip, now)
		if err != nil {
			t.Fatalf("attempt %d error: %v", i, err)
		}
		if !allowed {
			t.Fatalf("attempt %d blocked under limit", i)
		}
		rl.RecordFailure(ip, now)
	}
	allowed, err := rl.Allow(ip, now)
	if err != nil {
		t.Fatalf("over-limit attempt error: %v", err)
	}
	if allowed {
		t.Fatal("attempt over limit was allowed")
	}
}

func TestRateLimiterWindowRollover(t *testing.T) {
	rl := NewRateLimiter(2, time.Minute)
	start := time.Unix(1_700_000_000, 0)
	ip := "10.0.0.2"

	rl.RecordFailure(ip, start)
	rl.RecordFailure(ip, start)
	if allowed, _ := rl.Allow(ip, start); allowed {
		t.Fatal("blocked client allowed within window")
	}

	// A full window later, the budget resets.
	later := start.Add(time.Minute)
	if allowed, err := rl.Allow(ip, later); err != nil || !allowed {
		t.Fatalf("client not reset after window rollover (allowed=%v err=%v)", allowed, err)
	}
}

func TestRateLimiterSuccessClears(t *testing.T) {
	rl := NewRateLimiter(2, time.Minute)
	now := time.Unix(1_700_000_000, 0)
	ip := "10.0.0.3"

	rl.RecordFailure(ip, now)
	rl.RecordFailure(ip, now)
	if allowed, _ := rl.Allow(ip, now); allowed {
		t.Fatal("expected blocked before success")
	}
	rl.RecordSuccess(ip)
	if allowed, err := rl.Allow(ip, now); err != nil || !allowed {
		t.Fatalf("success did not clear throttle (allowed=%v err=%v)", allowed, err)
	}
}

func TestRateLimiterPerIPIsolation(t *testing.T) {
	rl := NewRateLimiter(1, time.Minute)
	now := time.Unix(1_700_000_000, 0)

	rl.RecordFailure("10.0.0.4", now)
	if allowed, _ := rl.Allow("10.0.0.4", now); allowed {
		t.Fatal("blocked ip allowed")
	}
	// A different IP is unaffected.
	if allowed, err := rl.Allow("10.0.0.5", now); err != nil || !allowed {
		t.Fatalf("second ip wrongly throttled (allowed=%v err=%v)", allowed, err)
	}
}

func TestRateLimiterFailClosed(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)

	// Empty client IP → deny with errNoClientIP (fail closed).
	rl := NewRateLimiter(5, time.Minute)
	allowed, err := rl.Allow("", now)
	if allowed || !errors.Is(err, errNoClientIP) {
		t.Errorf("empty ip: allowed=%v err=%v, want allowed=false err=errNoClientIP", allowed, err)
	}

	// Nil receiver → deny with errLimiterUnavailable (fail closed).
	var nilRL *RateLimiter
	allowed, err = nilRL.Allow("10.0.0.6", now)
	if allowed || !errors.Is(err, errLimiterUnavailable) {
		t.Errorf("nil limiter: allowed=%v err=%v, want allowed=false err=errLimiterUnavailable", allowed, err)
	}

	// Uninitialised map → deny with errLimiterUnavailable (fail closed).
	zeroRL := &RateLimiter{max: 5, window: time.Minute}
	allowed, err = zeroRL.Allow("10.0.0.7", now)
	if allowed || !errors.Is(err, errLimiterUnavailable) {
		t.Errorf("zero limiter: allowed=%v err=%v, want allowed=false err=errLimiterUnavailable", allowed, err)
	}
}

// TestRateLimiterPurgesStaleEntries proves review finding [MAJOR](d): entries
// whose window has fully rolled over are swept opportunistically on
// RecordFailure so the map cannot grow without bound.
func TestRateLimiterPurgesStaleEntries(t *testing.T) {
	rl := NewRateLimiter(5, time.Minute)
	start := time.Unix(1_700_000_000, 0)

	for i := 0; i < 10; i++ {
		rl.RecordFailure("10.2.0."+strconv.Itoa(i), start)
	}
	if got := rl.size(); got != 10 {
		t.Fatalf("size after 10 distinct clients = %d, want 10", got)
	}

	// A failure a full window later: every prior entry is stale and swept, so
	// only the new client's entry remains.
	later := start.Add(2 * time.Minute)
	rl.RecordFailure("10.2.9.99", later)
	if got := rl.size(); got != 1 {
		t.Fatalf("size after purge = %d, want 1 (stale entries must be swept)", got)
	}
}

func TestRateLimiterConcurrent(t *testing.T) {
	// Race-detector target: many goroutines hammering one limiter must not
	// deadlock or corrupt state.
	rl := NewRateLimiter(1000, time.Minute)
	now := time.Unix(1_700_000_000, 0)
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func(n int) {
			defer wg.Done()
			ip := "10.1.0." + string(rune('0'+n%10))
			for j := 0; j < 100; j++ {
				_, _ = rl.Allow(ip, now)
				rl.RecordFailure(ip, now)
			}
		}(i)
	}
	wg.Wait()
}
