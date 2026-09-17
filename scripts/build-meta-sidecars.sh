#!/usr/bin/env bash
#
# Build the modern-lane metadata sidecars `proot_meta` and `proot_meta_leveldb`.
#
# Source lineage (binary-proven by the P1F4A R1 probe, not guessed):
#   sidecar   CypherpunkArmory/proot @ 2a7f6d9d46552ed75cf1f2cab2391816f004877b
#   leveldb   CypherpunkArmory/proot @ 998dd31b6283e07233ec9004d585bce5ab1a4c27
#
# The frozen 2019 binaries were compiled with -DUSERLAND. USERLAND gates the
# fake_id0 metadata paths (chown.c/open.c/fake_id0.c, META_TAG/DB_PATH); without
# it the built binary does not reproduce the frozen `.proot-meta-file` /
# `/support/meta_db` behavior. -DUSERLAND is therefore a required build input,
# not a stylistic choice, and must never be removed.
#
# Toolchain: Android NDK r29 (29.0.14206865), build API 24.
#
# Required env:
#   NDK           absolute path to the NDK r29 install
#   SIDECAR_SRC   checkout of CypherpunkArmory/proot @ 2a7f6d9...
#   LEVELDB_SRC   checkout of CypherpunkArmory/proot @ 998dd31...
#   PREFIX_ROOT   directory holding <abi>/data/data/com.termux/files/usr with
#                 libtalloc (+ libleveldb) headers and libraries
#   OUT           output directory (receives <abi>/proot_meta{,_leveldb})
# Optional env:
#   ABIS                 default "arm64 arm x86 x86_64"
#   SOURCE_DATE_EPOCH    default 1787437959
set -euo pipefail

: "${NDK:?NDK must point at an Android NDK r29 install}"
: "${SIDECAR_SRC:?SIDECAR_SRC must point at the 2a7f6d9 checkout}"
: "${LEVELDB_SRC:?LEVELDB_SRC must point at the 998dd31 checkout}"
: "${PREFIX_ROOT:?PREFIX_ROOT must hold the staged termux prefix}"
: "${OUT:?OUT must be set}"
ABIS="${ABIS:-arm64 arm x86 x86_64}"
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1787437959}"

BIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
export PATH="$BIN:$PATH"
mkdir -p "$OUT"

declare -A CC=(
  [arm64]=aarch64-linux-android24-clang
  [arm]=armv7a-linux-androideabi24-clang
  [x86]=i686-linux-android24-clang
  [x86_64]=x86_64-linux-android24-clang
)

# The proot loader must be a fixed-address, build-id-free, static-nostdlib image.
# LOADER_ADDRESS is read from the source's arch.h so the link script matches the
# historical contract (0x600000000000 for 64-bit, 0xa0000000 for the x86_64 m32
# loader). --rosegment preserves the original segment layout.
loader_address() { # <cc> [extra-cflags...]
  local cc="$1"; shift
  "$cc" "$@" -E -dM -DNO_LIBC_HEADER "$SIDECAR_SRC/src/arch.h" 2>/dev/null \
    | awk '/^#define LOADER_ADDRESS/{print $3}' | head -1
}

for abi in $ABIS; do
  cc="${CC[$abi]:-}"
  [ -n "$cc" ] || { echo "unsupported ABI: $abi" >&2; exit 2; }
  p="$PREFIX_ROOT/$abi/data/data/com.termux/files/usr"
  mkdir -p "$OUT/$abi"

  a64="$(loader_address "$cc")"
  ll64="-static -nostdlib -Wl,--build-id=none,-Ttext=${a64},--rosegment,-z,noexecstack"
  ll32=""
  if [ "$abi" = x86_64 ]; then
    a32="$(loader_address "$cc" -m32)"
    ll32="-static -nostdlib -Wl,--build-id=none,-Ttext=${a32},--rosegment,-z,noexecstack"
  fi

  for pair in "sidecar:proot_meta:" "leveldb:proot_meta_leveldb:-lleveldb"; do
    src="${pair%%:*}"; rest="${pair#*:}"; name="${rest%%:*}"; extra="${rest#*:}"; extra="${extra#:}"
    if [ "$src" = sidecar ]; then tree="$SIDECAR_SRC"; else tree="$LEVELDB_SRC"; fi
    ( cd "$tree"
      make -C src clean >/dev/null 2>&1 || true
      make -C src -j"$(nproc)" proot VERSION=0.1 CC="$cc" \
        STRIP="$BIN/llvm-strip" AR="$BIN/llvm-ar" \
        OBJCOPY="$BIN/llvm-objcopy" OBJDUMP="$BIN/llvm-objdump" \
        "LOADER_LDFLAGS=$ll64" "LOADER_LDFLAGS-m32=$ll32" \
        CPPFLAGS="-DUSERLAND -DARG_MAX=131072 -I. -I$p/include -Wno-implicit-function-declaration -Wno-int-conversion -Wno-implicit-int" \
        LDFLAGS="-L$p/lib -landroid -ltalloc $extra" ) >"$OUT/$name-$abi.log" 2>&1 \
      || { echo "[$abi] $name FAILED"; tail -5 "$OUT/$name-$abi.log" >&2; exit 1; }
    install -m755 "$tree/src/proot" "$OUT/$abi/$name"
    echo "[$abi] $name OK align=$(readelf -lW "$OUT/$abi/$name" | awk '/LOAD/{printf "%s ",$NF}') sha=$(sha256sum "$OUT/$abi/$name" | cut -c1-16)"
  done
done
