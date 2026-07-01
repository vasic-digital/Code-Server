package main

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// OpenSSH version floors (§A7-1). The HARD floor refuses startup below it
// (fail closed); the RECOMMENDED floor is the CVE-2026-35414 "SplitSSHell" fix
// (OpenSSH 10.3) — below it we log a warning but still start, because
// helix-auth already neutralises that CVE's pattern-list hazard by using a
// literal, server-controlled principal (validatePrincipal + §A1-2/A1-3).
const (
	sshHardFloorMajor        = 9
	sshRecommendedFloorMajor = 10
	sshRecommendedFloorMinor = 3
)

// errNoOpenSSHVersion means the `OpenSSH_X.Y` token was not found in the output.
var errNoOpenSSHVersion = errors.New("no OpenSSH version token found")

// parseOpenSSHVersion extracts the major/minor version from an `ssh -V` /
// `ssh-keygen` banner such as:
//
//	OpenSSH_9.6p1, OpenSSL 3.0.13 30 Jan 2024
//	OpenSSH_10.3p2 Debian-1, ...
//
// It returns (major, minor) and ok=true when the `OpenSSH_<major>.<minor>`
// token is present.
func parseOpenSSHVersion(banner string) (major, minor int, ok bool) {
	const marker = "OpenSSH_"
	i := strings.Index(banner, marker)
	if i < 0 {
		return 0, 0, false
	}
	rest := banner[i+len(marker):]

	// major = leading digits.
	j := 0
	for j < len(rest) && rest[j] >= '0' && rest[j] <= '9' {
		j++
	}
	if j == 0 {
		return 0, 0, false
	}
	maj, err := strconv.Atoi(rest[:j])
	if err != nil {
		return 0, 0, false
	}
	if j >= len(rest) || rest[j] != '.' {
		return maj, 0, true // e.g. "OpenSSH_10" with no minor
	}
	rest = rest[j+1:]

	// minor = leading digits after the dot.
	k := 0
	for k < len(rest) && rest[k] >= '0' && rest[k] <= '9' {
		k++
	}
	if k == 0 {
		return maj, 0, true
	}
	min, err := strconv.Atoi(rest[:k])
	if err != nil {
		return maj, 0, true
	}
	return maj, min, true
}

// meetsHardFloor reports whether (major, minor) is at or above the hard floor.
func meetsHardFloor(major, minor int) bool {
	return major >= sshHardFloorMajor
}

// meetsRecommendedFloor reports whether (major, minor) is at or above the
// recommended (CVE-2026-35414-fixed) floor.
func meetsRecommendedFloor(major, minor int) bool {
	if major != sshRecommendedFloorMajor {
		return major > sshRecommendedFloorMajor
	}
	return minor >= sshRecommendedFloorMinor
}

// checkOpenSSHVersion parses the banner returned by getBanner and enforces the
// hard floor (fail closed). It returns the parsed (major, minor) and a non-nil
// error when the banner is unreadable/unparseable OR below the hard floor.
// belowRecommended is true when parsing succeeded but the version is under the
// recommended floor (caller logs a warning). getBanner is injected so the
// enforcement logic is unit-testable without exec.
func checkOpenSSHVersion(getBanner func() (string, error)) (major, minor int, belowRecommended bool, err error) {
	banner, gErr := getBanner()
	if gErr != nil {
		return 0, 0, false, fmt.Errorf("could not determine OpenSSH version: %w", gErr)
	}
	maj, min, ok := parseOpenSSHVersion(banner)
	if !ok {
		return 0, 0, false, fmt.Errorf("%w in %q", errNoOpenSSHVersion, strings.TrimSpace(banner))
	}
	if !meetsHardFloor(maj, min) {
		return maj, min, true, fmt.Errorf("OpenSSH %d.%d is below the required minimum %d.x (fail closed, §A7-1)",
			maj, min, sshHardFloorMajor)
	}
	return maj, min, !meetsRecommendedFloor(maj, min), nil
}

// opensshBanner runs `ssh -V` and returns its banner. OpenSSH prints the
// version to STDERR, so we capture combined output.
func opensshBanner() (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "ssh", "-V").CombinedOutput()
	if err != nil {
		// `ssh -V` exits 0 on all supported versions; even on a non-zero exit
		// the banner may still be on stderr in `out`, so prefer it when present.
		if len(strings.TrimSpace(string(out))) > 0 {
			return string(out), nil
		}
		return "", err
	}
	return string(out), nil
}

// checkSSHKeygenVersion enforces the hard floor against the version of the
// `ssh-keygen` tool ACTUALLY exec'd by the verifier — not just `ssh -V`, which
// reports the sibling `ssh` binary and can drift from `ssh-keygen` on a
// mixed install. getBanner is injected so the logic is unit-testable.
//
// Semantics (§11.4.6, no-guessing / §11.4.1, no FAIL-bluff):
//   - getBanner error (tool missing / unrunnable) -> non-nil err: the verifier
//     depends on ssh-keygen, so this fails closed at startup.
//   - banner carries an OpenSSH_x.y token below the hard floor -> non-nil err
//     (fail closed), reported=true.
//   - banner carries a token at/above the floor -> reported=true, no err.
//   - banner present but WITHOUT a version token (ssh-keygen has no version
//     flag on some builds, e.g. OpenSSH 9.6p1) -> reported=false, NO err: the
//     tool is present and runnable but simply does not self-report a version,
//     which is not a defect. The `ssh -V` hard-floor check still governs.
func checkSSHKeygenVersion(getBanner func() (string, error)) (major, minor int, reported bool, err error) {
	banner, gErr := getBanner()
	if gErr != nil {
		return 0, 0, false, fmt.Errorf("could not run ssh-keygen: %w", gErr)
	}
	maj, min, ok := parseOpenSSHVersion(banner)
	if !ok {
		// Tool present but no OpenSSH_x.y token in its output.
		return 0, 0, false, nil
	}
	if !meetsHardFloor(maj, min) {
		return maj, min, true, fmt.Errorf("ssh-keygen OpenSSH %d.%d is below the required minimum %d.x (fail closed, §A7-1)",
			maj, min, sshHardFloorMajor)
	}
	return maj, min, true, nil
}

// opensshKeygenBanner obtains a banner from the `ssh-keygen` binary that will
// actually be exec'd. ssh-keygen has NO dedicated version flag, so we (1) fail
// closed if the binary is absent from PATH (the verifier cannot work without
// it), then (2) invoke it with an invalid, side-effect-free query so it prints
// its usage/error banner. On builds that embed the OpenSSH_x.y token in that
// banner it is parsed; on builds that do not (OpenSSH 9.6p1), the caller treats
// the version as unreported. The `-Q <bogus>` form writes NOTHING to disk and
// generates no keys — it only prints an "unsupported query" message and exits.
func opensshKeygenBanner() (string, error) {
	if _, err := exec.LookPath("ssh-keygen"); err != nil {
		return "", fmt.Errorf("ssh-keygen not found on PATH: %w", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	// Combined output: the banner (if any) lands on stderr; a non-zero exit is
	// expected for the bogus query and is not itself an error for us.
	out, _ := exec.CommandContext(ctx, "ssh-keygen", "-Q", "helix-version-probe").CombinedOutput()
	return string(out), nil
}
