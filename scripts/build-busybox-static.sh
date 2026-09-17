#!/usr/bin/env bash
#
# Build the modern-lane `busybox_static`: a fully static, deterministic
# BusyBox 1.38.0 for Android, cross-built with NDK r29 at API 24.
#
# Source: https://busybox.net/downloads/busybox-1.38.0.tar.bz2
#   sha256 34f9ea6ff8636f2c9241153b9114eefa9e65674a45318ae1ef95bb5f31c53bb2
# Patches + config: termux-packages packages/busybox at the pinned commit.
#
# The Alpine "latest" binaries are deliberately NOT used, and the frozen legacy
# 4 KB x86_64 BusyBox is never copied into the modern lane.
#
# Required env:
#   NDK               absolute path to the NDK r29 install
#   BUSYBOX_SRC       extracted busybox-1.38.0 source tree
#   BUSYBOX_PATCHES   termux packages/busybox directory (patches + busybox.config)
#   OUT               output directory (receives busybox_static-<abi>)
# Optional env:
#   ABIS              default "arm64 arm x86 x86_64"
#   WORK              scratch dir, default <OUT>/.busybox-work
#   SOURCE_DATE_EPOCH default 1787437959
set -euo pipefail

: "${NDK:?NDK must point at an Android NDK r29 install}"
: "${BUSYBOX_SRC:?BUSYBOX_SRC must point at the extracted busybox source}"
: "${BUSYBOX_PATCHES:?BUSYBOX_PATCHES must point at termux packages/busybox}"
: "${OUT:?OUT must be set}"
ABIS="${ABIS:-arm64 arm x86 x86_64}"
WORK="${WORK:-$OUT/.busybox-work}"
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1787437959}"

BIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
export PATH="$BIN:$PATH"
mkdir -p "$OUT" "$WORK"

declare -A CC=(
  [arm64]=aarch64-linux-android24-clang
  [arm]=armv7a-linux-androideabi24-clang
  [x86]=i686-linux-android24-clang
  [x86_64]=x86_64-linux-android24-clang
)

patched="$WORK/patched"
if [ ! -d "$patched" ]; then
  cp -a "$BUSYBOX_SRC" "$patched"
  ( cd "$patched"
    for p in "$BUSYBOX_PATCHES"/*.patch; do
      # @TERMUX_PREFIX@ is substituted to empty for a neutral static build.
      # Default fuzz matches the termux build system; --fuzz=0 is too strict for
      # this patch set against the 1.38.0 context.
      sed 's/@TERMUX_PREFIX@//g' "$p" | patch --silent -p1 \
        || { echo "PATCH FAIL: $p" >&2; exit 1; }
    done
    echo "patches applied: $(ls "$BUSYBOX_PATCHES"/*.patch | wc -l)" )
fi

for abi in $ABIS; do
  cc="${CC[$abi]:-}"
  [ -n "$cc" ] || { echo "unsupported ABI: $abi" >&2; exit 2; }
  d="$WORK/$abi"; rm -rf "$d"; cp -a "$patched" "$d"
  sed -e 's|@TERMUX_HOST_PLATFORM@-||' -e 's|@TERMUX_SYSROOT@||' \
      -e 's|@TERMUX_CFLAGS@||' -e 's|@TERMUX_LDFLAGS@||' -e 's|@TERMUX_LDLIBS@||' \
      -e 's|@TERMUX_PREFIX@||g' "$BUSYBOX_PATCHES/busybox.config" > "$d/.config"
  sed -e 's|^# CONFIG_STATIC is not set|CONFIG_STATIC=y|' \
      -e 's|^# CONFIG_PIE is not set|CONFIG_PIE=y|' \
      -e 's|^CONFIG_SELINUX=y|# CONFIG_SELINUX is not set|' \
      -e 's|^CONFIG_PREFIX=""|CONFIG_PREFIX="/"|' "$d/.config" > "$d/.config.new"
  mv "$d/.config.new" "$d/.config"
  grep -q '^CONFIG_STATIC=y' "$d/.config" || echo 'CONFIG_STATIC=y' >> "$d/.config"
  grep -q '^CONFIG_PIE=y' "$d/.config" || echo 'CONFIG_PIE=y' >> "$d/.config"
  ( cd "$d"
    # `yes` dies of SIGPIPE when oldconfig finishes; tolerate it under pipefail.
    yes "" | make oldconfig >/dev/null 2>&1 || true
    make -j"$(nproc)" CC="$cc" HOSTCC=cc STRIP="$BIN/llvm-strip" \
      AR="$BIN/llvm-ar" NM="$BIN/llvm-nm" \
      CONFIG_STATIC=y CONFIG_PIE=y EXTRA_LDFLAGS="-Wl,--allow-multiple-definition" \
      >"$OUT/busybox_static-$abi.log" 2>&1 )
  install -m755 "$d/busybox" "$OUT/busybox_static-$abi"
  echo "[$abi] busybox_static OK needed=$(readelf -dW "$OUT/busybox_static-$abi" 2>/dev/null | grep -c NEEDED) align=$(readelf -lW "$OUT/busybox_static-$abi" | awk '/LOAD/{printf "%s ",$NF}') sha=$(sha256sum "$OUT/busybox_static-$abi" | cut -c1-16)"
done
