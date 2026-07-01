package main

import (
	"errors"
	"testing"
)

func TestParseOpenSSHVersion(t *testing.T) {
	cases := []struct {
		banner           string
		wantMaj, wantMin int
		wantOK           bool
	}{
		{"OpenSSH_9.6p1, OpenSSL 3.0.13 30 Jan 2024", 9, 6, true},
		{"OpenSSH_10.3p2 Debian-1, OpenSSL 3.3.1", 10, 3, true},
		{"OpenSSH_8.9p1 Ubuntu-3ubuntu0.10, OpenSSL 3.0.2", 8, 9, true},
		{"OpenSSH_10, LibreSSL 3.9", 10, 0, true},
		{"OpenSSH_9.9p2", 9, 9, true},
		{"garbage without the token", 0, 0, false},
		{"", 0, 0, false},
	}
	for _, c := range cases {
		maj, min, ok := parseOpenSSHVersion(c.banner)
		if ok != c.wantOK || maj != c.wantMaj || min != c.wantMin {
			t.Errorf("parseOpenSSHVersion(%q) = (%d,%d,%v), want (%d,%d,%v)",
				c.banner, maj, min, ok, c.wantMaj, c.wantMin, c.wantOK)
		}
	}
}

func TestFloorHelpers(t *testing.T) {
	// Hard floor is 9.x.
	if meetsHardFloor(8, 9) {
		t.Error("8.9 wrongly meets the 9.x hard floor")
	}
	if !meetsHardFloor(9, 0) || !meetsHardFloor(10, 3) {
		t.Error("9.0 / 10.3 should meet the hard floor")
	}
	// Recommended floor is 10.3.
	if meetsRecommendedFloor(10, 2) || meetsRecommendedFloor(9, 9) {
		t.Error("10.2 / 9.9 wrongly meet the 10.3 recommended floor")
	}
	if !meetsRecommendedFloor(10, 3) || !meetsRecommendedFloor(11, 0) {
		t.Error("10.3 / 11.0 should meet the recommended floor")
	}
}

func TestCheckOpenSSHVersion(t *testing.T) {
	// Below hard floor → error (fail closed).
	if _, _, _, err := checkOpenSSHVersion(func() (string, error) {
		return "OpenSSH_8.9p1, OpenSSL 3.0.2", nil
	}); err == nil {
		t.Error("8.9 should fail the hard floor")
	}

	// Between hard and recommended floor → ok but belowRecommended=true.
	maj, min, belowRec, err := checkOpenSSHVersion(func() (string, error) {
		return "OpenSSH_9.6p1, OpenSSL 3.0.13", nil
	})
	if err != nil {
		t.Fatalf("9.6 unexpected error: %v", err)
	}
	if maj != 9 || min != 6 || !belowRec {
		t.Errorf("9.6 → (%d,%d,belowRec=%v), want (9,6,true)", maj, min, belowRec)
	}

	// At/above recommended floor → ok, belowRecommended=false.
	_, _, belowRec, err = checkOpenSSHVersion(func() (string, error) {
		return "OpenSSH_10.3p2 Debian-1", nil
	})
	if err != nil || belowRec {
		t.Errorf("10.3 → belowRec=%v err=%v, want false,nil", belowRec, err)
	}

	// Unreadable banner → error.
	if _, _, _, err := checkOpenSSHVersion(func() (string, error) {
		return "", errors.New("exec failed")
	}); err == nil {
		t.Error("banner fetch error should propagate")
	}

	// Unparseable banner → error.
	if _, _, _, err := checkOpenSSHVersion(func() (string, error) {
		return "not an openssh banner", nil
	}); err == nil {
		t.Error("unparseable banner should error")
	}
}

// TestCheckSSHKeygenVersion proves the [NIT] ssh-keygen version floor: the tool
// actually exec'd is checked against the 9.x hard floor when it self-reports a
// version, present-but-no-version is tolerated (ssh-keygen has no version flag
// on 9.6p1), and a missing/unrunnable tool fails closed.
func TestCheckSSHKeygenVersion(t *testing.T) {
	// Below the hard floor → error (fail closed).
	if _, _, _, err := checkSSHKeygenVersion(func() (string, error) {
		return "OpenSSH_8.9p1, OpenSSL 3.0.2", nil
	}); err == nil {
		t.Error("ssh-keygen 8.9 should fail the 9.x hard floor")
	}

	// At/above the hard floor with a version token → reported, no error.
	maj, min, reported, err := checkSSHKeygenVersion(func() (string, error) {
		return "OpenSSH_9.6p1, OpenSSL 3.5.4", nil
	})
	if err != nil || !reported || maj != 9 || min != 6 {
		t.Errorf("ssh-keygen 9.6 → (%d,%d,reported=%v,err=%v), want (9,6,true,nil)", maj, min, reported, err)
	}

	// Present but no OpenSSH_x.y token (real 9.6p1 usage banner) → reported=false,
	// no error: the tool works, it simply does not self-report a version.
	_, _, reported, err = checkSSHKeygenVersion(func() (string, error) {
		return "usage: ssh-keygen [-q] [-a rounds] [-b bits] ...", nil
	})
	if err != nil || reported {
		t.Errorf("no-version banner → reported=%v err=%v, want false,nil", reported, err)
	}

	// Tool missing / unrunnable → fail closed.
	if _, _, _, err := checkSSHKeygenVersion(func() (string, error) {
		return "", errors.New("ssh-keygen not found")
	}); err == nil {
		t.Error("missing ssh-keygen should fail closed")
	}
}
