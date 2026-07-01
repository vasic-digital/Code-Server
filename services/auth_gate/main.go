package main

import (
	"log"
	"net/http"
	"os"
	"time"

	"github.com/gin-gonic/gin"
)

// main wires the production dependencies and starts the HTTP server. The
// backend is the sshSigVerifier: it verifies an SSH-key challenge-response by
// shelling out to the real `ssh-keygen -Y verify` against an allowed-signers
// file derived from the account's authorized_keys. No password, no cgo, no
// private key is ever read.
func main() {
	// Production runs the gin router in release mode (no debug logging of the
	// one-time challenge / route table; behind Caddy per operator decision).
	gin.SetMode(gin.ReleaseMode)

	home, err := os.UserHomeDir()
	if err != nil {
		// Non-fatal: an unset HOME only affects "~/..." path expansion for the
		// secret + authorized_keys defaults. Surface it; LoadConfig keeps the
		// literal path so the failure is a clear stat error, not a wrong write.
		log.Printf("warning: could not resolve home dir: %v", err)
	}

	cfg, err := LoadConfig(os.Getenv, home)
	if err != nil {
		log.Fatalf("config error: %v", err)
	}

	// §A7-1: require a patched OpenSSH (>= 9.x hard floor). Below the floor we
	// refuse to start (fail closed). Below the CVE-2026-35414-fixed 10.3 floor
	// we WARN but proceed (we already neutralise that CVE via a literal
	// server-controlled principal, §A1-2/§A1-3).
	if maj, min, belowRec, vErr := checkOpenSSHVersion(opensshBanner); vErr != nil {
		log.Fatalf("openssh version check failed: %v", vErr)
	} else {
		log.Printf("observed OpenSSH %d.%d", maj, min)
		if belowRec {
			log.Printf("WARNING: OpenSSH %d.%d is below the recommended %d.%d (CVE-2026-35414 fix); "+
				"helix-auth mitigates via a literal server principal, but upgrading is advised",
				maj, min, sshRecommendedFloorMajor, sshRecommendedFloorMinor)
		}
	}

	// §A7-1 belt-and-suspenders: the verifier execs `ssh-keygen`, which can be a
	// DIFFERENT OpenSSH build from the `ssh` checked above. Enforce the same hard
	// floor against the ssh-keygen tool actually used. It fails closed if
	// ssh-keygen is absent; when the tool is present but does not self-report a
	// version (it has no version flag on some builds, e.g. 9.6p1) we proceed —
	// the `ssh -V` floor above still governs.
	if kmaj, kmin, reported, kErr := checkSSHKeygenVersion(opensshKeygenBanner); kErr != nil {
		log.Fatalf("ssh-keygen version check failed: %v", kErr)
	} else if reported {
		log.Printf("observed ssh-keygen OpenSSH %d.%d", kmaj, kmin)
	} else {
		log.Printf("ssh-keygen present but did not report a version banner; relying on the ssh -V floor check")
	}

	secret, err := loadOrCreateSecret(cfg.CookieSecretPath)
	if err != nil {
		log.Fatalf("cookie secret error: %v", err)
	}

	verifier := newSSHSigVerifier(cfg.AuthorizedKeys, cfg.Principal, 5*time.Second)

	srv, err := NewServer(cfg, secret, verifier, time.Now)
	if err != nil {
		log.Fatalf("server init error: %v", err)
	}

	// The gin engine is the request handler; the hardened http.Server timeouts
	// are preserved (gin adds no TLS/HTTP-3 — those live at the Caddy edge).
	httpServer := &http.Server{
		Addr:              cfg.Bind,
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	// Never log secret material. Account/principal/mode names are configured,
	// non-secret defaults.
	log.Printf("helix-auth listening on %s (mode=%s, account=%s, principal=%s, authorized_keys=%s, session_ttl=%s)",
		cfg.Bind, cfg.Mode, cfg.Account, cfg.Principal, cfg.AuthorizedKeys, cfg.SessionTTL)
	if err := httpServer.ListenAndServe(); err != nil {
		log.Fatalf("server exited: %v", err)
	}
}
