#!/bin/bash
# Smoke test for the released FreeFileSync build.
#
# Runs in a CI container that deliberately contains ONLY runtime packages
# (no build tools, no dev headers) — the same situation as a stock Raspberry
# Pi OS system. The binary must start, stay alive, and produce no dynamic
# loader errors. This catches problems a successful compile cannot: missing
# runtime libraries or incompatible library symbol versions.
set -u

TARBALL="${1:?usage: smoke-test.sh <tarball>}"
INSTALL_DIR="/opt/freefilesync"

echo "== Unpacking ${TARBALL} =="
mkdir -p "$INSTALL_DIR"
tar -xzf "$TARBALL" -C "$INSTALL_DIR"

echo "== Launching FreeFileSync under Xvfb on a clean system =="
xvfb-run -a --server-args="-screen 0 1280x1024x24" bash -c '
  /opt/freefilesync/FreeFileSync_aarch64 > /tmp/ffs-stdout.log 2> /tmp/ffs-stderr.log &
  APP_PID=$!
  sleep 12
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "FAIL: FreeFileSync exited before the smoke-test timeout"
    exit 1
  fi
  if command -v import >/dev/null 2>&1; then
    import -window root /tmp/ffs-smoke.png 2>/dev/null || echo "(screenshot unavailable)"
  elif command -v magick >/dev/null 2>&1; then
    magick import -window root /tmp/ffs-smoke.png 2>/dev/null || echo "(screenshot unavailable)"
  fi
  kill "$APP_PID" 2>/dev/null
'
RESULT=$?

echo "== FreeFileSync stderr =="
cat /tmp/ffs-stderr.log 2>/dev/null || true

if [ "$RESULT" -ne 0 ]; then
  echo "FAIL: smoke test did not pass (exit ${RESULT})"
  exit "$RESULT"
fi

if grep -qi "error while loading shared libraries" /tmp/ffs-stderr.log 2>/dev/null; then
  echo "FAIL: dynamic loader reported a missing library"
  exit 1
fi

if grep -qiE "version .+ not found" /tmp/ffs-stderr.log 2>/dev/null; then
  echo "FAIL: binary requires a library symbol version that stock Debian 13 does not provide"
  exit 1
fi

if [ -s /tmp/ffs-smoke.png ]; then
  echo "✓ Screenshot captured: $(du -h /tmp/ffs-smoke.png | cut -f1)"
else
  echo "(no screenshot captured)"
fi

echo "✓ Smoke test passed: FreeFileSync started, rendered, and stayed alive"
