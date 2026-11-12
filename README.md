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

```sh
./build-freefilesync.sh 14.13     # build & install
./build-freefilesync.sh https://freefilesync.org/download/FreeFileSync_14.13_Source.zip
./build-freefilesync.sh 14.13 --no-install   # build & cache only
./build-freefilesync.sh 14.13 --keep-temp    # keep extracted sources
```

The script installs its build dependencies via `apt`, compiles libssh2 →
curl → wxWidgets → FreeFileSync, installs to `/opt/freefilesync` with a
`freefilesync` symlink in `/usr/local/bin`, and creates a desktop entry.

Build time: **30–60+ minutes on a Raspberry Pi** the first time; later
builds reuse the cached dependencies and finish much faster.

## Prebuilt binaries

This repository builds FreeFileSync automatically for **Raspberry Pi OS /
Debian 13 (aarch64)** via GitHub Actions (Debian 13 container on an ARM64
runner). Finished portable builds are attached to the matching
[Releases](../../releases) page:

```sh
sudo mkdir -p /opt/freefilesync
sudo tar -xzf FreeFileSync-<version>-linux-aarch64.tar.gz -C /opt/freefilesync
sudo chmod +x /opt/freefilesync/FreeFileSync_aarch64
sudo ln -sf /opt/freefilesync/FreeFileSync_aarch64 /usr/local/bin/freefilesync
```

## How CI builds work

- Trigger: push a tag `v<version>` (e.g. `v14.13`) or run the workflow
  manually from the *Actions* tab.
- The workflow runs `./build-freefilesync.sh <version> --no-install` inside a
  `debian:13` container, so binaries match Raspberry Pi OS Trixie.
- `build-library/` is cached between runs via `actions/cache` (keyed on the
  script hash, so dependency changes invalidate it).
- Tag builds are attached to a GitHub Release; manual runs are available as
  workflow artifacts.

## Notes

- FreeFileSync is GPLv3; these builds are compiled from unmodified upstream
  source. This repository's script itself is MIT licensed.
- To rebuild a cached dependency on a normal machine, delete it from
  `build-library/`, e.g. `rm -rf build-library/aarch64-debian-13/curl/8.23.0`.
