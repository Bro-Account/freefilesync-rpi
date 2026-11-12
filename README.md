# build-freefilesync.sh

Build [FreeFileSync](https://freefilesync.org) from source on Raspberry Pi OS
/ Debian 13 (64-bit ARM) — with smart caching so the heavy dependencies are
compiled only once.

Based on [pmkees/build-FreeFileSync-on-64bit-RaspberryPiOS](https://github.com/pmkees/build-FreeFileSync-on-64bit-RaspberryPiOS),
extended with automatic caching, resumable downloads, and version
compatibility patches.

## Features

- **Dependency caching** — libssh2, curl, and wxWidgets are compiled once into
  `build-library/` and reused for every future FreeFileSync build, on this
  machine or on other devices you copy/sync `build-library/` to.
- **Version caching** — each built FreeFileSync version (binary + Resources)
  is cached and keyed against its exact dependency signature, so a stale
  cache can never be reused by accident.
- **Resumable downloads** — archives are validated and re-downloaded when
  incomplete; a lock file prevents two builds from interfering.
- **Compatibility patches** — the script automatically applies the small
  source/Makefile patches needed to build recent FreeFileSync releases
  against Debian 13 / current libssh2 and wxWidgets versions.

## Requirements

- Raspberry Pi OS / Debian 13 (Trixie), 64-bit ARM (aarch64 or armv7l)
- Internet access, and enough free space in `~/Documents` (~3 GB during the
  build) and next to the script (~500 MB for the dependency cache)

## Usage

On Raspberry Pi OS / Debian 13+ (aarch64) the script first checks whether an
official prebuilt build of the requested version exists on this repository's
[Releases](../../releases) page. If yes, it downloads and stores it in the
local cache in seconds — no compilation. If not (or on other systems/OS
versions), it falls back to building from source. Either way the script
installs everything needed and sets up `/opt/freefilesync` with a
`freefilesync` symlink in `/usr/local/bin` and a desktop entry.

```sh
./build-freefilesync.sh 14.13               # install prebuilt (or build from source)
./build-freefilesync.sh 14.13 --no-prebuilt # force a local source build
./build-freefilesync.sh 14.13 --no-install  # fetch/build into the cache only
./build-freefilesync.sh <URL>               # build from a direct download link
```

The script installs its build dependencies via `apt`, compiles libssh2 →
curl → wxWidgets → FreeFileSync, installs to `/opt/freefilesync` with a
`freefilesync` symlink in `/usr/local/bin`, and creates a desktop entry.

Build time: **30–60+ minutes on a Raspberry Pi** the first time; later
builds reuse the cached dependencies and finish much faster.

## Prebuilt binaries

This repository builds FreeFileSync automatically for **Raspberry Pi OS /
Debian 13 (aarch64)** via GitHub Actions (Debian 13 container on an ARM64
runner), and the script consumes these builds directly:
`./build-freefilesync.sh <version>` downloads the matching release, seeds the
local cache, and installs it with the usual desktop-entry setup.

The released binary links **libssh2 and curl statically** (and wxWidgets was
already static), so it runs on a stock Raspberry Pi OS installation — only
standard Debian runtime packages are needed (gtk3, libssl, libpsl, libidn2,
libjpeg), which the script installs automatically. Hand-installation of a
release tarball (note that FreeFileSync expects `Resources/` one level above
the binary's directory):

```sh
sudo mkdir -p /opt/freefilesync
sudo tar -xzf FreeFileSync-<version>-linux-aarch64.tar.gz -C /opt/freefilesync
sudo mv /opt/freefilesync/Resources /opt/Resources
sudo chmod +x /opt/freefilesync/FreeFileSync_aarch64
sudo ln -sf /opt/freefilesync/FreeFileSync_aarch64 /usr/local/bin/freefilesync
```

## How CI builds work

- Trigger: push a tag `v<version>` (e.g. `v14.13`), run the workflow manually
  from the *Actions* tab (leaving the version empty auto-detects the latest
  upstream release), or wait for the **daily scheduled check**, which builds
  and publishes every new upstream FreeFileSync release automatically.
- The workflow runs `./build-freefilesync.sh <version> --no-install` inside a
  `debian:13` container, so binaries match Raspberry Pi OS Trixie.
- `build-library/` is cached between runs via `actions/cache` (keyed on the
  script hash, so dependency changes invalidate it).
- Tag builds are attached to a GitHub Release; manual runs are available as
  workflow artifacts.

## Automated testing

Every CI build is smoke-tested before publication: the freshly built tarball
is unpacked into a **clean Debian 13 container that contains only runtime
packages** (no build tools, no dev headers — the same situation as a stock
Raspberry Pi OS), and the binary is launched under a virtual display (Xvfb).
The test passes only if the app starts, stays alive, and reports no
dynamic-loader errors; a screenshot is saved as a workflow artifact as
visual proof. Releases are published only after this test passes.

## Notes

- FreeFileSync is GPLv3. These builds are compiled from upstream source
  **plus a small patchset** — the minimal changes needed to build on
  Debian 13 / aarch64, applied automatically by the script. For GPLv3
  "complete corresponding source" compliance, the script records the exact
  patchset as a diff, and CI attaches it to each release
  (`FreeFileSync-<version>-rpi-patches.diff`; corresponding source =
  upstream source ZIP with that diff applied via `patch -p1`).
- This repository's script itself is MIT licensed. Statically linked
  third-party libraries (libssh2, curl, OpenSSL) keep their own
  licenses and are unmodified except for the libssh2 compatibility
  patch included in the patchset.
- To rebuild a cached dependency on a normal machine, delete it from
  `build-library/`, e.g. `rm -rf build-library/aarch64-debian-13/curl/8.23.0`.
