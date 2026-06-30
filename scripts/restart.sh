#!/usr/bin/env bash
# scripts/restart.sh — restart the HelixCode stack (stop, then start).
#
# Purpose:      Convenience wrapper to cycle the stack (e.g. after editing
#               deploy/.env to change PROJECTS or the password).
# Usage:        scripts/restart.sh
# Inputs:       deploy/.env
# Outputs:      freshly restarted containers
# Side-effects: see scripts/stop.sh + scripts/start.sh
# Dependencies: bash; scripts/stop.sh; scripts/start.sh
# Cross-references: docs/scripts/README.md
set -euo pipefail
here="$(dirname "${BASH_SOURCE[0]}")"
bash "$here/stop.sh" || true
bash "$here/start.sh"
