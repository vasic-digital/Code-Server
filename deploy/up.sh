#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] && { set -a; . ./.env; set +a; }
: "${PORT_PREFIX:=52}"; : "${PROJECTS:=}"
: "${CODE_SERVER_PASSWORD:?set CODE_SERVER_PASSWORD in deploy/.env}"
{
  echo "services:"
  echo "  code-server:"
  echo "    volumes:"
  echo "      - cs-config:/home/coder/.config"
  IFS=':' read -ra _ps <<< "$PROJECTS"
  for p in "${_ps[@]}"; do
    [ -n "$p" ] || continue
    echo "      - ${p}:/home/coder/projects/$(basename "$p"):Z"
  done
} > compose.projects.yml
RT="podman compose"; command -v podman >/dev/null || RT="docker compose"
echo "runtime: $RT"
$RT -f compose.codeserver.yml -f compose.projects.yml up -d --build
$RT -f compose.codeserver.yml -f compose.projects.yml ps
