#!/usr/bin/env bash
set -euo pipefail

TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$TASK_ROOT"

# Keep the installed identity and preferences while using the fast local build.
pkill -x CodexBar 2>/dev/null || true
CODEXBAR_SIGNING=adhoc CODEXBAR_LOCAL_PRODUCTION_ID=1 ARCHES="$(uname -m)" \
  "$TASK_ROOT/Scripts/package_app.sh" debug
/usr/bin/open -n "$TASK_ROOT/CodexBar.app"
for _ in {1..20}; do
  if pgrep -x CodexBar >/dev/null; then
    echo "CodexBar is running."
    exit 0
  fi
  sleep 0.25
done
echo "ERROR: CodexBar did not stay running." >&2
exit 1
