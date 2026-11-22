#!/bin/bash
# Minimal paramiko SSH/SFTP test server for the NimbusTerm self-tests.
# Usage: scripts/test-ssh-server.sh [port] [root]
set -euo pipefail
PORT="${1:-2222}"
ROOT="${2:-/tmp/nimbusterm-sftp}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PYTHON="${PYTHON:-python3}"

if ! "$PYTHON" -c 'import paramiko' >/dev/null 2>&1; then
  echo "paramiko is required: $PYTHON -m pip install paramiko" >&2
  exit 1
fi

exec "$PYTHON" "$HERE/test_ssh_server.py" "$ROOT" "$PORT"
