package main

import (
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestMockVerifier exercises the challenge-response test double's accept and
// reject paths.
func TestMockVerifier(t *testing.T) {
	m := &mockVerifier{wantSig: "good-sig"}
	challenge := []byte("Y2hhbGxlbmdl")

	if err := m.Verify(challenge, "good-sig"); err != nil {
		t.Errorf("valid signature rejected: %v", err)
	}
	if err := m.Verify(challenge, "bad-sig"); err == nil {
		t.Error("wrong signature accepted")
	}
	if m.calls != 2 {
		t.Errorf("calls = %d, want 2", m.calls)
	}
}

// TestSSHVerifierRejectsBeforeShellOut proves the cheap fail-fast guards: an
// empty challenge/signature, a non-armored signature, and an oversized
// signature are all rejected WITHOUT any ssh-keygen invocation (they cannot
// depend on the tool being present).
func TestSSHVerifierRejectsBeforeShellOut(t *testing.T) {
	v := newSSHSigVerifier("/nonexistent/authorized_keys", "milosvasic", 0)
	armored := sshSigArmorHeader + "\nx\n-----END SSH SIGNATURE-----"

	cases := []struct {
		name      string
		challenge []byte
		signature string
	}{
		{"empty challenge", nil, armored},
		{"empty signature", []byte("abc"), "   "},
		{"not armored", []byte("abc"), "just some text"},
		{"oversized signature", []byte("abc"), sshSigArmorHeader + strings.Repeat("A", maxSignatureBytes)},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if err := v.Verify(tc.challenge, tc.signature); err == nil {
				t.Fatal("expected rejection, got nil (fail-open)")
			}
		})
	}
}

// TestBuildAllowedSignersHardened proves the defensive conversion (§A3-1/§A1-1):
// each accepted key becomes exactly `<principal> namespaces="<ns>" <type> <b64>`
// with options + comments stripped, and multiple keys become multiple lines.
func TestBuildAllowedSignersHardened(t *testing.T) {
	ed := "AAAAC3NzaC1lZDI1NTE5AAAAIH0tU3aXhL9r1m8k0m1n2o3p4q5r6s7t8u9v0w1x2y3z"
	ecdsa := ecdsaP256Blob()
	authorizedKeys := strings.Join([]string{
		"# a comment line",
		"",
		"ssh-ed25519 " + ed + " milosvasic@host",
		`command="/bin/true",no-pty ecdsa-sha2-nistp256 ` + ecdsa + " restricted-key",
		"   ",
		"not-a-key-line at all",
	}, "\n")

	got := buildAllowedSigners("milosvasic", authorizedKeys)
	lines := nonEmptyLines(got)
	if len(lines) != 2 {
		t.Fatalf("got %d allowed-signers lines, want 2:\n%s", len(lines), got)
	}
	wantEd := `milosvasic namespaces="` + sshSigNamespace + `" ssh-ed25519 ` + ed
	wantEc := `milosvasic namespaces="` + sshSigNamespace + `" ecdsa-sha2-nistp256 ` + ecdsa
	if lines[0] != wantEd {
		t.Errorf("line[0] = %q,\n want %q", lines[0], wantEd)
	}
	if lines[1] != wantEc {
		t.Errorf("line[1] = %q,\n want %q (options must be stripped, namespaces= pinned)", lines[1], wantEc)
	}
	for i, l := range lines {
		if !strings.Contains(l, `namespaces="`+sshSigNamespace+`"`) {
			t.Errorf("line[%d] missing namespaces= pin: %q", i, l)
		}
	}
}

// TestBuildAllowedSignersRejectsDSA proves §A3-2: a ssh-dss (DSA) line is
// skipped even though it is a syntactically valid key line.
func TestBuildAllowedSignersRejectsDSA(t *testing.T) {
	dss := base64.StdEncoding.EncodeToString(sshWireString([]byte("ssh-dss")))
	ak := "ssh-dss " + dss + " legacy-dsa-key\n"
	if got := buildAllowedSigners("milosvasic", ak); strings.TrimSpace(got) != "" {
		t.Errorf("DSA key was NOT rejected: %q", got)
	}
	if _, known := knownKeyTypes["ssh-dss"]; !known {
		t.Error("ssh-dss should be a known (rejected) type")
	}
	if _, accepted := acceptedKeyTypes["ssh-dss"]; accepted {
		t.Error("ssh-dss must NOT be in the accepted allow-list")
	}
}

// TestBuildAllowedSignersRejectsCertAuthority proves §A3-3: a cert-authority
// line is skipped (never converted to a raw allowed-signer).
func TestBuildAllowedSignersRejectsCertAuthority(t *testing.T) {
	ed := "AAAAC3NzaC1lZDI1NTE5AAAAIH0tU3aXhL9r1m8k0m1n2o3p4q5r6s7t8u9v0w1x2y3z"
	ak := "cert-authority ssh-ed25519 " + ed + " ca-key\n"
	if got := buildAllowedSigners("milosvasic", ak); strings.TrimSpace(got) != "" {
		t.Errorf("cert-authority line was NOT rejected: %q", got)
	}
	ak2 := `cert-authority,principals="x" ssh-ed25519 ` + ed + " ca-key\n"
	if got := buildAllowedSigners("milosvasic", ak2); strings.TrimSpace(got) != "" {
		t.Errorf("cert-authority (with options) line was NOT rejected: %q", got)
	}
}

// TestBuildAllowedSignersRejectsWeakRSA proves §A3-2: a <3072-bit RSA key is
// skipped while a >=3072-bit RSA key is accepted.
func TestBuildAllowedSignersRejectsWeakRSA(t *testing.T) {
	weak := rsaBlob(t, 2048)
	strong := rsaBlob(t, 3072)

	if got := buildAllowedSigners("milosvasic", "ssh-rsa "+weak+" weak\n"); strings.TrimSpace(got) != "" {
		t.Errorf("2048-bit RSA key was NOT rejected: %q", got)
	}
	got := buildAllowedSigners("milosvasic", "ssh-rsa "+strong+" strong\n")
	if !strings.Contains(got, "ssh-rsa "+strong) {
		t.Errorf("3072-bit RSA key was NOT accepted: %q", got)
	}
	if bits, det := sshRSABits(strong); !det || bits < minRSABits {
		t.Errorf("sshRSABits(strong) = (%d,%v), want >= %d determinable", bits, det, minRSABits)
	}
}

// TestBuildAllowedSignersEmpty proves an authorized_keys with no usable key
// yields an empty result (the verifier then refuses to build a signers file).
func TestBuildAllowedSignersEmpty(t *testing.T) {
	got := buildAllowedSigners("milosvasic", "# only a comment\n\nnot-a-key\n")
	if strings.TrimSpace(got) != "" {
		t.Errorf("expected empty allowed-signers, got %q", got)
	}
}

// TestAllowedSignersMTimeCache proves review finding [MEDIUM]: allowedSigners()
// caches on the authorized_keys mtime — it does NOT rebuild when unchanged,
// rebuilds when the file changes, and removes the superseded signers file.
func TestAllowedSignersMTimeCache(t *testing.T) {
	dir := t.TempDir()
	ak := filepath.Join(dir, "authorized_keys")
	ed := "AAAAC3NzaC1lZDI1NTE5AAAAIH0tU3aXhL9r1m8k0m1n2o3p4q5r6s7t8u9v0w1x2y3z"
	if err := os.WriteFile(ak, []byte("ssh-ed25519 "+ed+" first-key\n"), 0o600); err != nil {
		t.Fatalf("write authorized_keys: %v", err)
	}
	v := newSSHSigVerifier(ak, "milosvasic", 0)

	p1, _, err := v.allowedSigners()
	if err != nil {
		t.Fatalf("first build: %v", err)
	}
	if _, statErr := os.Stat(p1); statErr != nil {
		t.Fatalf("signers file missing after build: %v", statErr)
	}

	// Unchanged authorized_keys → cache hit → SAME path (no rebuild).
	p2, _, err := v.allowedSigners()
	if err != nil {
		t.Fatalf("second build: %v", err)
	}
	if p2 != p1 {
		t.Errorf("rebuilt despite unchanged authorized_keys: %q != %q", p2, p1)
	}

	// Change authorized_keys AND move its mtime forward → rebuild.
	ecdsa := ecdsaP256Blob()
	if err := os.WriteFile(ak, []byte("ecdsa-sha2-nistp256 "+ecdsa+" second-key\n"), 0o600); err != nil {
		t.Fatalf("rewrite authorized_keys: %v", err)
	}
	bump := time.Now().Add(2 * time.Second)
	if err := os.Chtimes(ak, bump, bump); err != nil {
		t.Fatalf("chtimes: %v", err)
	}
	p3, _, err := v.allowedSigners()
	if err != nil {
		t.Fatalf("rebuild: %v", err)
	}
	if p3 == p1 {
		t.Error("did not rebuild after authorized_keys changed")
	}
	// The superseded signers file must have been removed.
	if _, statErr := os.Stat(p1); !os.IsNotExist(statErr) {
		t.Errorf("old signers file not removed after rebuild: statErr=%v", statErr)
	}
}

func nonEmptyLines(s string) []string {
	var out []string
	for _, l := range strings.Split(s, "\n") {
		if strings.TrimSpace(l) != "" {
			out = append(out, l)
		}
	}
	return out
}

// --- test key-blob helpers: build real SSH wire blobs so the parser is
// exercised against genuine encodings, not hand-crafted base64 ---

func sshWireString(b []byte) []byte {
	out := make([]byte, 4+len(b))
	out[0] = byte(len(b) >> 24)
	out[1] = byte(len(b) >> 16)
	out[2] = byte(len(b) >> 8)
	out[3] = byte(len(b))
	copy(out[4:], b)
	return out
}

func sshWireMPInt(b []byte) []byte {
	i := 0
	for i < len(b) && b[i] == 0 {
		i++
	}
	b = b[i:]
	if len(b) > 0 && b[0]&0x80 != 0 {
		b = append([]byte{0}, b...)
	}
	return sshWireString(b)
}

// rsaBlob generates a real RSA key of the given size and returns its ssh-rsa
// public-blob base64, exactly as an authorized_keys line carries it.
func rsaBlob(t *testing.T, bits int) string {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, bits)
	if err != nil {
		t.Fatalf("rsa gen %d: %v", bits, err)
	}
	blob := sshWireString([]byte("ssh-rsa"))
	blob = append(blob, sshWireMPInt(bigIntBytes(key.E))...)
	blob = append(blob, sshWireMPInt(key.N.Bytes())...)
	return base64.StdEncoding.EncodeToString(blob)
}

// ecdsaP256Blob returns a syntactically valid ecdsa-sha2-nistp256 public blob
// (only base64 validity + type token matter for the conversion allow-list).
func ecdsaP256Blob() string {
	point := make([]byte, 65)
	point[0] = 0x04
	blob := sshWireString([]byte("ecdsa-sha2-nistp256"))
	blob = append(blob, sshWireString([]byte("nistp256"))...)
	blob = append(blob, sshWireString(point)...)
	return base64.StdEncoding.EncodeToString(blob)
}

// bigIntBytes encodes a small non-negative int (RSA public exponent) big-endian.
func bigIntBytes(e int) []byte {
	var b []byte
	for e > 0 {
		b = append([]byte{byte(e & 0xff)}, b...)
		e >>= 8
	}
	if len(b) == 0 {
		b = []byte{0}
	}
	return b
}
