package main

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
)

var fixedNow = time.Unix(1_700_000_000, 0)

// TestMain puts gin in TestMode so route registration + debug banners don't
// pollute test output, and the engine behaves deterministically under httptest.
func TestMain(m *testing.M) {
	gin.SetMode(gin.TestMode)
	os.Exit(m.Run())
}

// baseTestConfig is the shared Config for handler tests (fixed small tunables).
func baseTestConfig() Config {
	return Config{
		Mode:            modeSSHKey,
		Account:         "milosvasic",
		Principal:       "milosvasic",
		Bind:            "127.0.0.1:0",
		SessionTTL:      time.Hour,
		ChallengeTTL:    2 * time.Minute,
		RateLimitMax:    3,
		RateLimitWindow: time.Minute,
	}
}

// newTestServer builds a Server with a fixed clock, the supplied verifier, and
// small tunables suitable for tests. cfg fields not set here take test values.
func newTestServer(t *testing.T, v Verifier) *Server {
	t.Helper()
	srv, err := NewServer(baseTestConfig(), testSecret(), v, func() time.Time { return fixedNow })
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}
	return srv
}

// mintChallenge returns a fresh (challenge, token) pair from the server's own
// challenge codec at the fixed clock — the same values GET /login would embed.
func mintChallenge(t *testing.T, srv *Server) (challenge, token string) {
	t.Helper()
	c, tok, _, err := srv.challenge.Mint(srv.now())
	if err != nil {
		t.Fatalf("Mint: %v", err)
	}
	return c, tok
}

// testCSRF is the shared login-CSRF token value used for both the request
// cookie and the form field so the double-submit check passes in handler tests.
const testCSRF = "test-csrf-token-value"

// loginForm builds an application/x-www-form-urlencoded POST /login request for
// the challenge-response flow, carrying a VALID login-CSRF pair (matching
// __Host-helix_csrf cookie + csrf_token field) so it passes the CSRF gate.
func loginForm(token, principal, signature, remoteAddr string) *http.Request {
	form := url.Values{}
	form.Set("challenge_token", token)
	if principal != "" {
		form.Set("principal", principal)
	}
	form.Set("signature", signature)
	form.Set("csrf_token", testCSRF)
	req := httptest.NewRequest(http.MethodPost, "/login", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.RemoteAddr = remoteAddr
	req.AddCookie(&http.Cookie{Name: csrfCookieName, Value: testCSRF})
	return req
}

// sessionCookieFrom extracts the named cookie set on rec, or nil.
func cookieFrom(rec *httptest.ResponseRecorder, name string) *http.Cookie {
	for _, c := range rec.Result().Cookies() {
		if c.Name == name {
			return c
		}
	}
	return nil
}

func sessionCookieFrom(rec *httptest.ResponseRecorder) *http.Cookie {
	return cookieFrom(rec, cookieName)
}

func TestHealthz(t *testing.T) {
	srv := newTestServer(t, acceptAllVerifier{})
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if body := rec.Body.String(); body != "ok" {
		t.Errorf("body = %q, want ok", body)
	}
}

func TestLoginGetRendersChallengePage(t *testing.T) {
	srv := newTestServer(t, acceptAllVerifier{})
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/login", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	body := rec.Body.String()
	if strings.Contains(body, `type="password"`) {
		t.Error("login page still has a password field — pivot incomplete")
	}
	if !strings.Contains(body, `name="signature"`) {
		t.Error("login page missing the signature textarea")
	}
	if !strings.Contains(body, `name="challenge_token"`) {
		t.Error("login page missing the hidden challenge_token field")
	}
	if !strings.Contains(body, `name="csrf_token"`) {
		t.Error("login page missing the hidden csrf_token field")
	}
	if !strings.Contains(body, "ssh-keygen -Y sign -n "+sshSigNamespace) {
		t.Error("login page missing the exact ssh-keygen sign command")
	}
	if !strings.Contains(body, `value="milosvasic"`) {
		t.Error("login page did not prefill the configured principal")
	}
	// The CSRF state cookie is set on GET so the browser can echo it on POST.
	if c := cookieFrom(rec, csrfCookieName); c == nil {
		t.Error("GET /login did not set the __Host-helix_csrf state cookie")
	} else if c.SameSite != http.SameSiteStrictMode || !c.Secure || !c.HttpOnly {
		t.Errorf("CSRF cookie weak attributes: SameSite=%v Secure=%v HttpOnly=%v", c.SameSite, c.Secure, c.HttpOnly)
	}
}

func TestLoginPostSuccess(t *testing.T) {
	v := &mockVerifier{wantSig: "valid-sig"}
	srv := newTestServer(t, v)
	_, token := mintChallenge(t, srv)

	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, loginForm(token, "", "valid-sig", "192.0.2.10:5555"))

	if rec.Code != http.StatusSeeOther {
		t.Fatalf("status = %d, want 303 (body: %s)", rec.Code, rec.Body.String())
	}
	if loc := rec.Header().Get("Location"); loc != "/" {
		t.Errorf("Location = %q, want /", loc)
	}
	c := sessionCookieFrom(rec)
	if c == nil {
		t.Fatal("no session cookie set on success")
	}
	if c.Name != "__Host-helix_session" {
		t.Errorf("session cookie name = %q, want __Host-helix_session", c.Name)
	}
	if !c.HttpOnly {
		t.Error("cookie not HttpOnly")
	}
	if !c.Secure {
		t.Error("cookie not Secure")
	}
	if c.SameSite != http.SameSiteStrictMode {
		t.Errorf("cookie SameSite = %v, want Strict", c.SameSite)
	}
	if c.Path != "/" {
		t.Errorf("cookie Path = %q, want /", c.Path)
	}
	if c.Domain != "" {
		t.Errorf("cookie Domain = %q, want empty (__Host- requirement)", c.Domain)
	}
	if user, err := srv.codec.Verify(c.Value, fixedNow); err != nil || user != "milosvasic" {
		t.Errorf("issued cookie invalid: user=%q err=%v", user, err)
	}
}

// TestLoginRegeneratesSession proves anti-fixation (§A5-1): the post-login
// cookie value differs from any pre-login value, and two logins differ.
func TestLoginRegeneratesSession(t *testing.T) {
	v := &mockVerifier{wantSig: "valid-sig"}
	srv := newTestServer(t, v)

	preLogin := "attacker-preset-value"
	login := func(ip string) string {
		_, token := mintChallenge(t, srv)
		rec := httptest.NewRecorder()
		req := loginForm(token, "", "valid-sig", ip)
		req.AddCookie(&http.Cookie{Name: cookieName, Value: preLogin}) // pre-existing session
		srv.Handler().ServeHTTP(rec, req)
		if rec.Code != http.StatusSeeOther {
			t.Fatalf("login status = %d, want 303", rec.Code)
		}
		c := sessionCookieFrom(rec)
		if c == nil {
			t.Fatal("no session cookie issued")
		}
		return c.Value
	}
	v1 := login("192.0.2.30:1")
	v2 := login("192.0.2.30:2")
	if v1 == preLogin || v2 == preLogin {
		t.Error("post-login session equals the pre-login value (no regeneration)")
	}
	if v1 == v2 {
		t.Error("two logins produced the identical session value (session id not regenerated)")
	}
}

func TestLoginPostBadSignature(t *testing.T) {
	v := &mockVerifier{wantSig: "valid-sig"}
	srv := newTestServer(t, v)
	_, token := mintChallenge(t, srv)

	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, loginForm(token, "milosvasic", "WRONG-sig", "192.0.2.11:5555"))

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", rec.Code)
	}
	if c := sessionCookieFrom(rec); c != nil {
		t.Error("session cookie set on failed login")
	}
	if !strings.Contains(rec.Body.String(), "Sign-in failed") {
		t.Error("failed login did not re-render the generic error")
	}
}

// TestLoginPostRejectsClientPrincipal proves §A1-2/§A1-3: a client-supplied
// principal that is not the configured one is rejected, and the verifier is
// never handed request-controlled identity. principal="a,*" is the SplitSSHell
// comma-in-principal shape.
func TestLoginPostRejectsClientPrincipal(t *testing.T) {
	v := &mockVerifier{wantSig: "valid-sig"}
	srv := newTestServer(t, v)
	_, token := mintChallenge(t, srv)

	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, loginForm(token, "a,*", "valid-sig", "192.0.2.12:5555"))

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401 (client principal must be rejected)", rec.Code)
	}
	if v.calls != 0 {
		t.Error("verifier was consulted despite a rejected client principal")
	}
	if c := sessionCookieFrom(rec); c != nil {
		t.Error("cookie issued for a request carrying an injected principal")
	}
}

// TestLoginPostCSRFRequired proves the login-CSRF gate: a missing state cookie
// and a mismatched token are both rejected (403) before verification.
func TestLoginPostCSRFRequired(t *testing.T) {
	v := &mockVerifier{wantSig: "valid-sig"}
	srv := newTestServer(t, v)

	// Missing CSRF cookie.
	_, token := mintChallenge(t, srv)
	form := url.Values{}
	form.Set("challenge_token", token)
	form.Set("signature", "valid-sig")
	form.Set("csrf_token", testCSRF)
	req := httptest.NewRequest(http.MethodPost, "/login", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.RemoteAddr = "192.0.2.40:1"
	// no CSRF cookie added
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("missing CSRF cookie: status = %d, want 403", rec.Code)
	}
	if v.calls != 0 {
		t.Error("verifier consulted despite missing CSRF cookie")
	}

	// Mismatched CSRF (cookie != form field).
	_, token2 := mintChallenge(t, srv)
	req2 := loginForm(token2, "", "valid-sig", "192.0.2.40:2")
	// overwrite the cookie with a non-matching value
	req2.Header.Del("Cookie")
	req2.AddCookie(&http.Cookie{Name: csrfCookieName, Value: "different-value"})
	rec2 := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec2, req2)
	if rec2.Code != http.StatusForbidden {
		t.Fatalf("mismatched CSRF: status = %d, want 403", rec2.Code)
	}
}

func TestLoginPostForgedChallengeRejected(t *testing.T) {
	v := &mockVerifier{wantSig: "valid-sig"}
	srv := newTestServer(t, v)

	rec := httptest.NewRecorder()
	forged := "YWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWE|9999999999|" +
		"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
	srv.Handler().ServeHTTP(rec, loginForm(forged, "milosvasic", "valid-sig", "192.0.2.13:5555"))

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", rec.Code)
	}
	if v.calls != 0 {
		t.Error("verifier consulted for a forged (bad-HMAC) challenge")
	}
	if c := sessionCookieFrom(rec); c != nil {
		t.Error("cookie issued on forged challenge")
	}
}

func TestLoginPostExpiredChallengeRejected(t *testing.T) {
	v := &mockVerifier{wantSig: "valid-sig"}
	srv := newTestServer(t, v)
	_, token, _, err := srv.challenge.Mint(fixedNow.Add(-5 * time.Minute))
	if err != nil {
		t.Fatalf("Mint: %v", err)
	}

	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, loginForm(token, "milosvasic", "valid-sig", "192.0.2.14:5555"))

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", rec.Code)
	}
	if v.calls != 0 {
		t.Error("verifier consulted for an expired challenge")
	}
}

func TestLoginPostReplayRejected(t *testing.T) {
	v := &mockVerifier{wantSig: "valid-sig"}
	srv := newTestServer(t, v)
	_, token := mintChallenge(t, srv)
	ip := "192.0.2.15:5555"

	rec1 := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec1, loginForm(token, "milosvasic", "valid-sig", ip))
	if rec1.Code != http.StatusSeeOther {
		t.Fatalf("first use status = %d, want 303", rec1.Code)
	}
	rec2 := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec2, loginForm(token, "milosvasic", "valid-sig", ip))
	if rec2.Code != http.StatusUnauthorized {
		t.Fatalf("replay status = %d, want 401", rec2.Code)
	}
	if c := sessionCookieFrom(rec2); c != nil {
		t.Error("cookie issued on replay")
	}
}

func TestAuthWithValidCookie(t *testing.T) {
	srv := newTestServer(t, acceptAllVerifier{})
	token, _, err := srv.codec.Sign("milosvasic", fixedNow)
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/auth", nil)
	req.AddCookie(&http.Cookie{Name: cookieName, Value: token})
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	// §coherence: X-Helix-User must carry the configured account for Caddy.
	if got := rec.Header().Get("X-Helix-User"); got != "milosvasic" {
		t.Errorf("X-Helix-User = %q, want milosvasic", got)
	}
}

func TestAuthWithoutCookie(t *testing.T) {
	srv := newTestServer(t, acceptAllVerifier{})
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/auth", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", rec.Code)
	}
	if got := rec.Header().Get("X-Helix-User"); got != "" {
		t.Errorf("X-Helix-User leaked on unauthenticated /auth: %q", got)
	}
}

// Regression guard (§11.4.135) for the "This page isn't working" failure: an
// unauthenticated top-level BROWSER navigation (GET + Accept: text/html) must be
// redirected to /login (303), which Caddy's forward_auth copies to the client so
// the browser lands on the login form instead of a bare, bodyless 401.
func TestAuthBrowserNavigationRedirectsToLogin(t *testing.T) {
	srv := newTestServer(t, acceptAllVerifier{})
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/auth", nil)
	req.Header.Set("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusSeeOther {
		t.Fatalf("status = %d, want 303 (browser -> /login redirect)", rec.Code)
	}
	if loc := rec.Header().Get("Location"); loc != "/login" {
		t.Errorf("Location = %q, want /login", loc)
	}
	if got := rec.Header().Get("X-Helix-User"); got != "" {
		t.Errorf("X-Helix-User leaked on unauthenticated redirect: %q", got)
	}
}

// The redirect is ONLY for HTML navigations: a programmatic caller (XHR / fetch /
// asset / API — an Accept without text/html) must stay 401 so it never receives an
// HTML login page in place of its expected payload.
func TestAuthNonBrowserRequestsStay401(t *testing.T) {
	srv := newTestServer(t, acceptAllVerifier{})
	for _, accept := range []string{"*/*", "application/json", ""} {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, "/auth", nil)
		if accept != "" {
			req.Header.Set("Accept", accept)
		}
		srv.Handler().ServeHTTP(rec, req)
		if rec.Code != http.StatusUnauthorized {
			t.Fatalf("Accept %q: status = %d, want 401", accept, rec.Code)
		}
	}
}

func TestAuthWithTamperedCookie(t *testing.T) {
	srv := newTestServer(t, acceptAllVerifier{})
	token, _, err := srv.codec.Sign("milosvasic", fixedNow)
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}
	// Corrupt the FIRST payload char (guaranteed to change the decoded bytes,
	// unlike the trailing slack char of a no-padding base64 blob).
	tampered := corruptB64Char(token)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/auth", nil)
	req.AddCookie(&http.Cookie{Name: cookieName, Value: tampered})
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("tampered cookie: status = %d, want 401", rec.Code)
	}
}

func TestAuthWithExpiredCookie(t *testing.T) {
	srv := newTestServer(t, acceptAllVerifier{})
	token, _, err := srv.codec.Sign("milosvasic", fixedNow.Add(-2*time.Hour))
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/auth", nil)
	req.AddCookie(&http.Cookie{Name: cookieName, Value: token})
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expired cookie: status = %d, want 401", rec.Code)
	}
}

func TestLogoutClearsCookie(t *testing.T) {
	srv := newTestServer(t, acceptAllVerifier{})
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/logout", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusSeeOther {
		t.Fatalf("status = %d, want 303", rec.Code)
	}
	if loc := rec.Header().Get("Location"); loc != "/login" {
		t.Errorf("Location = %q, want /login", loc)
	}
	c := sessionCookieFrom(rec)
	if c == nil {
		t.Fatal("logout did not emit a clearing cookie")
	}
	if c.MaxAge >= 0 {
		t.Errorf("clearing cookie MaxAge = %d, want < 0", c.MaxAge)
	}
	if c.Value != "" {
		t.Errorf("clearing cookie Value = %q, want empty", c.Value)
	}
}

func TestLoginRateLimited(t *testing.T) {
	v := &mockVerifier{wantSig: "valid-sig"}
	srv := newTestServer(t, v) // RateLimitMax = 3
	ip := "192.0.2.20:5555"

	for i := 0; i < 3; i++ {
		_, token := mintChallenge(t, srv)
		rec := httptest.NewRecorder()
		srv.Handler().ServeHTTP(rec, loginForm(token, "milosvasic", "wrong", ip))
		if rec.Code != http.StatusUnauthorized {
			t.Fatalf("attempt %d status = %d, want 401", i, rec.Code)
		}
	}
	callsBefore := v.calls
	_, token := mintChallenge(t, srv)
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, loginForm(token, "milosvasic", "wrong", ip))
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("throttled attempt status = %d, want 429", rec.Code)
	}
	if v.calls != callsBefore {
		t.Error("verifier called on a throttled request (should short-circuit)")
	}
}

func TestLoginFailClosedOnUnknownIP(t *testing.T) {
	v := &mockVerifier{wantSig: "valid-sig"}
	srv := newTestServer(t, v)
	_, token := mintChallenge(t, srv)

	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, loginForm(token, "milosvasic", "valid-sig", "")) // empty RemoteAddr

	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503 (fail closed on unknown client)", rec.Code)
	}
	if v.calls != 0 {
		t.Error("verifier called despite fail-closed limiter path")
	}
	if c := sessionCookieFrom(rec); c != nil {
		t.Error("cookie issued on fail-closed path")
	}
}

func TestLoginTrustForwardedForKeying(t *testing.T) {
	v := &mockVerifier{wantSig: "valid-sig"}
	srv := newTestServer(t, v)
	srv.cfg.TrustForwardedFor = true

	proxyAddr := "127.0.0.1:4444"
	exhaust := func(xff string) {
		for i := 0; i < 3; i++ {
			_, token := mintChallenge(t, srv)
			rec := httptest.NewRecorder()
			req := loginForm(token, "milosvasic", "wrong", proxyAddr)
			req.Header.Set("X-Forwarded-For", xff)
			srv.Handler().ServeHTTP(rec, req)
		}
	}
	exhaust("203.0.113.1")

	_, token := mintChallenge(t, srv)
	rec := httptest.NewRecorder()
	req := loginForm(token, "milosvasic", "wrong", proxyAddr)
	req.Header.Set("X-Forwarded-For", "203.0.113.1")
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("client .1 status = %d, want 429", rec.Code)
	}

	_, token2 := mintChallenge(t, srv)
	rec = httptest.NewRecorder()
	req = loginForm(token2, "milosvasic", "valid-sig", proxyAddr)
	req.Header.Set("X-Forwarded-For", "203.0.113.2")
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("client .2 status = %d, want 303 (independent budget)", rec.Code)
	}
}

// TestLoginRightmostForwardedForKeying proves review finding [MAJOR](b): with
// TrustForwardedFor, the limiter keys on the RIGHTMOST X-Forwarded-For entry
// (the trusted Caddy hop), NEVER the client-spoofable leftmost. Two clients
// with distinct rightmost addresses get independent buckets, and a spoofed
// leftmost cannot dodge (or move) a bucket keyed on the rightmost.
func TestLoginRightmostForwardedForKeying(t *testing.T) {
	v := &mockVerifier{wantSig: "valid-sig"}
	srv := newTestServer(t, v) // RateLimitMax = 3
	srv.cfg.TrustForwardedFor = true
	const proxyAddr = "127.0.0.1:4444" // the trusted hop's own RemoteAddr

	postXFF := func(xff, sig string) *httptest.ResponseRecorder {
		_, token := mintChallenge(t, srv)
		req := loginForm(token, "milosvasic", sig, proxyAddr)
		req.Header.Set("X-Forwarded-For", xff)
		rec := httptest.NewRecorder()
		srv.Handler().ServeHTTP(rec, req)
		return rec
	}

	// Exhaust client A's budget. Each request carries a DIFFERENT spoofed
	// leftmost but the SAME real rightmost (203.0.113.9 appended by Caddy).
	for i := 0; i < 3; i++ {
		rec := postXFF("10.0.0."+strconv.Itoa(i)+", 203.0.113.9", "wrong")
		if rec.Code != http.StatusUnauthorized {
			t.Fatalf("A attempt %d: status=%d, want 401", i, rec.Code)
		}
	}
	// Same rightmost .9, yet-another spoofed leftmost → SAME bucket → throttled.
	if rec := postXFF("9.9.9.9, 203.0.113.9", "wrong"); rec.Code != http.StatusTooManyRequests {
		t.Fatalf("spoofed-leftmost same-rightmost: status=%d, want 429 (rightmost keying)", rec.Code)
	}
	// Client B: DIFFERENT rightmost (.10) → independent budget → valid login OK.
	if rec := postXFF("10.0.0.0, 203.0.113.10", "valid-sig"); rec.Code != http.StatusSeeOther {
		t.Fatalf("different-rightmost client: status=%d, want 303 (independent bucket)", rec.Code)
	}
}

// TestLoginPostNoCSRFDoesNotConsumeBudget proves review finding [MAJOR](a): a
// POST without a valid login-CSRF pair is rejected (403) WITHOUT recording a
// rate-limit failure, so an unauthenticated attacker cannot lock out the sole
// legitimate user. After more no-CSRF posts than RateLimitMax, a proper login
// still succeeds — the victim's budget was never touched.
func TestLoginPostNoCSRFDoesNotConsumeBudget(t *testing.T) {
	v := &mockVerifier{wantSig: "valid-sig"}
	srv := newTestServer(t, v) // RateLimitMax = 3
	const ip = "192.0.2.77:5555"

	for i := 0; i < 5; i++ { // 5 > RateLimitMax
		_, token := mintChallenge(t, srv)
		form := url.Values{}
		form.Set("challenge_token", token)
		form.Set("signature", "valid-sig")
		form.Set("csrf_token", testCSRF) // field present, but NO matching cookie
		req := httptest.NewRequest(http.MethodPost, "/login", strings.NewReader(form.Encode()))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		req.RemoteAddr = ip
		rec := httptest.NewRecorder()
		srv.Handler().ServeHTTP(rec, req)
		if rec.Code != http.StatusForbidden {
			t.Fatalf("no-CSRF attempt %d: status=%d, want 403", i, rec.Code)
		}
	}
	if v.calls != 0 {
		t.Errorf("verifier consulted on no-CSRF posts: calls=%d", v.calls)
	}

	// The victim's budget must be intact: a valid CSRF + valid-sig login works.
	_, token := mintChallenge(t, srv)
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, loginForm(token, "", "valid-sig", ip))
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("victim login after no-CSRF flood: status=%d, want 303 (budget must be intact)", rec.Code)
	}
}

// TestLoginPostBodyTooLarge proves the [NIT] MaxBytesReader guard: a POST body
// over maxLoginBodyBytes is rejected (400) before any verification work.
func TestLoginPostBodyTooLarge(t *testing.T) {
	v := &mockVerifier{wantSig: "valid-sig"}
	srv := newTestServer(t, v)

	form := url.Values{}
	form.Set("signature", strings.Repeat("A", maxLoginBodyBytes+4096)) // > 64 KiB
	req := httptest.NewRequest(http.MethodPost, "/login", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.RemoteAddr = "192.0.2.88:1"
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("oversized body: status=%d, want 400", rec.Code)
	}
	if v.calls != 0 {
		t.Errorf("verifier consulted on oversized body: calls=%d", v.calls)
	}
}

// TestLoginVerifyConcurrencyCap proves review finding [MAJOR](c): the GLOBAL
// concurrent-verify (ssh-keygen spawn) ceiling bounds concurrency. With a
// capacity of 1, while one login holds the only slot inside Verify, a second
// concurrent login fails closed FAST with 503 instead of spawning another proc.
func TestLoginVerifyConcurrencyCap(t *testing.T) {
	bv := &blockingVerifier{entered: make(chan struct{}), release: make(chan struct{})}
	cfg := baseTestConfig()
	cfg.VerifyConcurrency = 1
	cfg.RateLimitMax = 10
	srv, err := NewServer(cfg, testSecret(), bv, func() time.Time { return fixedNow })
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}

	// Request 1 acquires the only slot and blocks inside Verify.
	_, token1 := mintChallenge(t, srv)
	rec1 := httptest.NewRecorder()
	done := make(chan struct{})
	go func() {
		srv.Handler().ServeHTTP(rec1, loginForm(token1, "", "sig", "192.0.2.101:1"))
		close(done)
	}()
	select {
	case <-bv.entered: // request 1 is inside Verify, slot held
	case <-time.After(2 * time.Second):
		t.Fatal("request 1 never entered Verify")
	}

	// Request 2 finds the ceiling saturated → 503 fast, no verify.
	_, token2 := mintChallenge(t, srv)
	rec2 := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec2, loginForm(token2, "", "sig", "192.0.2.102:1"))
	if rec2.Code != http.StatusServiceUnavailable {
		t.Fatalf("saturated spawn ceiling: status=%d, want 503", rec2.Code)
	}

	// Release request 1 → it completes successfully.
	close(bv.release)
	<-done
	if rec1.Code != http.StatusSeeOther {
		t.Fatalf("request 1 final status=%d, want 303", rec1.Code)
	}
}
