package main

import (
	"crypto/hmac"
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"html/template"
	"log"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

// Cookie names. Both use the __Host- prefix (§A5-1), which browsers only accept
// on a Secure, Path=/, Domain-less cookie — hardening against network-based
// session fixation and subdomain injection.
const (
	cookieName     = "__Host-helix_session" // session cookie
	csrfCookieName = "__Host-helix_csrf"    // login-CSRF double-submit state cookie
)

// csrfTokenLen is the byte length of a login-CSRF token.
const csrfTokenLen = 32

// maxLoginBodyBytes caps the POST /login request body (form-encoded challenge +
// signature). 64 KiB comfortably fits an armored signature (capped at 16 KiB in
// the verifier) plus the small form fields, while a larger body is rejected by
// http.MaxBytesReader before it is buffered (§A4-3 DoS blunting).
const maxLoginBodyBytes = 64 << 10 // 64 KiB

// Server holds the wired dependencies for the HTTP handlers. Construct it with
// NewServer; obtain the gin-backed http.Handler with Handler.
type Server struct {
	cfg       Config
	codec     *CookieCodec
	challenge *ChallengeCodec
	replay    *ReplayGuard
	verifier  Verifier
	limiter   *RateLimiter
	tmpl      *template.Template
	now       func() time.Time

	// verifySem is the GLOBAL concurrent-verify (ssh-keygen spawn) ceiling. A
	// buffered channel used as a counting semaphore: an empty slot must be
	// acquired before Verify runs and released after. On saturation POST /login
	// fails closed fast (§A4-3, exec-flood bound independent of rate-limit key).
	verifySem chan struct{}

	// engine is the built gin router (an http.Handler). Built once in NewServer.
	engine *gin.Engine
}

// NewServer wires the cookie codec, challenge codec, replay guard, verifier and
// rate limiter from cfg + secret. The cookie codec and challenge codec share
// the one HMAC secret (domain-separated). now defaults to time.Now when nil
// (tests inject a fixed clock).
func NewServer(cfg Config, secret []byte, verifier Verifier, now func() time.Time) (*Server, error) {
	if now == nil {
		now = time.Now
	}
	tmpl, err := template.New("login").Parse(loginPageTemplate)
	if err != nil {
		return nil, err
	}
	conc := cfg.VerifyConcurrency
	if conc <= 0 {
		// Defend against a Config literal (e.g. in tests) that leaves the field
		// zero: a zero-capacity semaphore would reject every login.
		conc = defaultVerifyConcurrency
	}
	s := &Server{
		cfg:       cfg,
		codec:     NewCookieCodec(secret, cfg.SessionTTL),
		challenge: NewChallengeCodec(secret, cfg.ChallengeTTL),
		replay:    NewReplayGuard(),
		verifier:  verifier,
		limiter:   NewRateLimiter(cfg.RateLimitMax, cfg.RateLimitWindow),
		tmpl:      tmpl,
		now:       now,
		verifySem: make(chan struct{}, conc),
	}
	s.engine = s.buildEngine()
	return s, nil
}

// Handler returns the gin-backed http.Handler for the service. The caller wraps
// it in a hardened *http.Server (timeouts) in main; tests drive it directly via
// httptest (gin's standard ServeHTTP pattern).
func (s *Server) Handler() http.Handler { return s.engine }

// buildEngine wires the gin router. Cross-cutting POST /login concerns live in
// middleware where natural — body-size limit, the rate-limit ALLOW gate, and
// the login-CSRF double-submit check — so the handler holds only the
// challenge-response verification sequence.
func (s *Server) buildEngine() *gin.Engine {
	r := gin.New()
	// Recovery only — no request logger (avoids logging one-time challenge /
	// path noise; a security gate does not need per-request access logs here).
	r.Use(gin.Recovery())

	r.GET("/healthz", wrapHTTP(s.handleHealthz))
	r.GET("/auth", wrapHTTP(s.handleAuth))
	r.GET("/login", wrapHTTP(s.handleLoginGet))
	r.POST("/login",
		s.mwBodyLimit(),
		s.mwRateLimit(),
		s.mwCSRF(),
		wrapHTTP(s.handleLoginPost),
	)
	r.POST("/logout", wrapHTTP(s.handleLogout))
	return r
}

// wrapHTTP adapts a std-lib (http.ResponseWriter, *http.Request) handler into a
// gin.HandlerFunc. The security handlers stay framework-agnostic — gin only
// supplies the ResponseWriter + Request.
func wrapHTTP(h func(http.ResponseWriter, *http.Request)) gin.HandlerFunc {
	return func(c *gin.Context) { h(c.Writer, c.Request) }
}

// mwBodyLimit bounds the POST /login body (§A4-3). MaxBytesReader makes a later
// ParseForm fail with an error once the cap is exceeded, which mwCSRF turns into
// a 400 before any verification work.
func (s *Server) mwBodyLimit() gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, maxLoginBodyBytes)
		c.Next()
	}
}

// mwRateLimit is the ALLOW gate: it checks (never consumes) the client's budget
// before any work. A fail-closed limiter fault -> 503; an over-budget client ->
// 429. Keying is on the resolved client IP (rightmost trusted XFF or
// RemoteAddr). It records nothing — RecordFailure/RecordSuccess happen in the
// handler, and ONLY after CSRF + challenge validation, so an unauthenticated
// POST cannot consume the victim's budget.
func (s *Server) mwRateLimit() gin.HandlerFunc {
	return func(c *gin.Context) {
		now := s.now()
		ip := s.clientIP(c.Request)
		allowed, err := s.limiter.Allow(ip, now)
		if err != nil {
			s.renderLogin(c.Writer, http.StatusServiceUnavailable, true)
			c.Abort()
			return
		}
		if !allowed {
			s.renderLogin(c.Writer, http.StatusTooManyRequests, true)
			c.Abort()
			return
		}
		c.Next()
	}
}

// mwCSRF parses the form (bounded by mwBodyLimit) and enforces the login-CSRF
// double-submit check BEFORE the handler runs. A parse error (incl. an
// over-limit body) -> 400; a missing/mismatched token -> 403. Neither records a
// rate-limit failure, so a no-CSRF / oversized POST never burns the victim's
// budget (rate-limiter DoS fix).
func (s *Server) mwCSRF() gin.HandlerFunc {
	return func(c *gin.Context) {
		if err := c.Request.ParseForm(); err != nil {
			s.renderLogin(c.Writer, http.StatusBadRequest, true)
			c.Abort()
			return
		}
		if !s.csrfValid(c.Request) {
			s.renderLogin(c.Writer, http.StatusForbidden, true)
			c.Abort()
			return
		}
		c.Next()
	}
}

// handleHealthz is an unauthenticated liveness probe.
func (s *Server) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

// handleAuth is the forward-auth check Caddy calls per request: a valid signed
// session cookie yields 200 (plus X-Helix-User so Caddy can propagate the
// identity to code-server via copy_headers). Unauthenticated:
//   - a top-level BROWSER navigation (GET + Accept: text/html) is redirected to
//     /login (303) so the user lands on the login form instead of a bare 401 —
//     Caddy's forward_auth copies this response verbatim to the client, so the
//     browser follows the redirect and sees the login page (the canonical
//     forward-auth → login pattern used by Authelia/Authentik);
//   - every OTHER request (XHR / fetch / asset / API — Accept without text/html,
//     or a non-GET method) gets 401, so a programmatic caller never receives an
//     HTML login page in place of its expected payload.
func (s *Server) handleAuth(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.sessionUser(r); ok {
		// The session subject is always the configured account; advertise it so
		// the reverse proxy can attach it downstream.
		w.Header().Set("X-Helix-User", s.cfg.Account)
		w.WriteHeader(http.StatusOK)
		return
	}
	if r.Method == http.MethodGet && strings.Contains(r.Header.Get("Accept"), "text/html") {
		http.Redirect(w, r, "/login", http.StatusSeeOther)
		return
	}
	w.WriteHeader(http.StatusUnauthorized)
}

// handleLoginGet renders the login page with a fresh challenge + CSRF token.
func (s *Server) handleLoginGet(w http.ResponseWriter, r *http.Request) {
	// Already authenticated → send to the app.
	if _, ok := s.sessionUser(r); ok {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	s.renderLogin(w, http.StatusOK, false)
}

// handleLoginPost verifies an SSH-key challenge-response and issues a session
// cookie on success. The rate-limit ALLOW gate (mwRateLimit), body-size cap
// (mwBodyLimit), form parse + login-CSRF double-submit (mwCSRF) already ran as
// middleware, so on entry the form is parsed and CSRF is proven valid.
//
// Remaining sequence (each failure is generic, no cookie):
//  4. reject any client principal that is not the configured one (never let
//     request input drive identity, §A1-2) — NOT rate-counted;
//  5. challenge HMAC valid + unexpired (server-issued, not forged) — NOT
//     rate-counted;
//  6. nonce not already used (single-use replay guard, fail closed);
//  7. GLOBAL spawn-ceiling gate, then signature verifies over the challenge
//     bytes for the configured principal.
//
// Rate-limiter DoS fix (§11.4.134): a failure is recorded against the client's
// budget ONLY for a genuine post-challenge SIGNATURE failure (step 7). CSRF and
// challenge validation are proven BEFORE any budget is consumed, so an
// unauthenticated / no-CSRF / forged-challenge POST cannot lock out the sole
// legitimate user. A real brute-forcer still presents a valid CSRF + fresh
// challenge and burns budget on each wrong signature, so throttling is intact.
func (s *Server) handleLoginPost(w http.ResponseWriter, r *http.Request) {
	now := s.now()
	ip := s.clientIP(r) // same key mwRateLimit gated on

	// (4) Reject a client-supplied principal that differs from the configured
	// one. The verifier is NEVER handed request input for identity matching.
	// Not rate-counted: a real attacker submits the correct principal anyway.
	if p := strings.TrimSpace(r.PostFormValue("principal")); p != "" && p != s.cfg.Principal {
		s.renderLogin(w, http.StatusUnauthorized, true)
		return
	}

	token := strings.TrimSpace(r.PostFormValue("challenge_token"))
	signature := r.PostFormValue("signature")

	// (5) Challenge HMAC valid + unexpired. Not rate-counted (a forged/expired
	// challenge is not a signature guess; it never reaches the verifier).
	challenge, expiry, cerr := s.challenge.Verify(token, now)
	if cerr != nil {
		s.renderLogin(w, http.StatusUnauthorized, true)
		return
	}

	// (6) Single-use: claim the nonce. A structural guard fault fails closed;
	// an already-claimed nonce is a replay → deny (bounded by single-use, not
	// rate-counted).
	claimed, rerr := s.replay.Claim(challenge, expiry, now)
	if rerr != nil {
		s.renderLogin(w, http.StatusServiceUnavailable, true)
		return
	}
	if !claimed {
		s.renderLogin(w, http.StatusUnauthorized, true)
		return
	}

	// (7) GLOBAL ssh-keygen spawn ceiling around the verify exec: acquire a slot
	// or fail closed (503) FAST, so an exec-flood is bounded regardless of
	// per-client keying.
	select {
	case s.verifySem <- struct{}{}:
	default:
		s.renderLogin(w, http.StatusServiceUnavailable, true)
		return
	}
	// Release via defer so the slot is returned even if Verify panics (gin.Recovery
	// catches the panic) — otherwise the ceiling would shrink permanently (review nit).
	defer func() { <-s.verifySem }()
	verr := s.verifier.Verify([]byte(challenge), signature)
	if verr != nil {
		// THE ONLY budget-consuming failure: a genuine signature failure after a
		// valid CSRF + valid, unexpired, unclaimed challenge.
		s.limiter.RecordFailure(ip, now)
		s.renderLogin(w, http.StatusUnauthorized, true)
		return
	}

	// Success: clear throttle state, regenerate the session (fresh cookie value)
	// for the account, redirect to the app.
	s.limiter.RecordSuccess(ip)
	cookieToken, cookieExpiry, sErr := s.codec.Sign(s.cfg.Account, now)
	if sErr != nil {
		// CSPRNG failure minting the session → fail closed, no cookie.
		log.Printf("session sign error: %v", sErr)
		s.renderLogin(w, http.StatusServiceUnavailable, true)
		return
	}
	http.SetCookie(w, s.newSessionCookie(cookieToken, cookieExpiry))
	// The one-time challenge state is spent; clear the CSRF cookie.
	http.SetCookie(w, s.clearedCSRFCookie())
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

// handleLogout clears the session cookie and returns to the login page.
func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	http.SetCookie(w, s.clearedSessionCookie())
	http.Redirect(w, r, "/login", http.StatusSeeOther)
}

// csrfValid reports whether the request carries a login-CSRF state cookie that
// matches (constant-time) the hidden form token. Both must be present and
// non-empty — a missing cookie or field fails closed.
func (s *Server) csrfValid(r *http.Request) bool {
	c, err := r.Cookie(csrfCookieName)
	if err != nil || c.Value == "" {
		return false
	}
	form := r.PostFormValue("csrf_token")
	if form == "" {
		return false
	}
	return hmac.Equal([]byte(c.Value), []byte(form))
}

// sessionUser extracts and validates the session cookie, returning the user
// and whether a valid session is present.
func (s *Server) sessionUser(r *http.Request) (string, bool) {
	c, err := r.Cookie(cookieName)
	if err != nil || c.Value == "" {
		return "", false
	}
	user, verr := s.codec.Verify(c.Value, s.now())
	if verr != nil {
		return "", false
	}
	return user, true
}

// newSessionCookie builds the signed session cookie: __Host- prefix, HttpOnly,
// Secure, SameSite=Strict, Path=/, NO Domain, and an expiry (§A5-1).
func (s *Server) newSessionCookie(token string, expiry time.Time) *http.Cookie {
	return &http.Cookie{
		Name:     cookieName,
		Value:    token,
		Path:     "/",
		HttpOnly: true,
		Secure:   true,
		SameSite: http.SameSiteStrictMode,
		Expires:  expiry,
		MaxAge:   int(s.cfg.SessionTTL.Seconds()),
	}
}

// clearedSessionCookie is an expired empty cookie that evicts the session.
func (s *Server) clearedSessionCookie() *http.Cookie {
	return &http.Cookie{
		Name:     cookieName,
		Value:    "",
		Path:     "/",
		HttpOnly: true,
		Secure:   true,
		SameSite: http.SameSiteStrictMode,
		MaxAge:   -1,
	}
}

// newCSRFCookie builds the login-CSRF state cookie carrying token.
func (s *Server) newCSRFCookie(token string) *http.Cookie {
	return &http.Cookie{
		Name:     csrfCookieName,
		Value:    token,
		Path:     "/",
		HttpOnly: true,
		Secure:   true,
		SameSite: http.SameSiteStrictMode,
		MaxAge:   int(s.cfg.ChallengeTTL.Seconds()),
	}
}

// clearedCSRFCookie evicts the login-CSRF state cookie after a successful login.
func (s *Server) clearedCSRFCookie() *http.Cookie {
	return &http.Cookie{
		Name:     csrfCookieName,
		Value:    "",
		Path:     "/",
		HttpOnly: true,
		Secure:   true,
		SameSite: http.SameSiteStrictMode,
		MaxAge:   -1,
	}
}

// renderLogin writes the login page with the given status code, minting a
// FRESH challenge AND a fresh login-CSRF token on every render (so a user whose
// first attempt failed always has an unused challenge + matching CSRF state to
// sign/submit). showError toggles a single generic error banner.
func (s *Server) renderLogin(w http.ResponseWriter, status int, showError bool) {
	data := loginPageData{
		Account:   s.cfg.Account,
		Principal: s.cfg.Principal,
		Namespace: sshSigNamespace,
		ShowError: showError,
	}

	// Fresh CSRF state cookie + matching hidden field (double submit).
	if csrf, err := randToken(csrfTokenLen); err == nil {
		data.CSRFToken = csrf
		http.SetCookie(w, s.newCSRFCookie(csrf))
	} else {
		log.Printf("csrf token mint error: %v", err)
		data.ShowError = true
	}

	if challenge, token, _, err := s.challenge.Mint(s.now()); err != nil {
		// Minting a challenge only fails if the CSPRNG fails — surface a
		// degraded page rather than a usable-looking one (fail closed).
		log.Printf("challenge mint error: %v", err)
		data.ShowError = true
	} else {
		data.Challenge = challenge
		data.ChallengeToken = token
		data.SignCommand = fmt.Sprintf(
			"printf %%s '%s' | ssh-keygen -Y sign -n %s -f ~/.ssh/id_ed25519",
			challenge, sshSigNamespace)
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	// Do not cache authenticated-gate pages (or the one-time challenge).
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	if err := s.tmpl.Execute(w, data); err != nil {
		log.Printf("login template render error: %v", err)
	}
}

// randToken returns base64url of n random bytes.
func randToken(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

// clientIP resolves the rate-limit key for r. When TrustForwardedFor is set it
// uses the RIGHTMOST X-Forwarded-For entry — the address appended by the single
// trusted proxy (Caddy) directly in front of this gate. The leftmost entries
// are client-supplied and spoofable; keying on them would let an attacker forge
// arbitrary keys to evade the limiter or poison another client's bucket, so
// they are deliberately ignored. When the header is absent, or trust is off, it
// falls back to the RemoteAddr host. Returns "" when it cannot determine an IP,
// which drives the limiter's fail-closed path.
func (s *Server) clientIP(r *http.Request) string {
	if s.cfg.TrustForwardedFor {
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			parts := strings.Split(xff, ",")
			last := strings.TrimSpace(parts[len(parts)-1])
			if last != "" {
				return last
			}
		}
	}
	if r.RemoteAddr == "" {
		return ""
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		// RemoteAddr may already be a bare host.
		return r.RemoteAddr
	}
	return host
}

// loginPageData is the template model for the login page.
type loginPageData struct {
	Account        string
	Principal      string
	Challenge      string // base64url(nonce) the user signs
	ChallengeToken string // opaque HMAC token carried in the hidden field
	CSRFToken      string // login-CSRF double-submit token (also set as a cookie)
	SignCommand    string // exact `ssh-keygen -Y sign` command to run
	Namespace      string // ssh signature namespace
	ShowError      bool
}

// loginPageTemplate is a minimal, clean, self-contained SSH-key challenge login
// page. All dynamic values pass through html/template auto-escaping; the
// challenge/token/command are base64url + fixed text (no HTML-special chars).
// There is NO password field — the user proves possession of their private key
// by signing the shown challenge locally and pasting the signature.
const loginPageTemplate = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>HelixCode — Sign in</title>
<style>
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0; min-height: 100vh; display: flex; align-items: center;
    justify-content: center; font-family: system-ui, -apple-system, Segoe UI,
    Roboto, sans-serif; background: #0f1115; color: #e6e6e6;
  }
  .card {
    width: 100%; max-width: 520px; padding: 2rem; border-radius: 12px;
    background: #171a21; box-shadow: 0 10px 30px rgba(0,0,0,.4);
  }
  h1 { font-size: 1.25rem; margin: 0 0 .5rem; font-weight: 600; }
  p.lead { margin: 0 0 1.25rem; font-size: .9rem; opacity: .8; }
  label { display: block; font-size: .8rem; margin: .9rem 0 .3rem; opacity: .85; }
  ol { margin: 0 0 .5rem 1.1rem; padding: 0; font-size: .85rem; opacity: .9; }
  li { margin: .35rem 0; }
  input, textarea {
    width: 100%; padding: .6rem .7rem; border-radius: 8px; border: 1px solid #2a2f3a;
    background: #0f1115; color: #e6e6e6; font-size: .95rem;
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  }
  textarea { min-height: 8rem; resize: vertical; }
  input:focus, textarea:focus { outline: 2px solid #4c8bf5; border-color: transparent; }
  pre {
    margin: .35rem 0 0; padding: .7rem .8rem; border-radius: 8px; overflow-x: auto;
    background: #0b0d12; border: 1px solid #2a2f3a; font-size: .82rem;
  }
  code { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
  button {
    width: 100%; margin-top: 1.25rem; padding: .65rem; border: 0; border-radius: 8px;
    background: #4c8bf5; color: #fff; font-size: 1rem; font-weight: 600; cursor: pointer;
  }
  button:hover { background: #3d78dd; }
  .err {
    margin: 0 0 1rem; padding: .55rem .7rem; border-radius: 8px;
    background: #3a1d22; color: #ffb4b4; font-size: .85rem;
  }
</style>
</head>
<body>
  <main class="card">
    <h1>Sign in to HelixCode</h1>
    <p class="lead">SSH-key sign-in for <strong>{{.Account}}</strong> — no password. Sign the one-time challenge below with your registered key.</p>
    {{if .ShowError}}<p class="err" role="alert">Sign-in failed. A fresh challenge has been issued below — please sign it and try again.</p>{{end}}
    <ol>
      <li>Copy the challenge and run this command locally (namespace <code>{{.Namespace}}</code>):
        <pre><code>{{.SignCommand}}</code></pre>
      </li>
      <li>Paste the full <code>-----BEGIN SSH SIGNATURE-----</code> block it prints into the box below.</li>
    </ol>
    <form method="POST" action="/login" autocomplete="off">
      <input type="hidden" name="challenge_token" value="{{.ChallengeToken}}">
      <input type="hidden" name="csrf_token" value="{{.CSRFToken}}">
      <label for="principal">Principal</label>
      <input id="principal" name="principal" type="text" value="{{.Principal}}"
             autocapitalize="none" autocorrect="off" spellcheck="false">
      <label for="challenge">Challenge (sign exactly this)</label>
      <input id="challenge" name="challenge_display" type="text" value="{{.Challenge}}" readonly>
      <label for="signature">Signature</label>
      <textarea id="signature" name="signature" required spellcheck="false"
                placeholder="-----BEGIN SSH SIGNATURE-----&#10;...&#10;-----END SSH SIGNATURE-----"></textarea>
      <button type="submit">Sign in</button>
    </form>
  </main>
</body>
</html>
`
