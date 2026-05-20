#!/usr/bin/env bash
# Restore a database from the S3 replica.
#
# Usage:
#   ./restore.sh <output_path> [iso8601_timestamp]
#
# Examples:
#   ./restore.sh /tmp/restore_test.sqlite3
#   ./restore.sh /tmp/restore_test.sqlite3 2026-05-20T10:00:00Z
#
# Live restore (over the running DB):
#   1. stop the app:        kamal app stop   # or `docker stop <container>`
#   2. stop litestream:     sudo systemctl stop litestream
#   3. move the broken DB:  sudo mv /path/to/prod.sqlite3 /path/to/prod.sqlite3.broken
#   4. restore:             sudo ./restore.sh /path/to/prod.sqlite3 [timestamp]
#   5. fix ownership:       sudo chown <app-user>:<group> /path/to/prod.sqlite3
#   6. start app:           kamal app start
#   7. start litestream:    sudo systemctl start litestream

set -euo pipefail

OUT="${1:-}"
TS="${2:-}"

if [[ -z "$OUT" ]]; then
  echo "usage: $0 <output_path> [iso8601_timestamp]"
  exit 1
fi

# Read the source DB path from /etc/litestream.yml (first `path:` entry under `dbs:`).
SRC=$(sudo awk '/^dbs:/{flag=1;next} flag && /path:/{print $2; exit}' /etc/litestream.yml)
if [[ -z "$SRC" ]]; then
  echo "error: could not find db path in /etc/litestream.yml"
  exit 1
fi

ARGS=(-config /etc/litestream.yml -o "$OUT")
if [[ -n "$TS" ]]; then
  ARGS+=(-timestamp "$TS")
fi
ARGS+=("$SRC")

echo "==> restoring $SRC -> $OUT${TS:+ at $TS}"
sudo litestream restore "${ARGS[@]}"

echo "==> integrity check"
sqlite3 "$OUT" "PRAGMA integrity_check;"
sqlite3 "$OUT" "SELECT COUNT(*) AS tables FROM sqlite_master WHERE type='table';"
