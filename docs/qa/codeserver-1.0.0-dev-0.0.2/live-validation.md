# HelixCode codeserver-1.0.0-dev-0.0.2 — live validation evidence

**Revision:** 1 · **Last modified:** 2026-07-01T00:00:00Z

Full §11.4.169 test-type matrix run LIVE against the freshly-installed stack
(scripts/install.sh) on the host. Run id: 20260701T080517Z-1627662.

## Aggregate
```
=== AGGREGATE: PASS=14 FAIL=0  (evidence: qa-results/run_all/20260701T080517Z-1627662) ===
PASS: full §11.4.169 test-type matrix green
```

## Per-suite verdicts
```
tls_letsencrypt    PASS   === SUMMARY tls_letsencrypt: PASS=8 FAIL=0 SKIP=0 TOTAL=8 ===
security           PASS   === SUMMARY security: PASS=7 FAIL=0 SKIP=0 TOTAL=7 ===
stress_chaos       PASS   === SUMMARY stress_chaos: PASS=3 FAIL=0 SKIP=0 TOTAL=3 ===
integration        PASS   === SUMMARY integration: PASS=4 FAIL=0 SKIP=0 TOTAL=4 ===
e2e                PASS   === SUMMARY e2e: PASS=4 FAIL=0 SKIP=0 TOTAL=4 ===
full_automation    PASS   === SUMMARY full_automation: PASS=1 FAIL=0 SKIP=0 TOTAL=1 ===
concurrency        PASS   === SUMMARY concurrency: PASS=7 FAIL=0 SKIP=1 TOTAL=8 ===
race               PASS   === SUMMARY race: PASS=2 FAIL=0 SKIP=0 TOTAL=2 ===
load               PASS   === SUMMARY load: PASS=3 FAIL=0 SKIP=0 TOTAL=3 ===
memory             PASS   === SUMMARY memory: PASS=3 FAIL=0 SKIP=0 TOTAL=3 ===
benchmark          PASS   === SUMMARY benchmark: PASS=3 FAIL=0 SKIP=1 TOTAL=4 ===
unit               PASS   === SUMMARY unit: PASS=5 FAIL=0 SKIP=0 TOTAL=5 ===
helixqa            PASS   === SUMMARY helixqa: PASS=4 FAIL=0 SKIP=1 TOTAL=5 ===
challenges         PASS   === SUMMARY challenges: PASS=5 FAIL=0 SKIP=0 TOTAL=5 ===
```
