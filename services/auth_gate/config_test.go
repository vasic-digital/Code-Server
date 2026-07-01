package main

import (
	"testing"
	"time"
)

// mapEnv returns a getenv-style function backed by m.
func mapEnv(m map[string]string) func(string) string {
	return func(k string) string { return m[k] }
}

func TestLoadConfigDefaults(t *testing.T) {
	cfg, err := LoadConfig(mapEnv(nil), "/home/tester")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.Mode != modeSSHKey {
		t.Errorf("Mode = %q, want %q", cfg.Mode, modeSSHKey)
	}
	if cfg.Account != defaultAccount {
		t.Errorf("Account = %q, want %q", cfg.Account, defaultAccount)
	}
	if cfg.Principal != defaultAccount {
		t.Errorf("Principal = %q, want default-to-account %q", cfg.Principal, defaultAccount)
	}
	if want := "/home/tester/.ssh/authorized_keys"; cfg.AuthorizedKeys != want {
		t.Errorf("AuthorizedKeys = %q, want %q", cfg.AuthorizedKeys, want)
	}
	if cfg.Bind != defaultBind {
		t.Errorf("Bind = %q, want %q", cfg.Bind, defaultBind)
	}
	if cfg.SessionTTL != defaultSessionTTL {
		t.Errorf("SessionTTL = %v, want %v", cfg.SessionTTL, defaultSessionTTL)
	}
	if cfg.ChallengeTTL != defaultChallengeTTL {
		t.Errorf("ChallengeTTL = %v, want %v", cfg.ChallengeTTL, defaultChallengeTTL)
	}
	if cfg.RateLimitMax != defaultRateLimitMax {
		t.Errorf("RateLimitMax = %d, want %d", cfg.RateLimitMax, defaultRateLimitMax)
	}
	if cfg.RateLimitWindow != defaultRateLimitWindow {
		t.Errorf("RateLimitWindow = %v, want %v", cfg.RateLimitWindow, defaultRateLimitWindow)
	}
	if cfg.VerifyConcurrency != defaultVerifyConcurrency {
		t.Errorf("VerifyConcurrency = %d, want %d", cfg.VerifyConcurrency, defaultVerifyConcurrency)
	}
	if cfg.TrustForwardedFor != false {
		t.Errorf("TrustForwardedFor = %v, want false", cfg.TrustForwardedFor)
	}
	if want := "/home/tester/.config/helixcode/cookie_secret"; cfg.CookieSecretPath != want {
		t.Errorf("CookieSecretPath = %q, want %q", cfg.CookieSecretPath, want)
	}
}

func TestLoadConfigOverrides(t *testing.T) {
	env := map[string]string{
		envMode:              "sshkey",
		envAccount:           "alice",
		envPrincipal:         "alice-signer",
		envAuthorizedKeys:    "/etc/helix/authorized_keys",
		envBind:              "127.0.0.1:9999",
		envSessionTTL:        "2h30m",
		envChallengeTTL:      "90s",
		envCookieSecret:      "/etc/helix/secret",
		envRateMax:           "10",
		envRateWindow:        "30s",
		envVerifyConc:        "8",
		envTrustForwardedFor: "true",
	}
	cfg, err := LoadConfig(mapEnv(env), "/home/tester")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.Account != "alice" {
		t.Errorf("Account = %q, want alice", cfg.Account)
	}
	if cfg.Principal != "alice-signer" {
		t.Errorf("Principal = %q, want alice-signer", cfg.Principal)
	}
	if cfg.AuthorizedKeys != "/etc/helix/authorized_keys" {
		t.Errorf("AuthorizedKeys = %q (absolute path must not be tilde-touched)", cfg.AuthorizedKeys)
	}
	if cfg.Bind != "127.0.0.1:9999" {
		t.Errorf("Bind = %q", cfg.Bind)
	}
	if cfg.SessionTTL != 2*time.Hour+30*time.Minute {
		t.Errorf("SessionTTL = %v", cfg.SessionTTL)
	}
	if cfg.ChallengeTTL != 90*time.Second {
		t.Errorf("ChallengeTTL = %v", cfg.ChallengeTTL)
	}
	if cfg.CookieSecretPath != "/etc/helix/secret" {
		t.Errorf("CookieSecretPath = %q (tilde expansion must not touch absolute paths)", cfg.CookieSecretPath)
	}
	if cfg.RateLimitMax != 10 {
		t.Errorf("RateLimitMax = %d", cfg.RateLimitMax)
	}
	if cfg.RateLimitWindow != 30*time.Second {
		t.Errorf("RateLimitWindow = %v", cfg.RateLimitWindow)
	}
	if cfg.VerifyConcurrency != 8 {
		t.Errorf("VerifyConcurrency = %d, want 8", cfg.VerifyConcurrency)
	}
	if !cfg.TrustForwardedFor {
		t.Errorf("TrustForwardedFor = false, want true")
	}
}

func TestLoadConfigPrincipalDefaultsToAccount(t *testing.T) {
	cfg, err := LoadConfig(mapEnv(map[string]string{envAccount: "bob"}), "/home/tester")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.Principal != "bob" {
		t.Errorf("Principal = %q, want it to default to the account bob", cfg.Principal)
	}
}

func TestLoadConfigInvalid(t *testing.T) {
	cases := []struct {
		name string
		env  map[string]string
	}{
		{"unsupported mode", map[string]string{envMode: "pam"}},
		{"unknown mode", map[string]string{envMode: "password"}},
		{"bad ttl", map[string]string{envSessionTTL: "not-a-duration"}},
		{"zero ttl", map[string]string{envSessionTTL: "0s"}},
		{"negative ttl", map[string]string{envSessionTTL: "-5m"}},
		{"bad challenge ttl", map[string]string{envChallengeTTL: "nope"}},
		{"zero challenge ttl", map[string]string{envChallengeTTL: "0s"}},
		{"bad rate max", map[string]string{envRateMax: "abc"}},
		{"zero rate max", map[string]string{envRateMax: "0"}},
		{"negative rate max", map[string]string{envRateMax: "-1"}},
		{"bad rate window", map[string]string{envRateWindow: "10"}}, // no unit
		{"zero rate window", map[string]string{envRateWindow: "0s"}},
		{"bad bool", map[string]string{envTrustForwardedFor: "yesish"}},
		// §A1-3: a principal with a comma / wildcard / whitespace is a
		// pattern-list hazard (CVE-2026-35414) and must be rejected at load.
		{"principal comma+wildcard", map[string]string{envPrincipal: "a,*"}},
		{"principal comma", map[string]string{envPrincipal: "deploy,root"}},
		{"principal wildcard", map[string]string{envPrincipal: "adm*"}},
		{"principal negation", map[string]string{envPrincipal: "!root"}},
		{"principal question", map[string]string{envPrincipal: "user?"}},
		{"principal whitespace", map[string]string{envPrincipal: "a b"}},
		{"principal quote", map[string]string{envPrincipal: `a"b`}},
		// §A4-1: a leading '-' could be read as a CLI flag → rejected at load.
		{"principal leading dash", map[string]string{envPrincipal: "-milosvasic"}},
		{"principal bare dash", map[string]string{envPrincipal: "-"}},
		// VerifyConcurrency must be a positive integer.
		{"bad verify concurrency", map[string]string{envVerifyConc: "abc"}},
		{"zero verify concurrency", map[string]string{envVerifyConc: "0"}},
		{"negative verify concurrency", map[string]string{envVerifyConc: "-2"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := LoadConfig(mapEnv(tc.env), "/home/tester"); err == nil {
				t.Fatalf("expected error for %s, got nil", tc.name)
			}
		})
	}
}

// TestValidatePrincipal proves the literal-principal charset gate directly.
func TestValidatePrincipal(t *testing.T) {
	good := []string{"milosvasic", "milosvasic@vasic.digital", "svc_deploy-01", "a.b.c"}
	for _, p := range good {
		if err := validatePrincipal(p); err != nil {
			t.Errorf("validatePrincipal(%q) = %v, want nil", p, err)
		}
	}
	bad := []string{"", "a,b", "a,*", "adm*", "!root", "user?", "a b", `a"b`, "a\tb", "a|b", "a/b",
		"-milosvasic", "-", "-I"} // leading '-' is flag-ambiguous (§A4-1)
	for _, p := range bad {
		if err := validatePrincipal(p); err == nil {
			t.Errorf("validatePrincipal(%q) = nil, want error", p)
		}
	}
	// A non-leading dash is still allowed (e.g. svc_deploy-01).
	if err := validatePrincipal("svc-01"); err != nil {
		t.Errorf("validatePrincipal(%q) = %v, want nil (non-leading dash is fine)", "svc-01", err)
	}
}

func TestExpandTilde(t *testing.T) {
	cases := []struct {
		path, home, want string
	}{
		{"~/.config/x", "/home/u", "/home/u/.config/x"},
		{"~", "/home/u", "/home/u"},
		{"/abs/path", "/home/u", "/abs/path"},
		{"relative/path", "/home/u", "relative/path"},
		{"~/.config/x", "", "~/.config/x"},  // no home → unchanged
		{"~notme/x", "/home/u", "~notme/x"}, // "~user" form is not expanded
	}
	for _, c := range cases {
		if got := expandTilde(c.path, c.home); got != c.want {
			t.Errorf("expandTilde(%q, %q) = %q, want %q", c.path, c.home, got, c.want)
		}
	}
}
