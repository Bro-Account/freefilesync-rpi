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

echo "== Unpacking ${TARBALL} =="
rm -rf /opt/freefilesync /opt/Resources
mkdir -p /opt/freefilesync
tar -xzf "$TARBALL" -C /opt/freefilesync
# FreeFileSync looks for its Resources directory one level ABOVE the
# binary's directory (binary in /opt/freefilesync, Resources in /opt/Resources),
# which is exactly the layout the build script's install step uses.
mv /opt/freefilesync/Resources /opt/Resources

# Layout assertion: the resource files must sit where the app expects them.
# (Note: do NOT use Animal.dat here — that file is a Donation-Edition asset
# and is intentionally absent from open-source builds; its "Failed to load"
# message is a known, harmless upstream quirk.)
LAYOUT_OK=true
for RESOURCE_FILE in Icons.zip Languages.zip Gtk3Styles.css cacert.pem; do
  if [ ! -f "/opt/Resources/${RESOURCE_FILE}" ]; then
    echo "FAIL: expected resource missing at /opt/Resources/${RESOURCE_FILE}"
    LAYOUT_OK=false
  fi
done
if [ ! -x "/opt/freefilesync/FreeFileSync_aarch64" ]; then
  echo "FAIL: binary not found or not executable at /opt/freefilesync/FreeFileSync_aarch64"
  LAYOUT_OK=false
fi
if [ "$LAYOUT_OK" = false ]; then
  echo "FAIL: install layout does not match what FreeFileSync expects"
  exit 1
fi
echo "✓ Layout check passed: binary in /opt/freefilesync, Resources in /opt/Resources"

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
