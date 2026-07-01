package main

import (
	"errors"
	"sync"
	"time"
)

// Fail-closed sentinels: when the limiter cannot make a positive
// allow-decision it returns an error and callers MUST deny (§3.1 "fail
// closed"). These are distinct from a plain over-limit denial (allowed=false,
// err=nil), which is an ordinary rate-limit response.
var (
	errLimiterUnavailable = errors.New("rate limiter unavailable")
	errNoClientIP         = errors.New("cannot determine client ip")
)

// windowCounter tracks failed attempts within one fixed window.
type windowCounter struct {
	windowStart time.Time
	failures    int
}

// RateLimiter is a per-client-IP fixed-window failure counter for POST /login.
// A client is allowed to attempt a login while it has fewer than max recorded
// failures in the current window; once it reaches max it is blocked until the
// window rolls over. Successful logins clear the client's counter.
//
// It is safe for concurrent use.
type RateLimiter struct {
	mu     sync.Mutex
	max    int
	window time.Duration
	hits   map[string]*windowCounter
}

// NewRateLimiter builds a limiter permitting up to max failures per window.
func NewRateLimiter(max int, window time.Duration) *RateLimiter {
	return &RateLimiter{
		max:    max,
		window: window,
		hits:   make(map[string]*windowCounter),
	}
}

// Allow reports whether ip may attempt a login now. It returns (false, err)
// — the fail-closed path — when the limiter itself is unusable (nil receiver /
// uninitialised map) or when the client IP is unknown; callers deny on any
// error. It returns (false, nil) for an ordinary over-limit denial and
// (true, nil) when the attempt is permitted.
func (r *RateLimiter) Allow(ip string, now time.Time) (bool, error) {
	if r == nil || r.hits == nil {
		return false, errLimiterUnavailable
	}
	if ip == "" {
		return false, errNoClientIP
	}

	r.mu.Lock()
	defer r.mu.Unlock()

	c, ok := r.hits[ip]
	if !ok || now.Sub(c.windowStart) >= r.window {
		// No live window for this client → fresh budget available.
		return true, nil
	}
	if c.failures >= r.max {
		return false, nil
	}
	return true, nil
}

// RecordFailure increments the failure counter for ip, starting a new window
// if none is live. No-op on a nil/uninitialised limiter. It opportunistically
// purges entries whose window has fully rolled over so the map cannot grow
// without bound (mirrors ReplayGuard.Claim's sweep).
func (r *RateLimiter) RecordFailure(ip string, now time.Time) {
	if r == nil || r.hits == nil || ip == "" {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()

	// Opportunistic purge: any client whose window fully expired holds no live
	// budget, so its entry is dead weight — drop it (bounds memory).
	for k, wc := range r.hits {
		if now.Sub(wc.windowStart) >= r.window {
			delete(r.hits, k)
		}
	}

	c, ok := r.hits[ip]
	if !ok || now.Sub(c.windowStart) >= r.window {
		c = &windowCounter{windowStart: now}
		r.hits[ip] = c
	}
	c.failures++
}

// size returns the number of tracked client entries. It is used by tests to
// assert the opportunistic purge bounds the map; production code never needs it.
func (r *RateLimiter) size() int {
	if r == nil || r.hits == nil {
		return 0
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.hits)
}

// RecordSuccess clears any failure state for ip after a successful login so a
// legitimate user is never throttled by their own earlier typos.
func (r *RateLimiter) RecordSuccess(ip string) {
	if r == nil || r.hits == nil || ip == "" {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.hits, ip)
}
