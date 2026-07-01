package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// errAuthFailed is the single, generic authentication-failure error surfaced
// to clients. Keeping it generic avoids user enumeration and timing/response
// oracles (§3.1 security).
var errAuthFailed = errors.New("authentication failed")

// sshSigNamespace is the ssh-keygen signature namespace (`-n`). It scopes a
// signature to this application so a signature produced for another purpose
// (git, email, another service reusing the same key) cannot be replayed here.
// It is enforced THREE ways (defense in depth, §A1-1): the user signs with
// `-n <this>`, we verify with `-n <this>`, AND every allowed_signers line pins
// `namespaces="<this>"`.
const sshSigNamespace = "helixcode-login"

// maxSignatureBytes caps the pasted armored signature accepted before we spawn
// ssh-keygen, to blunt DoS via huge/malformed input (§A4-3).
const maxSignatureBytes = 16 * 1024

// sshSigArmorHeader is the required leading marker of an armored SSH signature.
const sshSigArmorHeader = "-----BEGIN SSH SIGNATURE-----"

// minRSABits is the minimum accepted RSA modulus size (§A3-2).
const minRSABits = 3072

// Verifier authenticates a login by checking that `signature` is a valid SSH
// signature over `challenge`, produced by a key authorized for the
// SERVER-CONFIGURED principal.
//
// The seam deliberately takes NO principal argument: the SSHSIG signature
// carries no identity, so `-I`/allowed_signers principal matching is a verifier
// assertion the SERVER makes — it must never be driven by request input
// (§A1-2, the lesson of CVE-2026-35414 "SplitSSHell"). The concrete
// implementation binds the identity from its own configuration. It returns nil
// on success and a non-nil error on ANY failure, and MUST NEVER read a private
// key nor log secret material.
type Verifier interface {
	Verify(challenge []byte, signature string) error
}

// sshSigVerifier is the PRODUCTION verifier. It shells out to the real
// `ssh-keygen -Y verify` tool (no cgo, no bundled crypto to drift) against an
// allowed-signers file derived from the account's authorized_keys. Only public
// key material is ever read.
type sshSigVerifier struct {
	// authorizedKeysPath is the account's authorized_keys file.
	authorizedKeysPath string
	// principal is the configured signing identity (a validated literal — see
	// validatePrincipal). It is used for `-I` and every allowed_signers line;
	// request input never influences it.
	principal string
	// timeout bounds each ssh-keygen invocation.
	timeout time.Duration

	// mu guards the private-dir + allowed-signers cache below.
	mu sync.Mutex
	// dir is a private 0700 working directory (lazy); the allowed_signers file
	// and per-call signature files live inside it so no attacker-writable /tmp
	// path can be swapped in via symlink/TOCTOU (§A4-2).
	dir string
	// signersPath is the on-disk allowed-signers file (0600). Empty until built.
	signersPath string
	// signersMTime is the authorized_keys mtime the cache was built from; a
	// change triggers a rebuild.
	signersMTime time.Time
}

// newSSHSigVerifier constructs a verifier. A zero timeout uses a safe default.
func newSSHSigVerifier(authorizedKeysPath, principal string, timeout time.Duration) *sshSigVerifier {
	if timeout <= 0 {
		timeout = 5 * time.Second
	}
	return &sshSigVerifier{
		authorizedKeysPath: authorizedKeysPath,
		principal:          principal,
		timeout:            timeout,
	}
}

// Verify checks the armored SSH signature over challenge for the configured
// principal.
//
// Order of operations:
//  1. cheap shape/size checks BEFORE spawning (empty, oversized, not armored);
//  2. (re)build the allowed-signers file from authorized_keys (mtime-cached),
//     inside a private 0700 dir;
//  3. write the armored signature to a private 0600 temp file in that dir;
//  4. run `ssh-keygen -Y verify -n <ns> -f <allowed_signers> -I <principal>
//     -s <sigfile>` feeding the challenge bytes on stdin (the signed message);
//     exit 0 == valid.
//
// Any error path returns the generic errAuthFailed (no enumeration).
func (v *sshSigVerifier) Verify(challenge []byte, signature string) error {
	if len(challenge) == 0 {
		return errAuthFailed
	}
	if len(signature) == 0 || len(signature) > maxSignatureBytes {
		return errAuthFailed
	}
	sig := strings.TrimSpace(signature)
	if !strings.HasPrefix(sig, sshSigArmorHeader) {
		// Not an armored SSH signature; reject before shelling out (§A4-3).
		return errAuthFailed
	}

	signersPath, dir, err := v.allowedSigners()
	if err != nil {
		return errAuthFailed
	}

	sigFile, err := os.CreateTemp(dir, "sig_*.sig")
	if err != nil {
		return errAuthFailed
	}
	sigPath := sigFile.Name()
	defer func() { _ = os.Remove(sigPath) }()
	if chmodErr := sigFile.Chmod(0o600); chmodErr != nil {
		_ = sigFile.Close()
		return errAuthFailed
	}
	if _, wErr := sigFile.WriteString(sig + "\n"); wErr != nil {
		_ = sigFile.Close()
		return errAuthFailed
	}
	if cErr := sigFile.Close(); cErr != nil {
		return errAuthFailed
	}

	if runErr := v.runVerify(signersPath, sigPath, challenge); runErr != nil {
		// §low (concurrent-rebuild TOCTOU): allowedSigners() may have swapped +
		// removed the old signers file between returning it and this exec (a
		// parallel login triggered a rebuild). If the file we pointed at is now
		// gone, that is a spurious failure, not a bad signature — force a fresh
		// rebuild and retry the verify EXACTLY ONCE before returning 401.
		if _, statErr := os.Stat(signersPath); errors.Is(statErr, os.ErrNotExist) {
			if fresh, _, rbErr := v.ensureAllowedSigners(true); rbErr == nil {
				if retryErr := v.runVerify(fresh, sigPath, challenge); retryErr == nil {
					return nil
				}
			}
		}
		return errAuthFailed
	}
	return nil
}

// runVerify execs `ssh-keygen -Y verify` for one attempt against signersPath,
// feeding challenge on stdin. Explicit arg slice — NEVER `sh -c` (§A4-1). The
// signature + allowed_signers are FILES (-s/-f), so no user bytes reach argv;
// the principal is our own validated literal. The challenge (signed message) is
// fed on stdin; ssh-keygen -Y verify has no data-file flag — stdin IS the
// message. stdout/stderr are discarded (they may echo key data). Each call uses
// a fresh timeout context so a retry is not starved by the first attempt.
func (v *sshSigVerifier) runVerify(signersPath, sigPath string, challenge []byte) error {
	ctx, cancel := context.WithTimeout(context.Background(), v.timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "ssh-keygen",
		"-Y", "verify",
		"-n", sshSigNamespace,
		"-f", signersPath,
		"-I", v.principal,
		"-s", sigPath,
	)
	cmd.Stdin = bytes.NewReader(challenge)
	cmd.Stdout = nil
	cmd.Stderr = nil
	return cmd.Run()
}

// allowedSigners returns the path to a current allowed-signers file (and the
// private dir it lives in), rebuilding it (0600) whenever authorized_keys is
// missing from cache or its mtime moved. Safe for concurrent use.
func (v *sshSigVerifier) allowedSigners() (signersPath, dir string, err error) {
	return v.ensureAllowedSigners(false)
}

// ensureAllowedSigners is allowedSigners with an explicit force flag. When
// force is true the mtime cache is bypassed and the file is rebuilt
// unconditionally (used by the Verify ENOENT retry path). Safe for concurrent
// use.
func (v *sshSigVerifier) ensureAllowedSigners(force bool) (signersPath, dir string, err error) {
	v.mu.Lock()
	defer v.mu.Unlock()

	if v.dir == "" {
		d, mkErr := os.MkdirTemp("", "helix_auth_*")
		if mkErr != nil {
			return "", "", fmt.Errorf("create private dir: %w", mkErr)
		}
		// MkdirTemp already creates 0700; make it explicit against a lax umask.
		if chErr := os.Chmod(d, 0o700); chErr != nil {
			_ = os.RemoveAll(d)
			return "", "", chErr
		}
		v.dir = d
	}

	info, err := os.Stat(v.authorizedKeysPath)
	if err != nil {
		return "", "", fmt.Errorf("stat authorized_keys: %w", err)
	}

	if !force && v.signersPath != "" && info.ModTime().Equal(v.signersMTime) {
		if _, statErr := os.Stat(v.signersPath); statErr == nil {
			return v.signersPath, v.dir, nil
		}
	}

	raw, err := os.ReadFile(v.authorizedKeysPath)
	if err != nil {
		return "", "", fmt.Errorf("read authorized_keys: %w", err)
	}
	content := buildAllowedSigners(v.principal, string(raw))
	if strings.TrimSpace(content) == "" {
		return "", "", errors.New("no acceptable public keys in authorized_keys")
	}

	f, err := os.CreateTemp(v.dir, "allowed_signers_*")
	if err != nil {
		return "", "", fmt.Errorf("create allowed_signers: %w", err)
	}
	tmp := f.Name()
	if chErr := f.Chmod(0o600); chErr != nil {
		_ = f.Close()
		_ = os.Remove(tmp)
		return "", "", chErr
	}
	if _, wErr := f.WriteString(content); wErr != nil {
		_ = f.Close()
		_ = os.Remove(tmp)
		return "", "", wErr
	}
	if cErr := f.Close(); cErr != nil {
		_ = os.Remove(tmp)
		return "", "", cErr
	}

	// Swap in the fresh file and drop the old one.
	old := v.signersPath
	v.signersPath = tmp
	v.signersMTime = info.ModTime()
	if old != "" && old != tmp {
		_ = os.Remove(old)
	}
	return v.signersPath, v.dir, nil
}

// acceptedKeyTypes is the allow-list of signer key types (§A3-2). ssh-dss (DSA)
// and any unknown type are deliberately ABSENT → rejected. ssh-rsa is accepted
// only when its modulus is >= minRSABits (checked separately).
var acceptedKeyTypes = map[string]struct{}{
	"ssh-ed25519":                        {},
	"sk-ssh-ed25519@openssh.com":         {},
	"sk-ecdsa-sha2-nistp256@openssh.com": {},
	"ecdsa-sha2-nistp256":                {},
	"ecdsa-sha2-nistp384":                {},
	"ecdsa-sha2-nistp521":                {},
	"ssh-rsa":                            {},
}

// knownKeyTypes is the universe of key-type tokens (accepted PLUS explicitly
// rejected) used to locate the keytype field and thus the options boundary in
// an authorized_keys line.
var knownKeyTypes = map[string]struct{}{
	"ssh-ed25519":                        {},
	"sk-ssh-ed25519@openssh.com":         {},
	"sk-ecdsa-sha2-nistp256@openssh.com": {},
	"ecdsa-sha2-nistp256":                {},
	"ecdsa-sha2-nistp384":                {},
	"ecdsa-sha2-nistp521":                {},
	"ssh-rsa":                            {},
	"ssh-dss":                            {}, // known but REJECTED (weak DSA)
}

// buildAllowedSigners converts an authorized_keys file body into an
// allowed-signers file body for the given principal. Each ACCEPTED key line
// becomes exactly:
//
//	<principal> namespaces="<ns>" <keytype> <base64>
//
// It PARSES and REBUILDS (never copies): options (command=, restrict, from=,
// ...) and the trailing comment are dropped entirely — this closes
// comment/option/whitespace-injection into the generated line (§A3-1). Lines
// carrying cert-authority (§A3-3), the ssh-dss type or any unknown type
// (§A3-2), an under-strength RSA key, or a non-base64 blob are skipped. Only
// public key material is emitted; no private material is touched.
func buildAllowedSigners(principal, authorizedKeys string) string {
	var b strings.Builder
	for _, line := range strings.Split(authorizedKeys, "\n") {
		keyType, keyData, ok := parseAuthorizedKeyLine(line)
		if !ok {
			continue
		}
		b.WriteString(principal)
		b.WriteString(` namespaces="`)
		b.WriteString(sshSigNamespace)
		b.WriteString(`" `)
		b.WriteString(keyType)
		b.WriteByte(' ')
		b.WriteString(keyData)
		b.WriteByte('\n')
	}
	return b.String()
}

// parseAuthorizedKeyLine defensively extracts the (keytype, keydata) of one
// acceptable authorized_keys line, or ok=false to skip it. It rejects
// cert-authority lines, the ssh-dss type, unknown types, under-strength RSA,
// and malformed base64.
func parseAuthorizedKeyLine(line string) (keyType, keyData string, ok bool) {
	trimmed := strings.TrimSpace(line)
	if trimmed == "" || strings.HasPrefix(trimmed, "#") {
		return "", "", false
	}
	fields := strings.Fields(trimmed)

	// Locate the keytype field; everything before it is the options blob.
	idx := -1
	for i, f := range fields {
		if _, known := knownKeyTypes[f]; known {
			idx = i
			break
		}
	}
	if idx < 0 || idx+1 >= len(fields) {
		return "", "", false
	}

	// §A3-3: reject a cert-authority signer (would trust every cert that CA
	// signs). cert-authority appears in the option blob before the keytype.
	for _, opt := range fields[:idx] {
		if strings.Contains(strings.ToLower(opt), "cert-authority") {
			return "", "", false
		}
	}

	kt := fields[idx]
	kd := fields[idx+1]
	if _, err := base64.StdEncoding.DecodeString(kd); err != nil {
		return "", "", false
	}
	if _, accepted := acceptedKeyTypes[kt]; !accepted {
		// §A3-2: rejects ssh-dss and any unknown type.
		return "", "", false
	}
	if kt == "ssh-rsa" {
		bits, det := sshRSABits(kd)
		if !det || bits < minRSABits {
			// Under-strength or unparseable RSA → reject (§A3-2).
			return "", "", false
		}
	}
	return kt, kd, true
}

// sshRSABits parses an ssh-rsa public-key blob (base64) and returns the modulus
// bit length. det is false when the blob is not a well-formed ssh-rsa key.
// Wire format: string "ssh-rsa" | mpint e | mpint n.
func sshRSABits(b64 string) (bits int, det bool) {
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return 0, false
	}
	r := bytes.NewReader(raw)
	typ, ok := readSSHString(r)
	if !ok || string(typ) != "ssh-rsa" {
		return 0, false
	}
	if _, ok := readSSHString(r); !ok { // public exponent e
		return 0, false
	}
	n, ok := readSSHString(r) // modulus n
	if !ok {
		return 0, false
	}
	// mpint may carry a leading 0x00 when the MSB is set; strip leading zeros.
	i := 0
	for i < len(n) && n[i] == 0 {
		i++
	}
	n = n[i:]
	if len(n) == 0 {
		return 0, false
	}
	return (len(n)-1)*8 + bitLenByte(n[0]), true
}

// readSSHString reads a uint32-length-prefixed byte string from r (SSH wire
// format), with a sanity cap to reject absurd lengths.
func readSSHString(r *bytes.Reader) ([]byte, bool) {
	var lb [4]byte
	if _, err := io.ReadFull(r, lb[:]); err != nil {
		return nil, false
	}
	n := binary.BigEndian.Uint32(lb[:])
	if n > 1<<20 {
		return nil, false
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(r, buf); err != nil {
		return nil, false
	}
	return buf, true
}

// bitLenByte returns the position of the highest set bit in b (0 for b==0).
func bitLenByte(b byte) int {
	n := 0
	for b > 0 {
		n++
		b >>= 1
	}
	return n
}
