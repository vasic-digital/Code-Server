package main

// mockVerifier is a configurable test double for the challenge-response
// Verifier interface. Per §11.4.27 mocks live ONLY in unit-test sources — this
// file is _test.go, so it never compiles into the production binary.
//
// It accepts when signature == wantSig; any other value fails with
// errAuthFailed. Setting forceErr makes every Verify return that error
// regardless (used to model a backend outage / generic-error path). It records
// the last challenge seen for assertion; the signature is intentionally NOT
// retained beyond the match, mirroring the production no-store rule. Note the
// seam takes NO principal — identity is bound server-side, never from the
// request (§A1-2).
type mockVerifier struct {
	wantSig  string
	forceErr error

	lastChallenge []byte
	calls         int
}

func (m *mockVerifier) Verify(challenge []byte, signature string) error {
	m.calls++
	m.lastChallenge = append([]byte(nil), challenge...)
	if m.forceErr != nil {
		return m.forceErr
	}
	if signature == m.wantSig {
		return nil
	}
	return errAuthFailed
}

// acceptAllVerifier accepts any challenge/signature — handy for isolating
// cookie/session behaviour in handler tests.
type acceptAllVerifier struct{}

func (acceptAllVerifier) Verify(_ []byte, _ string) error { return nil }

// blockingVerifier signals when a Verify call has started (holding a spawn-
// ceiling slot) and blocks until released, so a test can prove the global
// concurrent-verify semaphore caps concurrency. It accepts on release.
type blockingVerifier struct {
	entered chan struct{} // Verify sends here once it is inside (slot held)
	release chan struct{} // Verify returns after this is closed/signalled
}

func (b *blockingVerifier) Verify(_ []byte, _ string) error {
	b.entered <- struct{}{}
	<-b.release
	return nil
}
