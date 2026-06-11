#!/usr/bin/env bash
# Replace alertstack_host="<anything>" with alertstack_host="<TARGET>" in all
# .prom test fixtures under app/test/.
#
# Usage:
#   set_prom_host.sh <target-host>          # e.g. alertstack.dev
#   ALERTSTACK_HOST=alertstack.dev set_prom_host.sh
#
# Can also be invoked via: make prom-set-host [ALERTSTACK_HOST=alertstack.dev]

set -euo pipefail

TARGET="${1:-${ALERTSTACK_HOST:-}}"

if [[ -z "$TARGET" ]]; then
  echo "ERROR: supply a target host as \$1 or via ALERTSTACK_HOST" >&2
  exit 1
fi

PROM_DIR="$(cd "$(dirname "$0")/../app/test" && pwd)"

count=0
for f in "$PROM_DIR"/*.prom; do
  [[ -f "$f" ]] || continue
  if grep -q 'alertstack_host=' "$f"; then
    sed -i.bak "s/alertstack_host=\"[^\"]*\"/alertstack_host=\"$TARGET\"/g" "$f" && rm -f "$f.bak"
    echo "  updated: $(basename "$f")"
    (( count++ )) || true
  fi
done

echo "Done — $count file(s) updated to alertstack_host=\"$TARGET\"."
