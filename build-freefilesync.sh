#!/bin/bash
set -o pipefail

# When already running as root (e.g. inside a CI build container), there is no
# sudo binary and none is needed: execute the commands directly instead.
if [ "$(id -u)" -eq 0 ]; then
  sudo() { "$@"; }
fi

# Script for building FreeFileSync on 64-bit Raspberry Pi OS
# Based on: https://github.com/pmkees/build-FreeFileSync-on-64bit-RaspberryPiOS
# Dynamically fetches the version based on the provided version number or download link
#
# Usage:
#   ./build-freefilesync.sh 14.10
#   ./build-freefilesync.sh https://freefilesync.org/download/FreeFileSync_14.8_Source.zip
#
# The version-specific source patches below are applied automatically before
# compiling; they are needed for building recent FreeFileSync releases
# against Debian 13 / Raspberry Pi OS (aarch64).

#==============================================================================
# BUILD CONFIGURATION
#==============================================================================
# Use 2 parallel jobs for compilation (leaves 2 CPUs free on 4-core Pi)
MAKE_JOBS=2

#==============================================================================
# DEPENDENCY VERSIONS - Update these to use newer versions
#==============================================================================
LIBSSH2_VERSION="1.11.1" # https://libssh2.org/
CURL_VERSION="8.23.0" # https://curl.se/download.html
WXWIDGETS_VERSION="3.3.4" # https://wxwidgets.org/downloads/
# Note: FFS 14.6+ uses GTK3 with native dark mode support

# Build library path for caching compiled dependencies (relative to script location)
# Static suffix: libssh2 and curl are built as static archives so the final
# FreeFileSync binary is self-contained and runs on stock Raspberry Pi OS.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Prevent simultaneous builds from modifying the same working directory/cache.
LOCK_FILE="${SCRIPT_DIR}/.build-freefilesync.lock"

if ! command -v flock >/dev/null 2>&1; then
  echo "Error: flock is required but was not found"
  echo "Install it with: sudo apt-get install -y util-linux"
  exit 1
fi

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
  echo "Error: another build-freefilesync.sh process is already running."
  echo "Lock file: $LOCK_FILE"
  exit 1
fi

BUILD_LIBRARY_ROOT="${SCRIPT_DIR}/build-library"

## Step 0: Check for command-line argument
if [ -z "$1" ]; then
  echo "Usage: $0 <version_or_url> [options]"
  echo "Examples:"
  echo "  $0 14.6"
  echo "  $0 https://freefilesync.org/download/FreeFileSync_14.6_Source.zip"
  echo ""
  echo "Default behavior:"
  echo "  - Downloads the official prebuilt GitHub release when available"
  echo "    (aarch64 + Debian 13+); otherwise compiles from source"
  echo "  - Uses cached dependencies if available (build-library/)"
  echo "  - Installs binary to /usr/local/bin with desktop entry"
  echo "  - Cleans up temporary build files (keeps cache)"
  echo ""
  echo "Options:"
  echo "  --no-install     Skip system installation"
  echo "  --keep-temp      Keep temporary build files (extracted sources, downloads)"
  echo "  --no-prebuilt    Ignore prebuilt GitHub releases, always compile"
  echo ""
  echo "Note: To rebuild a component, delete it from build-library/"
  echo "      e.g., rm -rf build-library/aarch64-debian-13/curl/8.17.0-static"
  exit 1
fi

INPUT="$1"
INSTALL_SYSTEM=true   # Default: Install to system
CLEANUP_TEMP=true     # Default: Clean up temp files, keep cache
PREBUILT_ENABLED=true # Default: use prebuilt GitHub release when available

# Detect if input is a version number or URL
if [[ "$INPUT" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  # Input is a version number - construct URL
  VERSION="$INPUT"
  DOWNLOAD_URL="https://freefilesync.org/download/FreeFileSync_${VERSION}_Source.zip"
  echo "Version detected: ${VERSION}"
  echo "Using URL: ${DOWNLOAD_URL}"
  echo ""
else
  # Input is a URL - extract version
  DOWNLOAD_URL="$INPUT"
  # Extract VERSION from URL (e.g., FreeFileSync_14.5_Source.zip -> 14.5)
  VERSION=$(basename "$DOWNLOAD_URL" | sed 's/FreeFileSync_//' | sed 's/_Source.zip$//')
fi

#==============================================================================
# DOWNLOAD AND ARCHIVE VALIDATION HELPERS
#==============================================================================

validate_zip_archive() {
  unzip -tq "$1" >/dev/null 2>&1
}

validate_tar_gz_archive() {
  tar tzf "$1" >/dev/null 2>&1
}

validate_tar_bz2_archive() {
  tar tjf "$1" >/dev/null 2>&1
}

download_and_validate() {
  local url="$1"
  local archive="$2"
  local validator="$3"
  local description="$4"
  local temp_archive="${archive}.part"

  # Reuse only archives that pass an integrity/listing test.
  if [ -f "$archive" ] && "$validator" "$archive"; then
    echo "✓ Valid ${description} already exists: $archive"
    return 0
  fi

  if [ -f "$archive" ]; then
    echo "⚠ Existing ${description} is invalid or incomplete; deleting it"
    rm -f "$archive"
  fi

  rm -f "$temp_archive"

  echo "Downloading ${description}..."

  wget \
    --https-only \
    --timeout=30 \
    --tries=3 \
    --waitretry=2 \
    --output-document="$temp_archive" \
    "$url" || {
      rm -f "$temp_archive"
      echo "Failed to download ${description}"
      return 1
    }

  if ! "$validator" "$temp_archive"; then
    echo "Downloaded ${description} is not a valid archive."
    echo "Downloaded size: $(wc -c < "$temp_archive") bytes"
    rm -f "$temp_archive"
    return 1
  fi

  mv -f "$temp_archive" "$archive"

  echo "✓ Downloaded and validated ${description}"
}

# Parse options
shift
while [[ $# -gt 0 ]]; do
  case $1 in
    --no-install)
      INSTALL_SYSTEM=false
      shift
      ;;
    --keep-temp)
      CLEANUP_TEMP=false
      shift
      ;;
    --no-prebuilt)
      PREBUILT_ENABLED=false
      shift
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

## Step 1: Check if the version is valid
if [ -z "$VERSION" ]; then
  echo "Failed to determine version from the download link."
  exit 1
fi

echo "Building FreeFileSync version $VERSION for Raspberry Pi OS..."

# Check architecture
ARCH=$(uname -m)
echo "Detected architecture: $ARCH"

if [[ "$ARCH" != "aarch64" && "$ARCH" != "armv7l" ]]; then
  echo "Warning: This script is designed for ARM architecture (Raspberry Pi)"
  echo "Detected: $ARCH"
  read -p "Do you want to continue anyway? (y/N) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
  fi
fi

# Native build caches must never be shared between CPU architectures or
# incompatible operating-system releases.
#
# Read /etc/os-release in a command substitution so its VERSION variable
# cannot overwrite this script's FreeFileSync VERSION variable.
if [ -r /etc/os-release ]; then
  OS_CACHE_ID="$(
    . /etc/os-release
    printf '%s-%s' "${ID:-linux}" "${VERSION_ID:-unknown}"
  )"
else
  OS_CACHE_ID="linux-unknown"
fi

# Keep the value safe for use as a directory name.
OS_CACHE_ID="${OS_CACHE_ID//[^A-Za-z0-9._-]/_}"

BUILD_LIBRARY="${BUILD_LIBRARY_ROOT}/${ARCH}-${OS_CACHE_ID}"

echo "Build cache target: ${BUILD_LIBRARY}"

echo ""
echo "NOTE: This build process will take 30-60+ minutes depending on your Pi model."
echo "The script will compile libssh2, curl, wxWidgets, and FreeFileSync from source."
echo ""

## Step 2: Set variables for working directory
WORKING_DIR="$HOME/Documents/freefilesync-build"
ZIP_NAME="FreeFileSync_${VERSION}_Source.zip"
EXTRACT_DIR="freefilesync-${VERSION}"

# Ensure working directory exists
mkdir -p "$WORKING_DIR"
cd "$WORKING_DIR" || { echo "Failed to access working directory"; exit 1; }

# Ensure /usr/local/lib/pkgconfig is in pkg-config search path.
# On some systems this isn't included by default, which breaks pkg-config
# lookups for libraries installed to /usr/local (curl, libssh2, wxWidgets).
# Make locally built dependencies discoverable by pkg-config, the compiler,
# the linker, and configure-time test programs.
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export CPPFLAGS="-I/usr/local/include${CPPFLAGS:+ $CPPFLAGS}"
export LDFLAGS="-L/usr/local/lib -Wl,-rpath,/usr/local/lib${LDFLAGS:+ $LDFLAGS}"
export LD_LIBRARY_PATH="/usr/local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

## Step 3: Install apt dependencies
echo "Installing system dependencies..."
sudo apt-get update
sudo apt-get install -y \
  libgtk-3-dev \
  libssl-dev \
  libpsl-dev \
  libidn2-dev \
  zlib1g-dev \
  build-essential \
  wget \
  unzip \
  pkg-config \
  libjpeg62

## Step 4: Download the FreeFileSync source code (if not already cached)
# Check if we have this version cached - if so, we don't need the source
FFS_CACHE_DIR="${BUILD_LIBRARY}/freefilesync/${VERSION}"
DEPS_FILE="${FFS_CACHE_DIR}/.deps"

# Increase CACHE_FORMAT when cache layout/build assumptions change.
# Increase PATCHSET_REVISION whenever one of the FreeFileSync source patches
# below is added, removed, or materially changed.
CACHE_FORMAT="4"
PATCHSET_REVISION="14.13-rpi-compat-5"

CURRENT_DEPS="cacheFormat=${CACHE_FORMAT},patchset=${PATCHSET_REVISION},arch=${ARCH},os=${OS_CACHE_ID},libssh2=${LIBSSH2_VERSION},curl=${CURL_VERSION},wxWidgets=${WXWIDGETS_VERSION}"

# Detect the binary name based on architecture (needed for cache check)
if [ "$ARCH" = "aarch64" ]; then
  BINARY_NAME="FreeFileSync_aarch64"
elif [ "$ARCH" = "armv7l" ]; then
  BINARY_NAME="FreeFileSync_armv7l"
elif [ "$ARCH" = "x86_64" ]; then
  BINARY_NAME="FreeFileSync_x86_64"
else
  BINARY_NAME="FreeFileSync"
fi

CACHED_BINARY="${FFS_CACHE_DIR}/bin/${BINARY_NAME}"
CACHED_RESOURCES="${FFS_CACHE_DIR}/Resources"
SKIP_BUILD=false

## Optional fast path: official prebuilt build from GitHub Releases.
# Supported only on aarch64 with Debian 13 or newer (the release binaries are
# built in a debian:13 container). Anything else, or a version without a
# published release, falls back to compiling from source.
if [ "$PREBUILT_ENABLED" = true ] && [ "$SKIP_BUILD" = false ]; then
  PREBUILT_COMPATIBLE="$(
    . /etc/os-release
    if [ "$ARCH" = "aarch64" ] && [ "${ID:-}" = "debian" ] && [ "${VERSION_ID:-0}" -ge 13 ] 2>/dev/null; then
      echo yes
    else
      echo no
    fi
  )"

  if [ "$PREBUILT_COMPATIBLE" = yes ]; then
    PREBUILT_URL="https://github.com/Bro-Account/freefilesync-rpi/releases/download/v${VERSION}/FreeFileSync-${VERSION}-linux-aarch64.tar.gz"
    PREBUILT_TARBALL="${WORKING_DIR}/FreeFileSync-${VERSION}-prebuilt.tar.gz"

    echo "Checking for prebuilt FreeFileSync ${VERSION} on GitHub Releases..."
    if wget --spider -q "$PREBUILT_URL"; then
      echo "  Found: downloading prebuilt build (no compilation needed)..."
      if wget --https-only --timeout=30 --tries=3 \
         --output-document="$PREBUILT_TARBALL" "$PREBUILT_URL" \
         && tar tzf "$PREBUILT_TARBALL" >/dev/null 2>&1; then

        PREBUILT_TMP="${WORKING_DIR}/prebuilt-${VERSION}"
        rm -rf "$PREBUILT_TMP"
        mkdir -p "$PREBUILT_TMP"
        tar xzf "$PREBUILT_TARBALL" -C "$PREBUILT_TMP"

        # Store it in the same layout a fresh build would have produced,
        # so the rest of the script (cache check, installation) just works.
        rm -rf "$FFS_CACHE_DIR"
        mkdir -p "${FFS_CACHE_DIR}/bin"
        mv "${PREBUILT_TMP}/FreeFileSync_aarch64" "${FFS_CACHE_DIR}/bin/"
        mv "${PREBUILT_TMP}/Resources" "${FFS_CACHE_DIR}/Resources"
        echo "$CURRENT_DEPS" > "$DEPS_FILE"
        rm -rf "$PREBUILT_TMP" "$PREBUILT_TARBALL"

        echo "  ✓ Prebuilt build stored in ${FFS_CACHE_DIR}"
      else
        echo "  ⚠ Download failed - falling back to building from source"
      fi
    else
      echo "  No prebuilt release for ${VERSION} - will build from source"
    fi
    echo ""
  fi
fi

# Check if we have a complete cached build with matching dependencies
if [ -f "$CACHED_BINARY" ] && [ -d "$CACHED_RESOURCES" ] && [ -f "$DEPS_FILE" ]; then
  CACHED_DEPS=$(cat "$DEPS_FILE")
  if [ "$CACHED_DEPS" = "$CURRENT_DEPS" ]; then
    echo "✓ FreeFileSync ${VERSION} already cached with matching dependencies"
    echo "  Skipping source download and build"
    SKIP_BUILD=true
    BINARY_PATH="$CACHED_BINARY"
  else
    echo "⚠ Cached build found but dependencies changed:"
    echo "  Cached:  $CACHED_DEPS"
    echo "  Current: $CURRENT_DEPS"
    echo "  → Will rebuild with updated dependencies"
  fi
fi

# Only download if we need to build.
if [ "$SKIP_BUILD" = false ]; then
  download_and_validate \
    "$DOWNLOAD_URL" \
    "$ZIP_NAME" \
    validate_zip_archive \
    "FreeFileSync ${VERSION} source package" || exit 1
fi

## Step 5: Extract the package (only if we need to build)
if [ "$SKIP_BUILD" = false ]; then
  if [ -d "$EXTRACT_DIR" ]; then
    echo "Removing previous extract directory..."
    rm -rf "$EXTRACT_DIR"
  fi
  echo "Extracting the package..."
  unzip -qo "$ZIP_NAME" -d "$EXTRACT_DIR" || { echo "Failed to extract the package"; exit 1; }
fi

## Step 6: Build libssh2 (with smart caching)
echo ""
echo "=========================================="
echo "Step 1/4: libssh2 ${LIBSSH2_VERSION}"
echo "=========================================="

LIBSSH2_CACHE_DIR="${BUILD_LIBRARY}/libssh2/${LIBSSH2_VERSION}-static"
LIBSSH2_DIR="libssh2-${LIBSSH2_VERSION}"

# Check if we have a cached version
if [ -d "$LIBSSH2_CACHE_DIR" ] && [ -f "$LIBSSH2_CACHE_DIR/.build_complete" ]; then
  echo "✓ Using cached libssh2 ${LIBSSH2_VERSION}"
  # Install from cache to system
  sudo install -d /usr/local/include /usr/local/lib

  sudo cp -R --no-dereference --preserve=mode,timestamps,links \
    "$LIBSSH2_CACHE_DIR/include/." /usr/local/include/ || {
      echo "Failed to restore cached libssh2 headers"
      exit 1
    }

  sudo cp -R --no-dereference --preserve=mode,timestamps,links \
    "$LIBSSH2_CACHE_DIR/lib/." /usr/local/lib/ || {
      echo "Failed to restore cached libssh2 libraries"
      exit 1
    }

  # Restore pkg-config file
  sudo mkdir -p /usr/local/lib/pkgconfig
  if [ -f "$LIBSSH2_CACHE_DIR/pkgconfig/libssh2.pc" ]; then
    sudo cp "$LIBSSH2_CACHE_DIR/pkgconfig/libssh2.pc" /usr/local/lib/pkgconfig/
  else
    # Create libssh2.pc if it wasn't in the cache (old cache or first run)
    sudo bash -c "cat > /usr/local/lib/pkgconfig/libssh2.pc << 'PKGEOF'
prefix=/usr/local
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: libssh2
Description: A library implementing the SSH2 protocol
Version: ${LIBSSH2_VERSION}
Libs: -L\${libdir} -lssh2
Cflags: -I\${includedir}
PKGEOF"
  fi

  # Keep custom-built libraries in /usr/local/lib.
  # Do not copy them into Debian's package-managed multiarch directories.

  sudo ldconfig
else
  echo "Building libssh2 ${LIBSSH2_VERSION} (first time, will be cached)..."
  
  download_and_validate \
    "https://libssh2.org/download/libssh2-${LIBSSH2_VERSION}.tar.gz" \
    "${LIBSSH2_DIR}.tar.gz" \
    validate_tar_gz_archive \
    "libssh2 ${LIBSSH2_VERSION} source archive" || exit 1

  if [ -d "$LIBSSH2_DIR" ]; then
    rm -rf "$LIBSSH2_DIR"
  fi
  
  tar xzf "${LIBSSH2_DIR}.tar.gz" || { echo "Failed to extract libssh2"; exit 1; }
  cd "$LIBSSH2_DIR" || exit 1
  mkdir -p build
  cd build || exit 1
  # Static only: FreeFileSync then links libssh2 from the archive and does
  # not depend on a specific libssh2 runtime version being installed.
  ../configure --disable-shared || { echo "libssh2 configure failed"; exit 1; }
  make -j${MAKE_JOBS} || { echo "libssh2 build failed"; exit 1; }
  sudo make install || { echo "libssh2 install failed"; exit 1; }
  
  # Keep custom-built libraries in /usr/local/lib.
  # Do not copy them into Debian's package-managed multiarch directories.
  sudo ldconfig

  # Create libssh2.pc (libssh2 doesn't generate one during make install)
  sudo mkdir -p /usr/local/lib/pkgconfig
  sudo bash -c "cat > /usr/local/lib/pkgconfig/libssh2.pc << 'PKGEOF'
prefix=/usr/local
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: libssh2
Description: A library implementing the SSH2 protocol
Version: ${LIBSSH2_VERSION}
Libs: -L\${libdir} -lssh2
Cflags: -I\${includedir}
PKGEOF"

  cd "$WORKING_DIR" || exit 1

  # Cache the built libraries
  echo "Caching libssh2 ${LIBSSH2_VERSION} for future use..."
  # Remove any incomplete cache from a prior interrupted build.
  rm -rf "$LIBSSH2_CACHE_DIR"

  mkdir -p "$LIBSSH2_CACHE_DIR"/{lib,include,pkgconfig}

  cp -R --no-dereference --preserve=mode,timestamps,links \
    /usr/local/include/libssh2*.h \
    "$LIBSSH2_CACHE_DIR/include/" || {
      echo "Failed to cache libssh2 headers"
      exit 1
    }

  cp -R --no-dereference --preserve=mode,timestamps,links \
    /usr/local/lib/libssh2* \
    "$LIBSSH2_CACHE_DIR/lib/" || {
      echo "Failed to cache libssh2 libraries"
      exit 1
    }

  cp /usr/local/lib/pkgconfig/libssh2.pc \
    "$LIBSSH2_CACHE_DIR/pkgconfig/" || {
      echo "Failed to cache libssh2 pkg-config metadata"
      exit 1
    }

  touch "$LIBSSH2_CACHE_DIR/.build_complete"
  echo "✓ Cached in ${LIBSSH2_CACHE_DIR}"
fi

# libssh2 is built with --disable-shared, so curl and FreeFileSync link
# against the static archive and no ldconfig symlinks or runtime library
# are needed for it.
if [ ! -f /usr/local/lib/libssh2.a ]; then
  echo "Error: static libssh2 archive was not found in /usr/local/lib"
  echo "Expected /usr/local/lib/libssh2.a (built with --disable-shared)"
  exit 1
fi

echo "✓ Static libssh2 archive available: /usr/local/lib/libssh2.a"

cd "$WORKING_DIR" || exit 1

## Step 7: Build libcurl (with smart caching)
echo ""
echo "=========================================="
echo "Step 2/4: libcurl ${CURL_VERSION}"
echo "=========================================="

CURL_CACHE_DIR="${BUILD_LIBRARY}/curl/${CURL_VERSION}-static"
CURL_DIR="curl-${CURL_VERSION}"

# Check if we have a cached version
if [ -d "$CURL_CACHE_DIR" ] && [ -f "$CURL_CACHE_DIR/.build_complete" ]; then
  echo "✓ Using cached libcurl ${CURL_VERSION}"
  # Install from cache to system
  sudo install -d /usr/local/include /usr/local/lib /usr/local/bin

  sudo cp -R --no-dereference --preserve=mode,timestamps,links \
    "$CURL_CACHE_DIR/include/." /usr/local/include/ || {
      echo "Failed to restore cached curl headers"
      exit 1
    }

  sudo cp -R --no-dereference --preserve=mode,timestamps,links \
    "$CURL_CACHE_DIR/lib/." /usr/local/lib/ || {
      echo "Failed to restore cached curl libraries"
      exit 1
    }

  sudo cp -R --no-dereference --preserve=mode,timestamps,links \
    "$CURL_CACHE_DIR/bin/." /usr/local/bin/ || {
      echo "Failed to restore cached curl binaries"
      exit 1
    }

  # Restore pkg-config file (needed for pkg-config --cflags/--libs libcurl)
  if [ -d "$CURL_CACHE_DIR/pkgconfig" ]; then
    sudo mkdir -p /usr/local/lib/pkgconfig
    sudo cp "$CURL_CACHE_DIR"/pkgconfig/*.pc /usr/local/lib/pkgconfig/ 2>/dev/null || true
  fi

  # Keep custom-built libraries in /usr/local/lib.
  # Do not copy them into Debian's package-managed multiarch directories.
  sudo ldconfig
else
  echo "Building libcurl ${CURL_VERSION} (first time, will be cached)..."
  
  download_and_validate \
    "https://curl.se/download/curl-${CURL_VERSION}.tar.gz" \
    "${CURL_DIR}.tar.gz" \
    validate_tar_gz_archive \
    "curl ${CURL_VERSION} source archive" || exit 1

  
  if [ -d "$CURL_DIR" ]; then
    rm -rf "$CURL_DIR"
  fi
  
  tar xzf "${CURL_DIR}.tar.gz" || { echo "Failed to extract curl"; exit 1; }
  cd "$CURL_DIR" || exit 1
  mkdir -p build
  cd build || exit 1
  # Static only: see the libssh2 note above — the final FreeFileSync binary
  # carries curl (and its dependency chain) inside.
  ../configure \
  --disable-shared \
  --with-openssl \
  --with-libssh2=/usr/local \
  --enable-versioned-symbols || {
    echo "curl configure failed"
    exit 1
  }
  make -j${MAKE_JOBS} || { echo "curl build failed"; exit 1; }
  sudo make install || { echo "curl install failed"; exit 1; }
  
  # Keep custom-built libraries in /usr/local/lib.
  # Do not copy them into Debian's package-managed multiarch directories.
  sudo ldconfig
  
  cd "$WORKING_DIR" || exit 1
  
  # Cache the built libraries
  echo "Caching libcurl ${CURL_VERSION} for future use..."
  # Remove any incomplete cache from a prior interrupted build.
  rm -rf "$CURL_CACHE_DIR"

  mkdir -p "$CURL_CACHE_DIR"/{lib,include,bin,pkgconfig}

  cp -R --no-dereference --preserve=mode,timestamps,links \
    /usr/local/include/curl \
    "$CURL_CACHE_DIR/include/" || {
      echo "Failed to cache curl headers"
      exit 1
    }

  cp -R --no-dereference --preserve=mode,timestamps,links \
    /usr/local/lib/libcurl* \
    "$CURL_CACHE_DIR/lib/" || {
      echo "Failed to cache curl libraries"
      exit 1
    }

  cp -R --no-dereference --preserve=mode,timestamps,links \
    /usr/local/bin/curl* \
    "$CURL_CACHE_DIR/bin/" || {
      echo "Failed to cache curl binaries"
      exit 1
    }

  cp /usr/local/lib/pkgconfig/libcurl.pc \
    "$CURL_CACHE_DIR/pkgconfig/" || {
      echo "Failed to cache curl pkg-config metadata"
      exit 1
    }

  touch "$CURL_CACHE_DIR/.build_complete"
  echo "✓ Cached in ${CURL_CACHE_DIR}"
fi

cd "$WORKING_DIR" || exit 1

## Step 8: Build wxWidgets (with smart caching)
echo ""
echo "=========================================="
echo "Step 3/4: wxWidgets ${WXWIDGETS_VERSION}"
echo "=========================================="

WXWIDGETS_CACHE_DIR="${BUILD_LIBRARY}/wxWidgets/${WXWIDGETS_VERSION}"
WX_DIR="wxWidgets-${WXWIDGETS_VERSION}"

# Check if we have a cached version
if [ -d "$WXWIDGETS_CACHE_DIR" ] && [ -f "$WXWIDGETS_CACHE_DIR/.build_complete" ]; then
  echo "✓ Using cached wxWidgets ${WXWIDGETS_VERSION}"
  # Install from cache to system
  sudo install -d /usr/local/include /usr/local/lib /usr/local/bin

  sudo cp -R --no-dereference --preserve=mode,timestamps,links \
    "$WXWIDGETS_CACHE_DIR/include/." /usr/local/include/ || {
      echo "Failed to restore cached wxWidgets headers"
      exit 1
    }

  sudo cp -R --no-dereference --preserve=mode,timestamps,links \
    "$WXWIDGETS_CACHE_DIR/lib/." /usr/local/lib/ || {
      echo "Failed to restore cached wxWidgets libraries"
      exit 1
    }

  sudo cp -R --no-dereference --preserve=mode,timestamps,links \
    "$WXWIDGETS_CACHE_DIR/bin/." /usr/local/bin/ || {
      echo "Failed to restore cached wxWidgets binaries"
      exit 1
    }
  # Defensive re-assertion: wx-config and wxrc tools must be executable.
  sudo chmod +x /usr/local/bin/wx-config 2>/dev/null || true
  sudo chmod +x /usr/local/bin/wxrc* 2>/dev/null || true
  sudo ldconfig
else
  echo "Building wxWidgets ${WXWIDGETS_VERSION} (first time, will be cached)..."
  echo "This will take 20-40 minutes..."
  
  download_and_validate \
    "https://github.com/wxWidgets/wxWidgets/releases/download/v${WXWIDGETS_VERSION}/wxWidgets-${WXWIDGETS_VERSION}.tar.bz2" \
    "${WX_DIR}.tar.bz2" \
    validate_tar_bz2_archive \
    "wxWidgets ${WXWIDGETS_VERSION} source archive" || exit 1
  
  if [ -d "$WX_DIR" ]; then
    rm -rf "$WX_DIR"
  fi
  
  tar xjf "${WX_DIR}.tar.bz2" || { echo "Failed to extract wxWidgets"; exit 1; }
  cd "$WX_DIR" || exit 1
  mkdir -p gtk-build
  cd gtk-build || exit 1
  ../configure --disable-shared || { echo "wxWidgets configure failed"; exit 1; }
  make -j${MAKE_JOBS} || { echo "wxWidgets build failed"; exit 1; }
  sudo make install || { echo "wxWidgets install failed"; exit 1; }
  sudo ldconfig
  
  cd "$WORKING_DIR" || exit 1
  
  # Cache the built libraries (this is the BIG time saver!)
  echo "Caching wxWidgets ${WXWIDGETS_VERSION} for future use..."
  # Remove any incomplete cache from a prior interrupted build.
  rm -rf "$WXWIDGETS_CACHE_DIR"

  mkdir -p "$WXWIDGETS_CACHE_DIR"/{lib,include,bin}

  cp -R --no-dereference --preserve=mode,timestamps,links \
    /usr/local/include/wx-* \
    "$WXWIDGETS_CACHE_DIR/include/" || {
      echo "Failed to cache wxWidgets headers"
      exit 1
    }

  cp -R --no-dereference --preserve=mode,timestamps,links \
    /usr/local/lib/wx \
    "$WXWIDGETS_CACHE_DIR/lib/" || {
      echo "Failed to cache wxWidgets library data"
      exit 1
    }

  cp -R --no-dereference --preserve=mode,timestamps,links \
    /usr/local/lib/libwx* \
    "$WXWIDGETS_CACHE_DIR/lib/" || {
      echo "Failed to cache wxWidgets libraries"
      exit 1
    }

  cp /usr/local/bin/wx-config \
    "$WXWIDGETS_CACHE_DIR/bin/" || {
      echo "Failed to cache wx-config"
      exit 1
    }

  cp /usr/local/bin/wxrc* \
    "$WXWIDGETS_CACHE_DIR/bin/" || {
      echo "Failed to cache wxWidgets resource tools"
      exit 1
    }

  touch "$WXWIDGETS_CACHE_DIR/.build_complete"
  echo "✓ Cached in ${WXWIDGETS_CACHE_DIR}"
fi

cd "$WORKING_DIR" || exit 1

## Step 10: Build FreeFileSync (with dependency-aware caching)
echo ""
echo "=========================================="
echo "Step 4/4: Building FreeFileSync..."
echo "=========================================="

# If we already determined we can skip the build (matching cache exists), jump to installation
if [ "$SKIP_BUILD" = true ]; then
  echo "✓ Using cached FreeFileSync ${VERSION} (dependencies match)"
  BINARY_PATH="$CACHED_BINARY"
else
  # We need to build - apply patches first
  echo "Applying code patches to FreeFileSync..."
  
  FFS_SOURCE_DIR="${EXTRACT_DIR}/FreeFileSync/Source"
  
  if [ ! -d "$FFS_SOURCE_DIR" ]; then
    echo "Error: FreeFileSync source directory not found"
    exit 1
  fi

# Patch 1: Add missing constants to sftp.cpp (FFS 14.6 compatibility)
SFTP_FILE="${EXTRACT_DIR}/FreeFileSync/Source/afs/sftp.cpp"
if [ -f "$SFTP_FILE" ]; then
  echo "Patching sftp.cpp..."
  # Check if already patched by looking for our #define
  if ! grep -q "#define MAX_SFTP_READ_SIZE" "$SFTP_FILE"; then
    # Find the line where constants are first used
    LINE_NUM=$(grep -n "const size_t SFTP_OPTIMAL_BLOCK_SIZE_READ" "$SFTP_FILE" | head -1 | cut -d: -f1)
    
    if [ -n "$LINE_NUM" ]; then
      # Insert the #defines before the line that uses them
      sed -i "${LINE_NUM}i\\
// FFS 14.6: Define missing libssh2 constants (removed from libssh2 headers)\\
#define MAX_SFTP_READ_SIZE 30000\\
#define MAX_SFTP_OUTGOING_SIZE 30000\\
" "$SFTP_FILE"
      echo "  - Added missing MAX_SFTP_READ_SIZE and MAX_SFTP_OUTGOING_SIZE constants"
    else
      echo "  - Warning: Could not find insertion point for SFTP constants"
    fi
  else
    echo "  - sftp.cpp constants already defined"
  fi
else
  echo "Warning: sftp.cpp not found at expected location"
fi

# Patch 2: Update Makefile for GTK3 and remove non-existent warn_static.h
MAKEFILE="${FFS_SOURCE_DIR}/Makefile"
if [ -f "$MAKEFILE" ]; then
  echo "Patching Makefile..."
  # GTK3 is already default in 14.6+
  sed -i 's/gtk+-2\.0/gtk+-3.0/g' "$MAKEFILE" 2>/dev/null || true
  # Remove warn_static.h include (doesn't exist in 14.6+)
  sed -i 's/-include "zen\/warn_static\.h" //g' "$MAKEFILE"
  # FreeFileSync expects wxWidgets implicit wxString encoding conversions
  # to be disabled. This also avoids wxCStrData conversion ambiguity.
  if ! grep -q -- "-DwxNO_IMPLICIT_WXSTRING_ENCODING" "$MAKEFILE"; then
    sed -i 's/-DWXINTL_NO_GETTEXT_MACRO/-DWXINTL_NO_GETTEXT_MACRO -DwxNO_IMPLICIT_WXSTRING_ENCODING/g' "$MAKEFILE"
    echo "  - Added -DwxNO_IMPLICIT_WXSTRING_ENCODING"
  fi

  # The 14.13 source ZIP omits the line-continuation backslash before
  # "-O3 -DNDEBUG". Without it, make reports "missing separator" on line 14.
  if [ "$VERSION" = "14.13" ]; then
    python3 - "$MAKEFILE" <<'PY' || exit 1
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

broken = (
    "           -Wno-unused-function -Wno-deprecated-enum-enum-conversion\n"
    "           -O3 -DNDEBUG"
)
fixed = (
    "           -Wno-unused-function -Wno-deprecated-enum-enum-conversion \\\n"
    "           -O3 -DNDEBUG"
)

if broken in text:
    path.write_text(text.replace(broken, fixed, 1))
    print("  - Fixed missing Makefile line continuation in FFS 14.13")
elif fixed in text:
    print("  - FFS 14.13 Makefile line continuation is already correct")
else:
    sys.exit("Error: FFS 14.13 Makefile layout changed; refusing to guess a patch")
PY
  fi
  echo "  - Removed warn_static.h include (file doesn't exist in 14.6+)"
  
  # curl and libssh2 are static archives now, so the linker needs the full
  # dependency chain appended after -lcurl: libssh2, OpenSSL, libpsl,
  # libidn2, zlib (all standard Debian dev packages installed above).
  if grep -q "^LDFLAGS.*pkg-config.*libcurl" "$MAKEFILE"; then
    if ! grep -q "\-lssh2" "$MAKEFILE"; then
      sed -i '/^LDFLAGS.*pkg-config.*libcurl/s/$/ -lssh2 -lssl -lcrypto -lpsl -lidn2 -lz/' "$MAKEFILE"
      echo "  - Added -lssh2 -lssl -lcrypto -lpsl -lidn2 -lz to LDFLAGS (static linking)"
    fi
  fi
else
  echo "Warning: Makefile not found at expected location"
fi

# Patch 3: Change error to warning in application.cpp
APP_FILE="${EXTRACT_DIR}/FreeFileSync/Source/application.cpp"
if [ -f "$APP_FILE" ]; then
  echo "Patching application.cpp..."
  sed -i 's/#error why is wxWidgets uncaught exception handling enabled!?/#warning why is wxWidgets uncaught exception handling enabled!?/g' "$APP_FILE"
  echo "  - Changed wxWidgets exception check to warning"
else
  echo "Warning: application.cpp not found at expected location"
fi

# Patch 4: Darkmode changes in wx+/darkmode.cpp
# NOTE: FFS 14.6 has native GTK3 dark mode support, MUCH simpler than 14.5!
# GTK3 handles dark mode natively, so we need minimal patching
DARKMODE_CPP="${EXTRACT_DIR}/wx+/darkmode.cpp"
if [ -f "$DARKMODE_CPP" ]; then
  echo "Checking darkmode.cpp (14.6 has native GTK3 support)..."
  
  # FFS 14.6 with GTK3: Only patch if specific patterns cause issues
  # Most GTK3 dark mode handling works out of the box
  
  # Check if problematic GetAppearance() pattern exists
  if grep -q "globalDefaultThemeIsDark = wxSystemSettings::GetAppearance()\.AreAppsDark()" "$DARKMODE_CPP"; then
    echo "  - Found wxSystemSettings::GetAppearance(), patching..."
    sed -i 's/globalDefaultThemeIsDark = wxSystemSettings::GetAppearance()\.AreAppsDark();/globalDefaultThemeIsDark = false; \/\/ FFS 14.6: default to light/' "$DARKMODE_CPP"
  fi
  
  # Comment out refGlobalColorHook if it exists (may cause issues)
  if grep -q "refGlobalColorHook" "$DARKMODE_CPP"; then
    sed -i '/refGlobalColorHook/s/^/\/\/ /' "$DARKMODE_CPP"
    echo "  - Commented out refGlobalColorHook references"
  fi
  
  # GTK3 note: wxColorHook and SysColorsHook should work correctly
  # No need to remove override keyword or modify class structure
  
  echo "  - darkmode.cpp patches applied (minimal for GTK3)"
else
  echo "Warning: darkmode.cpp not found"
fi

# Patch 5: Darkmode changes in wx+/darkmode.h
# FFS 14.6: Need to define wxColorHook for SysColorsHook to inherit from
DARKMODE_H="${EXTRACT_DIR}/wx+/darkmode.h"
if [ -f "$DARKMODE_H" ]; then
  echo "Patching darkmode.h..."
  
  # Add wx/colour.h include for wxColor
  if ! grep -q "#include <wx/colour.h>" "$DARKMODE_H"; then
    sed -i '/#include <wx\/app.h>/a\
#include <wx/colour.h>\
#include <wx/settings.h>' "$DARKMODE_H"
    echo "  - Added wx/colour.h and wx/settings.h includes"
  fi
  
# Check if wxColorHook is already defined.
# FFS 14.11 used an #endif include guard, but FFS 14.12 uses #pragma once.
# Insert immediately before "namespace zen", which exists in both releases.

if ! grep -q "struct wxColorHook" "$DARKMODE_H"; then
  python3 - "$DARKMODE_H" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()

marker = "\nnamespace zen\n"

definition = r'''

// FFS Raspberry Pi build compatibility: used by wx+/darkmode.cpp.
struct wxColorHook
{
    virtual ~wxColorHook() = default;
    virtual wxColor getColor(wxSystemColour index) const = 0;
};
'''.rstrip() + "\n"

if "struct wxColorHook" in text:
    print("  - wxColorHook already present")
elif marker not in text:
    print("  - Error: could not find 'namespace zen' insertion point")
    sys.exit(1)
else:
    path.write_text(text.replace(marker, definition + marker, 1))
    print("  - Added wxColorHook structure definition")
PY

  if ! grep -q "struct wxColorHook" "$DARKMODE_H"; then
    echo "Error: failed to add wxColorHook to darkmode.h"
    exit 1
  fi
else
  echo "  - wxColorHook already defined"
fi
else
  echo "Warning: darkmode.h not found at expected location"
fi

# Patch 6: Build FFS 14.12 with libssh2 1.11.1.
#
# FFS 14.12 refers to LIBSSH2_ERROR_STORE_OVERFLOW, but this error code
# is not defined by libssh2 1.11.1. The affected code only formats an error
# string, so compile that switch case only when the installed header provides
# the constant.

LIBSSH2_WRAP_FILE="${EXTRACT_DIR}/libssh2/libssh2_wrap.h"

if [ -f "$LIBSSH2_WRAP_FILE" ]; then
  echo "Patching libssh2_wrap.h for libssh2 ${LIBSSH2_VERSION} compatibility..."

  python3 - "$LIBSSH2_WRAP_FILE" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()

old = "        ZEN_CASE_RETURN_STRING(LIBSSH2_ERROR_STORE_OVERFLOW);"

new = """#ifdef LIBSSH2_ERROR_STORE_OVERFLOW
        ZEN_CASE_RETURN_STRING(LIBSSH2_ERROR_STORE_OVERFLOW);
#endif"""

patch_tag = "#ifdef LIBSSH2_ERROR_STORE_OVERFLOW"

if patch_tag in text:
    print("  - LIBSSH2_ERROR_STORE_OVERFLOW guard already present")
elif old not in text:
    print("  - Error: expected LIBSSH2_ERROR_STORE_OVERFLOW case was not found")
    print("  - No edit was made")
    sys.exit(1)
else:
    path.write_text(text.replace(old, new, 1))
    print("  - Guarded optional LIBSSH2_ERROR_STORE_OVERFLOW status code")
PY

  if ! grep -q "#ifdef LIBSSH2_ERROR_STORE_OVERFLOW" "$LIBSSH2_WRAP_FILE"; then
    echo "Error: libssh2 compatibility patch was not applied"
    exit 1
  fi
else
  echo "Error: libssh2_wrap.h not found at expected location"
  exit 1
fi

  # FFS 14.13 source ZIP has an invalid preprocessor directive in argon2.cpp.
  if [ "$VERSION" = "14.13" ]; then
    ARGON2_FILE="${EXTRACT_DIR}/zen/argon2.cpp"
    XBRZ_FILE="${EXTRACT_DIR}/xBRZ/src/xbrz.cpp"

    python3 - "$ARGON2_FILE" "$XBRZ_FILE" <<'PY' || exit 1
from pathlib import Path
import sys

broken = "#if  def __GNUC__"
fixed = "#if defined(__GNUC__)"

for name in sys.argv[1:]:
    path = Path(name)
    if not path.is_file():
        sys.exit(f"Error: source file not found: {path}")

    text = path.read_text()
    if broken in text:
        path.write_text(text.replace(broken, fixed, 1))
        print(f"  - Fixed invalid preprocessor directive in {path}")
    elif fixed in text:
        print(f"  - Preprocessor directive already correct in {path}")
    else:
        sys.exit(f"Error: expected directive not found in {path}; refusing to guess")
PY
  fi

  # Record the applied patchset. GPLv3 requires distributed binaries to come
  # with their complete corresponding source — for these builds that is the
  # pristine upstream source ZIP plus this diff. Stored in the build-library
  # cache so CI can attach it to the release (also on cache-hit re-runs).
  PATCHSET_DIR="${BUILD_LIBRARY}/patches"
  PATCHSET_FILE="${PATCHSET_DIR}/FreeFileSync-${VERSION}-rpi-patches-${PATCHSET_REVISION}.diff"
  echo "Recording patchset (pristine upstream source vs patched tree)..."
  PATCH_PARENT="$(mktemp -d)"
  unzip -qo "$ZIP_NAME" -d "${PATCH_PARENT}/${EXTRACT_DIR}" || {
    echo "Failed to extract pristine source for the patchset diff"; exit 1;
  }
  mkdir -p "$PATCHSET_DIR"
  (
    cd "$PATCH_PARENT" &&
    diff -ruN "${EXTRACT_DIR}" "${OLDPWD}/${EXTRACT_DIR}" > "${OLDPWD}/${PATCHSET_FILE}"
  )
  # diff exits 1 when differences exist, which is the expected case here.
  if [ -s "$PATCHSET_FILE" ]; then
    echo "  - Patchset recorded: ${PATCHSET_FILE} ($(du -h "$PATCHSET_FILE" | cut -f1))"
  else
    echo "Error: patchset diff is empty; refusing to continue without license-relevant evidence"
    exit 1
  fi
  rm -rf "$PATCH_PARENT"

  # Now compile FreeFileSync
  cd "$FFS_SOURCE_DIR" || exit 1
  # FreeFileSync's Makefile stores intermediate objects in /tmp.
  # Remove objects from a prior dependency/toolchain build so they cannot be
  # reused accidentally after changing wxWidgets, curl, or libssh2.
  echo "Cleaning previous FreeFileSync object directory..."
  rm -rf "/tmp/FreeFileSync_${ARCH}_Make"

  echo "Compiling FreeFileSync ${VERSION}..."

  make -j${MAKE_JOBS} || { echo "FreeFileSync build failed"; exit 1; }
  
  ## Verify build was successful
  BIN_DIR="${EXTRACT_DIR}/FreeFileSync/Build/Bin"
  BINARY_PATH="${WORKING_DIR}/${BIN_DIR}/${BINARY_NAME}"
  
  if [ ! -f "$BINARY_PATH" ]; then
    echo "Error: FreeFileSync binary not found at $BINARY_PATH"
    echo "Checking for any FreeFileSync binaries in build directory..."
    ls -la "${WORKING_DIR}/${BIN_DIR}/" 2>/dev/null || echo "Build directory not found"
    exit 1
  fi
  
  echo "✓ Build successful, binary size: $(du -h "$BINARY_PATH" | cut -f1)"
  
  # Cache the binary and Resources for future use
  echo "Caching FreeFileSync ${VERSION} build artifacts..."

  # This build replaced an older or dependency-incompatible cache.
  # Remove it first so stale files cannot survive or cause nested Resources/.
  rm -rf "$FFS_CACHE_DIR"
  mkdir -p "$FFS_CACHE_DIR/bin"
  
  # Cache the final binary
  cp "$BINARY_PATH" "$FFS_CACHE_DIR/bin/"
  
  # Cache Resources folder (icons, languages, sounds, CSS)
  RESOURCES_DIR="${WORKING_DIR}/${EXTRACT_DIR}/FreeFileSync/Build/Resources"
  if [ -d "$RESOURCES_DIR" ]; then
    echo "  Caching Resources folder (icons, languages, CSS)..."
    cp -R "$RESOURCES_DIR" "$FFS_CACHE_DIR/"
  else
    echo "  Warning: Resources folder not found at $RESOURCES_DIR"
  fi
  
  # Cache dependency signature
  echo "$CURRENT_DEPS" > "$DEPS_FILE"
  
  echo "✓ Cached in ${FFS_CACHE_DIR}"
  echo "  Binary: ${FFS_CACHE_DIR}/bin/${BINARY_NAME}"
  echo "  Resources: ${FFS_CACHE_DIR}/Resources/"
  echo "  Dependencies: $CURRENT_DEPS"
  
  # Update BINARY_PATH to cached location
  BINARY_PATH="${FFS_CACHE_DIR}/bin/${BINARY_NAME}"
fi

cd "$WORKING_DIR" || exit 1

echo ""
echo "=================================================="
echo "FreeFileSync build completed successfully!"
echo "Version: $VERSION"
echo "Binary location: $BINARY_PATH"
echo "=================================================="

## Step 11: Optional system installation
if [ "$INSTALL_SYSTEM" = true ]; then
  echo ""
  echo "Installing FreeFileSync to system..."
  
  # Create installation directory
  INSTALL_DIR="/opt/freefilesync"
  sudo mkdir -p "$INSTALL_DIR"
  
  # Copy the binary from cache
  sudo cp "$BINARY_PATH" "$INSTALL_DIR/" || { echo "Failed to copy binary"; exit 1; }
  
  # Copy Resources folder (icons, languages, sounds, CSS)
  if [ -d "$CACHED_RESOURCES" ]; then
    sudo cp -R "$CACHED_RESOURCES" /opt/ || { echo "Failed to copy Resources"; exit 1; }
  else
    echo "  Warning: Resources folder not found in cache"
  fi
  
  # Make sure binary is executable
  sudo chmod +x "$INSTALL_DIR/$BINARY_NAME"
  
  # Create symlink in /usr/local/bin (pointing to the actual binary name)
  sudo ln -sf "$INSTALL_DIR/$BINARY_NAME" /usr/local/bin/freefilesync || { echo "Failed to create symlink"; exit 1; }
  
  # Extract icon from Resources for desktop entry
  ICON_PATH="/opt/Resources/FreeFileSync.png"
  if [ -f "${CACHED_RESOURCES}/Icons.zip" ]; then
    sudo mkdir -p /tmp/ffs-icons
    sudo unzip -q "${CACHED_RESOURCES}/Icons.zip" -d /tmp/ffs-icons 2>/dev/null || true
    # Find the FreeFileSync logo
    ICON_SOURCE=$(sudo find /tmp/ffs-icons -name "FreeFileSync.png" -o -name "logo.png" | head -1)
    if [ -n "$ICON_SOURCE" ]; then
      sudo cp "$ICON_SOURCE" "$ICON_PATH" 2>/dev/null || true
    fi
    sudo rm -rf /tmp/ffs-icons
  fi
  
  # Create desktop entry with icon
  DESKTOP_FILE="/usr/share/applications/freefilesync.desktop"
  sudo tee "$DESKTOP_FILE" > /dev/null <<EOF
[Desktop Entry]
Type=Application
Name=FreeFileSync
Comment=Folder Comparison and Synchronization
Exec=/usr/local/bin/freefilesync
Icon=${ICON_PATH}
Terminal=false
Categories=Utility;FileTools;
Keywords=sync;synchronization;backup;compare;
EOF
  
  sudo chmod 644 "$DESKTOP_FILE"
  
  echo "  - Installed to $INSTALL_DIR"
  echo "  - Created symlink: /usr/local/bin/freefilesync"
  echo "  - Created desktop entry"
  echo ""
  echo "You can now run FreeFileSync by typing: freefilesync"
  echo "Or find it in your application menu."
fi

## Step 12: Cleanup temporary build files (in ~/Documents, NOT synced)
if [ "$CLEANUP_TEMP" = true ]; then
  echo ""
  echo "Cleaning up temporary build files in $WORKING_DIR..."
  cd "$WORKING_DIR" || exit 1
  
  # Remove FreeFileSync source
  if [ -d "$EXTRACT_DIR" ]; then
    rm -rf "$EXTRACT_DIR"
    echo "  - Removed FreeFileSync source directory"
  fi
  
  if [ -f "$ZIP_NAME" ]; then
    rm -f "$ZIP_NAME"
    echo "  - Removed FreeFileSync source archive"
  fi
  
  # Remove dependency source tarballs and extracted directories
  rm -rf libssh2-* curl-* wxWidgets-* 2>/dev/null
  rm -f libssh2-*.tar.gz curl-*.tar.gz wxWidgets-*.tar.bz2 2>/dev/null
  echo "  - Removed dependency source files"
  
  echo "  ✓ Temp files cleaned from ${WORKING_DIR}"
  echo "  ✓ Build cache preserved in ${BUILD_LIBRARY}"
fi

echo ""
echo "=================================================="
echo "Build process completed successfully!"
echo "Build library: ${BUILD_LIBRARY}"
echo "  - Dependencies cached for future builds"
echo "  - Binary ready at: $BINARY_PATH"
echo "=================================================="
