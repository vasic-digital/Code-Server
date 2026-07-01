// Package main implements helix-auth: a small, decoupled forward-auth HTTP
// gate that authenticates a login via an SSH-key challenge-response and issues
// a signed session cookie.
//
// It stores NO password (there is none): the user proves possession of a
// private key by signing a server-issued challenge with `ssh-keygen -Y sign`;
// the service verifies that signature with `ssh-keygen -Y verify` against an
// allowed-signers file derived from the account's ~/.ssh/authorized_keys. The
// service NEVER reads a private key. The only on-disk artifact is the HMAC
// cookie/challenge-signing secret (0600), which is a server key, not a
// credential.
//
// Design authority:
//   - docs/superpowers/specs/2026-07-01-auth-pivot-ssh-key.md (authoritative)
//   - docs/superpowers/specs/2026-07-01-real-account-code-server-design.md (context)
package main

import (
	"fmt"
	"strconv"
	"strings"
	"time"
)

// Config holds all runtime parameters. Every field is sourced from an
// environment variable with a documented default so the service stays
// project-agnostic and decoupled (§11.4.28) — no hardcoded host paths,
// hostnames or asset names beyond the enumerated env defaults.
type Config struct {
	// Mode selects the authentication mechanism. Only "sshkey" is supported in
	// this release. Env: HELIX_AUTH_MODE (default "sshkey"). LoadConfig rejects
	// any other value rather than silently degrading (§11.4.6 no-guessing).
	Mode string

	// Account is the system account a session ties to. It is also the default
	// value of Principal when HELIX_AUTH_PRINCIPAL is unset.
	// Env: HELIX_AUTH_ACCOUNT (default "milosvasic").
	Account string

	// AuthorizedKeys is the path to the account's authorized_keys file, whose
	// public keys become the allowed signers for challenge verification. Only
	// public key material is ever read. Env: HELIX_AUTH_AUTHORIZED_KEYS
	// (default "~/.ssh/authorized_keys").
	AuthorizedKeys string

	// Principal is the identity written into every allowed-signers line and
	// passed to `ssh-keygen -Y verify -I <principal>`. The POST /login form's
	// principal field must equal this value. Env: HELIX_AUTH_PRINCIPAL
	// (default: Account).
	Principal string

	// Bind is the loopback listen address. Env: HELIX_AUTH_BIND
	// (default "127.0.0.1:8081").
	Bind string

	// SessionTTL is how long an issued cookie stays valid.
	// Env: HELIX_AUTH_SESSION_TTL (Go duration, default "8h").
	SessionTTL time.Duration

	// ChallengeTTL is how long a minted login challenge stays valid before the
	// user must fetch a fresh one. Kept short to bound the replay window.
	// Env: HELIX_AUTH_CHALLENGE_TTL (Go duration, default "2m").
	ChallengeTTL time.Duration

	// CookieSecretPath is the 0600 file holding the 32-byte HMAC secret used to
	// sign BOTH session cookies AND login challenges (domain-separated); it is
	// generated if absent. Env: HELIX_AUTH_COOKIE_SECRET
	// (default "~/.config/helixcode/cookie_secret").
	CookieSecretPath string

	// RateLimitMax is the maximum failed POST /login attempts permitted per
	// client IP within RateLimitWindow. Env: HELIX_AUTH_RATE_MAX (default 5).
	RateLimitMax int

	// RateLimitWindow is the fixed window for RateLimitMax.
	// Env: HELIX_AUTH_RATE_WINDOW (Go duration, default "60s").
	RateLimitWindow time.Duration

	// VerifyConcurrency is the GLOBAL ceiling on concurrent signature
	// verifications (each spawns one `ssh-keygen` process). It bounds an
	// exec-flood regardless of per-client rate-limit keying; once the ceiling
	// is saturated POST /login fails closed (503) fast instead of spawning an
	// unbounded number of processes. Env: HELIX_AUTH_VERIFY_CONCURRENCY
	// (default 4). NewServer substitutes the default for any non-positive value.
	VerifyConcurrency int

	// TrustForwardedFor makes the rate limiter key off the RIGHTMOST
	// X-Forwarded-For entry instead of RemoteAddr, for when a single trusted
	// loopback reverse proxy (Caddy) fronts the service. The rightmost entry is
	// the one appended by that trusted hop; the leftmost entries are
	// client-supplied and spoofable, so keying on them would let an attacker
	// forge arbitrary keys (and evade / poison the limiter). Env:
	// HELIX_AUTH_TRUST_FORWARDED_FOR (default false). Only enable when exactly
	// one trusted proxy fronts the service.
	TrustForwardedFor bool
}

// Config env-var names and defaults, exported as constants for tests + docs.
const (
	envMode              = "HELIX_AUTH_MODE"
	envAccount           = "HELIX_AUTH_ACCOUNT"
	envAuthorizedKeys    = "HELIX_AUTH_AUTHORIZED_KEYS"
	envPrincipal         = "HELIX_AUTH_PRINCIPAL"
	envBind              = "HELIX_AUTH_BIND"
	envSessionTTL        = "HELIX_AUTH_SESSION_TTL"
	envChallengeTTL      = "HELIX_AUTH_CHALLENGE_TTL"
	envCookieSecret      = "HELIX_AUTH_COOKIE_SECRET"
	envRateMax           = "HELIX_AUTH_RATE_MAX"
	envRateWindow        = "HELIX_AUTH_RATE_WINDOW"
	envVerifyConc        = "HELIX_AUTH_VERIFY_CONCURRENCY"
	envTrustForwardedFor = "HELIX_AUTH_TRUST_FORWARDED_FOR"

	// modeSSHKey is the only supported auth mode this release.
	modeSSHKey = "sshkey"

	defaultMode              = modeSSHKey
	defaultAccount           = "milosvasic"
	defaultAuthorizedKeys    = "~/.ssh/authorized_keys"
	defaultBind              = "127.0.0.1:8081"
	defaultSessionTTL        = 8 * time.Hour
	defaultChallengeTTL      = 2 * time.Minute
	defaultCookieSecretRel   = "~/.config/helixcode/cookie_secret"
	defaultRateLimitMax      = 5
	defaultRateLimitWindow   = 60 * time.Second
	defaultVerifyConcurrency = 4
	defaultTrustForwarded    = false
)

// LoadConfig builds a Config from the supplied getenv function (inject
// os.Getenv in main, a map-backed stub in tests). homeDir is used to expand a
// leading "~/" in file paths; pass os.UserHomeDir()'s result in main. It
// returns an error on malformed values rather than silently substituting a
// default (§11.4.6 no-guessing).
func LoadConfig(getenv func(string) string, homeDir string) (Config, error) {
	cfg := Config{
		Mode:              firstNonEmpty(getenv(envMode), defaultMode),
		Account:           firstNonEmpty(getenv(envAccount), defaultAccount),
		Bind:              firstNonEmpty(getenv(envBind), defaultBind),
		SessionTTL:        defaultSessionTTL,
		ChallengeTTL:      defaultChallengeTTL,
		RateLimitMax:      defaultRateLimitMax,
		RateLimitWindow:   defaultRateLimitWindow,
		VerifyConcurrency: defaultVerifyConcurrency,
		TrustForwardedFor: defaultTrustForwarded,
	}

	if cfg.Mode != modeSSHKey {
		return Config{}, fmt.Errorf("%s: unsupported mode %q (only %q is supported this release)", envMode, cfg.Mode, modeSSHKey)
	}

	// Principal defaults to the account name; the two are decoupled so a
	// deployment may use a distinct signing identity.
	cfg.Principal = firstNonEmpty(getenv(envPrincipal), cfg.Account)
	if err := validatePrincipal(cfg.Principal); err != nil {
		return Config{}, err
	}

	cfg.AuthorizedKeys = expandTilde(firstNonEmpty(getenv(envAuthorizedKeys), defaultAuthorizedKeys), homeDir)
	cfg.CookieSecretPath = expandTilde(firstNonEmpty(getenv(envCookieSecret), defaultCookieSecretRel), homeDir)

	if v := getenv(envSessionTTL); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil {
			return Config{}, fmt.Errorf("%s: invalid duration %q: %w", envSessionTTL, v, err)
		}
		if d <= 0 {
			return Config{}, fmt.Errorf("%s: must be positive, got %q", envSessionTTL, v)
		}
		cfg.SessionTTL = d
	}

	if v := getenv(envChallengeTTL); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil {
			return Config{}, fmt.Errorf("%s: invalid duration %q: %w", envChallengeTTL, v, err)
		}
		if d <= 0 {
			return Config{}, fmt.Errorf("%s: must be positive, got %q", envChallengeTTL, v)
		}
		cfg.ChallengeTTL = d
	}

	if v := getenv(envRateMax); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil {
			return Config{}, fmt.Errorf("%s: invalid integer %q: %w", envRateMax, v, err)
		}
		if n <= 0 {
			return Config{}, fmt.Errorf("%s: must be positive, got %q", envRateMax, v)
		}
		cfg.RateLimitMax = n
	}

	if v := getenv(envRateWindow); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil {
			return Config{}, fmt.Errorf("%s: invalid duration %q: %w", envRateWindow, v, err)
		}
		if d <= 0 {
			return Config{}, fmt.Errorf("%s: must be positive, got %q", envRateWindow, v)
		}
		cfg.RateLimitWindow = d
	}

	if v := getenv(envVerifyConc); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil {
			return Config{}, fmt.Errorf("%s: invalid integer %q: %w", envVerifyConc, v, err)
		}
		if n <= 0 {
			return Config{}, fmt.Errorf("%s: must be positive, got %q", envVerifyConc, v)
		}
		cfg.VerifyConcurrency = n
	}

	if v := getenv(envTrustForwardedFor); v != "" {
		b, err := strconv.ParseBool(v)
		if err != nil {
			return Config{}, fmt.Errorf("%s: invalid boolean %q: %w", envTrustForwardedFor, v, err)
		}
		cfg.TrustForwardedFor = b
	}

	return cfg, nil
}

// validatePrincipal enforces that the configured signing identity is a safe
// LITERAL for the allowed_signers principals field and the `ssh-keygen -Y
// verify -I` argument. The principals field is an OpenSSH PATTERNS pattern-list
// (§A1-3): a comma splits it into multiple patterns and `*`/`?`/`!` are
// wildcards/negation — any of which would widen who is accepted. It is the
// direct lesson of CVE-2026-35414 (SplitSSHell): never let a non-literal
// identity reach pattern-list matching. We therefore permit only a conservative
// literal charset and reject everything else at config-load (fail closed).
func validatePrincipal(p string) error {
	if p == "" {
		return fmt.Errorf("%s: principal must not be empty", envPrincipal)
	}
	// A leading '-' would make the principal look like a CLI flag if it ever
	// reached an argv position; reject it outright (flag-ambiguity defense,
	// §A4-1) even though '-' is otherwise an allowed literal character.
	if strings.HasPrefix(p, "-") {
		return fmt.Errorf("%s: principal %q must not begin with '-' "+
			"(flag-ambiguity defense, §A4-1)", envPrincipal, p)
	}
	for _, r := range p {
		switch {
		case r >= 'a' && r <= 'z',
			r >= 'A' && r <= 'Z',
			r >= '0' && r <= '9',
			r == '.' || r == '_' || r == '-' || r == '@':
			// allowed literal charset
		default:
			return fmt.Errorf("%s: principal %q contains a disallowed character %q — "+
				"commas, wildcards (*?!), whitespace and other pattern/quote chars are forbidden "+
				"(§A1-3 / CVE-2026-35414); use a literal [A-Za-z0-9._@-] identity", envPrincipal, p, string(r))
		}
	}
	return nil
}

// firstNonEmpty returns a if it is non-empty, else b.
func firstNonEmpty(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

// expandTilde replaces a leading "~/" (or a bare "~") with homeDir. A path
// that does not start with "~" is returned unchanged. If homeDir is empty the
// path is returned unchanged so the caller surfaces a clear error later rather
// than silently writing to a wrong location.
func expandTilde(path, homeDir string) string {
	if homeDir == "" {
		return path
	}
	if path == "~" {
		return homeDir
	}
	if strings.HasPrefix(path, "~/") {
		return homeDir + path[1:]
	}
	return path
}
