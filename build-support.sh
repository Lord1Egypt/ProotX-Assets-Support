#!/bin/bash
#
# ProotX-Assets-Support v1.2.0 complete dual-lane builder.
#
# Produces deterministic candidate support bundles only. It never publishes.
#
# Dual-lane model (see provenance/sources.lock.json):
#   common/  architecture-neutral non-native scripts/data (from the frozen legacy set)
#   legacy/  API 21-28 frozen executable/native compatibility payload (never rebuilt)
#   modern/  API 29+ source-built executable/native payload (NDK r29, API 24)
#
# The legacy lane is the frozen v1.1.0 (== v1.0.0 for these files) input, verified
# against provenance/legacy-v1.0.0.files.sha256 and never rebuilt.
#
# Usage:
#   ./build-support.sh all
#   ./build-support.sh arm64
#   ./build-support.sh all --skip-docker      # reuse an existing modern build
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
LOCK="$ROOT/provenance/sources.lock.json"
LEGACY_SUMS="$ROOT/provenance/legacy-v1.0.0.files.sha256"
FILE_SOURCES="$ROOT/provenance/file_sources.json"
WORK="${WORK_DIR:-$ROOT/.work}"
OUT="${OUT_DIR:-$ROOT/dist}"
LEGACY_TAG="v1.1.0"
RELEASE_VERSION="v1.2.0"

# Pinned inputs (mirrored in sources.lock.json).
BUILDER_IMAGE="ghcr.io/termux/package-builder@sha256:374fedda8d2ce7a8ab499735d39329301c4f2f18ea4411b3cf7c93d4668768ab"
TERMUX_PACKAGES_REPO="https://github.com/termux/termux-packages"
TERMUX_PACKAGES_COMMIT="0ffca06c59752c6d52c646980d956b961064e1fc"
SIDECAR_REPO="https://github.com/CypherpunkArmory/proot"
SIDECAR_COMMIT="2a7f6d9d46552ed75cf1f2cab2391816f004877b"
LEVELDB_COMMIT="998dd31b6283e07233ec9004d585bce5ab1a4c27"
BUSYBOX_URL="https://busybox.net/downloads/busybox-1.38.0.tar.bz2"
BUSYBOX_SHA256="34f9ea6ff8636f2c9241153b9114eefa9e65674a45318ae1ef95bb5f31c53bb2"
MODERN_API_LEVEL="24"
SOURCE_DATE_EPOCH_VALUE="1787437959"
MODERN_PKGS="busybox dropbear openssl libandroid-selinux pcre2 zlib libc++ leveldb libsnappy termux-auth libtalloc libandroid-shmem proot"

# CA bundle pre-seed: the pinned ca-certificates recipe downloads the Mozilla
# bundle from https://curl.se, which some build networks DPI-block. We seed the
# exact hash-pinned file from the termux repo so `termux_download` verifies and
# skips the network fetch. This does NOT remove the ca-certificates dependency.
CA_PEM_SHA256="f66dff1bdf8f96060b8177976f8b7d9254bc89bc4db933d769f7384d28480bc9"
CA_DEB_URL="https://packages.termux.dev/apt/termux-main/pool/main/c/ca-certificates/ca-certificates_1%3a2026.08.13_all.deb"

die() { echo "ERROR: $*" >&2; exit 1; }
usage() { sed -n '2,18p' "$0"; exit 2; }
sha_check() { echo "$1  $2" | sha256sum -c - >/dev/null 2>&1; }

declare -A ABI_TO_TERMUX=( [arm64]="aarch64" [arm]="arm" [x86]="i686" [x86_64]="x86_64" )
declare -A ABI_TO_ANDROID=( [arm64]="arm64-v8a" [arm]="armeabi-v7a" [x86]="x86" [x86_64]="x86_64" )

ndk_root() {
  if [ -n "${ANDROID_NDK_HOME:-}" ]; then echo "$ANDROID_NDK_HOME"; return; fi
  if [ -n "${ANDROID_SDK_ROOT:-}" ] && [ -d "$ANDROID_SDK_ROOT/ndk/29.0.14206865" ]; then
    echo "$ANDROID_SDK_ROOT/ndk/29.0.14206865"; return; fi
  if [ -n "${ANDROID_HOME:-}" ] && [ -d "$ANDROID_HOME/ndk/29.0.14206865" ]; then
    echo "$ANDROID_HOME/ndk/29.0.14206865"; return; fi
  if [ -d "$HOME/Android/Sdk/ndk/29.0.14206865" ]; then
    echo "$HOME/Android/Sdk/ndk/29.0.14206865"; return; fi
  die "Android NDK r29 (29.0.14206865) not found; set ANDROID_NDK_HOME"
}

verify_lock() {
  command -v python3 >/dev/null || die "python3 required"
  python3 - "$LOCK" "$TERMUX_PACKAGES_COMMIT" "$BUILDER_IMAGE" "$SIDECAR_COMMIT" "$LEVELDB_COMMIT" <<'PY'
import json, sys
lock = json.load(open(sys.argv[1]))
assert lock["schemaVersion"] == 2, lock["schemaVersion"]
assert lock["termuxPackages"]["commit"] == sys.argv[2]
assert lock["builder"]["digest"] in sys.argv[3]
assert lock["toolchain"]["apiLevel"] == 24
assert lock["applicationMinSdk"] == 21
assert lock["metaLineage"]["sidecar"]["commit"] == sys.argv[4]
assert lock["metaLineage"]["leveldb"]["commit"] == sys.argv[5]
print("source lock schema OK")
PY
}

fetch_termux_packages() {
  local dir="$WORK/termux-packages"
  if [ ! -d "$dir/.git" ]; then
    mkdir -p "$WORK"; git init -q "$dir"
    git -C "$dir" remote add origin "$TERMUX_PACKAGES_REPO"
  fi
  git -C "$dir" fetch -q --depth 1 origin "$TERMUX_PACKAGES_COMMIT"
  git -C "$dir" checkout -q --force FETCH_HEAD
  git -C "$dir" clean -ffdx >/dev/null 2>&1 || true
  [ "$(git -C "$dir" rev-parse HEAD)" = "$TERMUX_PACKAGES_COMMIT" ] || die "termux-packages commit mismatch"
}

fetch_pinned_source() { # <name> <repo> <commit> <dest>
  local name="$1" repo="$2" commit="$3" dest="$4"
  if [ ! -d "$dest/.git" ]; then
    mkdir -p "$(dirname "$dest")"; git init -q "$dest"
    git -C "$dest" remote add origin "$repo"
  fi
  git -C "$dest" fetch -q --depth 1 origin "$commit"
  git -C "$dest" checkout -q --force FETCH_HEAD
  [ "$(git -C "$dest" rev-parse HEAD)" = "$commit" ] || die "$name commit mismatch"
}

fetch_legacy() {
  local abi="$1" lname="${ABI_TO_ANDROID[$abi]}"
  local zip="$WORK/legacy/$lname-assets.zip"
  mkdir -p "$WORK/legacy"
  if [ ! -f "$zip" ]; then
    curl -fsSL -o "$zip" \
      "https://github.com/Lord1Egypt/ProotX-Assets-Support/releases/download/$LEGACY_TAG/$lname-assets.zip"
  fi
  # verify against the frozen per-file lock (authoritative)
  local bad=0 tmp="$WORK/legacy-x-$abi"
  rm -rf "$tmp"; mkdir -p "$tmp"; unzip -oq "$zip" -d "$tmp"
  while read -r sum rel; do
    [ -z "${sum:-}" ] && continue
    case "$rel" in "$lname/"*) ;; *) continue ;; esac
    # `.a10` slots were the v1.0.0/v1.1.0 modern-lane placeholders. v1.2.0
    # replaces them with the source-built modern lane, so they are not legacy.
    case "$rel" in *.a10) continue ;; esac
    local f="$tmp/${rel#"$lname/"}"
    [ -f "$f" ] || { echo "MISSING legacy file $rel" >&2; bad=1; continue; }
    sha_check "$sum" "$f" || { echo "LEGACY digest mismatch $rel" >&2; bad=1; }
  done < "$LEGACY_SUMS"
  [ "$bad" -eq 0 ] || die "frozen legacy verification failed for $lname"
}

seed_ca_bundle() {
  local abi="$1"
  local seed="$WORK/ca-seed/$abi/etc/tls"
  [ -f "$seed/cert.pem" ] && return 0
  mkdir -p "$seed" "$WORK/ca"
  local deb="$WORK/ca/ca-certificates.deb"
  [ -f "$deb" ] || curl -fsSL -o "$deb" "$CA_DEB_URL"
  ( cd "$WORK/ca"; rm -rf x; mkdir x; cd x; ar x "$deb"; tar xf data.tar.xz )
  cp "$WORK/ca/x/data/data/com.termux/files/usr/etc/tls/cert.pem" "$seed/cert.pem"
  sha_check "$CA_PEM_SHA256" "$seed/cert.pem" || die "ca-certificates PEM hash mismatch"
}

build_modern_packages() {
  local abi="$1" tarch="${ABI_TO_TERMUX[$abi]}"
  local out="$WORK/modern/$abi" cache="$WORK/cache/$abi"
  if [ -f "$out/.done" ]; then echo ">> modern packages cached: $abi"; return 0; fi
  rm -rf "$out"; mkdir -p "$out" "$cache"
  seed_ca_bundle "$abi"
  echo ">> building modern packages: $abi ($tarch) API $MODERN_API_LEVEL, NDK r29"
  docker run --rm --user root -e HOME=/home/builder \
    --device /dev/fuse --cap-add CAP_SYS_ADMIN \
    --security-opt seccomp=unconfined --security-opt apparmor=unconfined \
    -v "$WORK/termux-packages:/home/builder/termux-packages" \
    -v "$out:/home/builder/termux-packages/output" \
    -v "$cache:/home/builder/.termux-build/_cache" \
    -v "$WORK/ca-seed/$abi/etc:/data/data/com.termux/files/usr/etc" \
    -w /home/builder/termux-packages \
    -e "TERMUX_PKG_API_LEVEL=$MODERN_API_LEVEL" \
    -e "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH_VALUE" \
    "$BUILDER_IMAGE" \
    ./build-package.sh -a "$tarch" $MODERN_PKGS
  touch "$out/.done"
}

extract_sysroot() {
  local abi="$1" tarch="${ABI_TO_TERMUX[$abi]}"
  local sys="$WORK/sysroot/$abi"
  rm -rf "$sys"; mkdir -p "$sys"
  local d
  for d in "$WORK/modern/$abi"/*.deb; do
    [ -f "$d" ] || continue
    ( cd "$sys" && ar x "$d" && tar xf data.tar.xz 2>/dev/null || true )
    rm -f "$sys"/data.tar.* "$sys"/control.tar.* "$sys"/debian-binary
  done
  [ -d "$sys/data/data/com.termux/files/usr" ] || die "sysroot extraction failed for $abi"
}

stage_prefix_for_meta() {
  local abi="$1" sys="$WORK/sysroot/$abi" tarch="${ABI_TO_TERMUX[$abi]}"
  local pfx="$WORK/prefix/$abi"; rm -rf "$pfx"; mkdir -p "$pfx"
  # only libtalloc + leveldb headers/libs are needed to link the sidecars
  cp -a "$sys/data" "$pfx/"
  echo ">> meta prefix staged: $abi"
}

build_ndk_components() {
  local ndk; ndk="$(ndk_root)"
  local busybox_src="$WORK/busybox-src"
  if [ ! -d "$busybox_src" ]; then
    mkdir -p "$busybox_src"
    curl -fsSL -o "$WORK/busybox-1.38.0.tar.bz2" "$BUSYBOX_URL"
    sha_check "$BUSYBOX_SHA256" "$WORK/busybox-1.38.0.tar.bz2" || die "busybox source hash mismatch"
    tar xjf "$WORK/busybox-1.38.0.tar.bz2" -C "$busybox_src" --strip-components=1
  fi
  local abis="$*"
  echo ">> building meta sidecars (NDK $ndk)"
  NDK="$ndk" SIDECAR_SRC="$WORK/src/sidecar" LEVELDB_SRC="$WORK/src/leveldb" \
    PREFIX_ROOT="$WORK/prefix" OUT="$WORK/ndk/meta" ABIS="$abis" \
    SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH_VALUE" \
    bash "$ROOT/scripts/build-meta-sidecars.sh"
  echo ">> building static busybox (NDK $ndk)"
  NDK="$ndk" BUSYBOX_SRC="$busybox_src" \
    BUSYBOX_PATCHES="$WORK/termux-packages/packages/busybox" \
    OUT="$WORK/ndk/busybox" WORK="$WORK/ndk/busybox-work" ABIS="$abis" \
    SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH_VALUE" \
    bash "$ROOT/scripts/build-busybox-static.sh"
}

# Copy one runtime file from the extracted sysroot with a stable name/mode.
install_from_sysroot() { # <abi> <relpath-under-prefix> <dest>
  local abi="$1" rel="$2" dest="$3"
  local src="$WORK/sysroot/$abi/data/data/com.termux/files/usr/$rel"
  [ -e "$src" ] || die "missing modern runtime file $rel for $abi"
  install -m755 "$src" "$dest"
}

stage_modern() {
  local abi="$1" stage="$2" tarch="${ABI_TO_TERMUX[$abi]}"
  local m="$stage/modern"; mkdir -p "$m"
  install_from_sysroot "$abi" bin/proot                       "$m/proot"
  install_from_sysroot "$abi" libexec/proot/loader            "$m/loader"
  if [ -e "$WORK/sysroot/$abi/data/data/com.termux/files/usr/libexec/proot/loader32" ]; then
    install_from_sysroot "$abi" libexec/proot/loader32        "$m/loader32"
  fi
  install_from_sysroot "$abi" bin/busybox                     "$m/busybox"
  install_from_sysroot "$abi" bin/dropbearmulti               "$m/dbclient"
  install_from_sysroot "$abi" lib/libtalloc.so.2              "$m/libtalloc.so.2"
  install_from_sysroot "$abi" lib/libandroid-shmem.so         "$m/libandroid-shmem.so"
  install_from_sysroot "$abi" lib/libtermux-auth.so           "$m/libtermux-auth.so"
  install_from_sysroot "$abi" lib/libcrypto.so.3              "$m/libcrypto.so.3"
  install_from_sysroot "$abi" lib/libleveldb.so               "$m/libleveldb.so"
  install_from_sysroot "$abi" lib/libsnappy.so                "$m/libsnappy.so"
  install_from_sysroot "$abi" lib/libc++_shared.so            "$m/libc++_shared.so"
  install_from_sysroot "$abi" lib/libz.so.1                   "$m/libz.so.1"
  install_from_sysroot "$abi" lib/libandroid-selinux.so       "$m/libandroid-selinux.so"
  install_from_sysroot "$abi" lib/libpcre2-8.so               "$m/libpcre2-8.so"
  install_from_sysroot "$abi" lib/libbusybox.so.1.38.0        "$m/libbusybox.so.1.38.0"
  install -m755 "$WORK/ndk/meta/$abi/proot_meta"              "$m/proot_meta"
  install -m755 "$WORK/ndk/meta/$abi/proot_meta_leveldb"      "$m/proot_meta_leveldb"
  install -m755 "$WORK/ndk/busybox/busybox_static-$abi"       "$m/busybox_static"
}

stage_common_legacy() {
  local abi="$1" stage="$2" lname="${ABI_TO_ANDROID[$abi]}"
  local src="$WORK/legacy-x-$abi"
  mkdir -p "$stage/common" "$stage/legacy"
  local f base
  for f in "$src"/*; do
    base="$(basename "$f")"
    case "$base" in
      # common: architecture-neutral non-native scripts/data
      addNonRootUser.sh|compressFilesystem.sh|deleteFilesystem.sh|execInProot.sh|extractFilesystem.sh|isServerInProcTree.sh|killProcTree.sh|stat4|stat8|uptime)
        install -m755 "$f" "$stage/common/$base" ;;
      # superseded v1.0.0/v1.1.0 modern-lane placeholders, replaced by the
      # source-built modern lane; not part of the legacy payload.
      *.a10|libandroid-shmem.so)
        : ;;
      # legacy: the frozen API 21-28 native payload
      *)
        install -m755 "$f" "$stage/legacy/$base" ;;
    esac
  done
}

assemble() {
  local abi="$1"
  local stage="$WORK/stage/$abi"
  rm -rf "$stage"; mkdir -p "$stage"
  stage_common_legacy "$abi" "$stage"
  stage_modern "$abi" "$stage"
  python3 "$ROOT/scripts/assemble_support.py" \
    --abi "$abi" --stage "$stage" --lock "$LOCK" --sources "$FILE_SOURCES" \
    --out-zip "$OUT/${ABI_TO_ANDROID[$abi]}-assets.zip" \
    --version "$RELEASE_VERSION" --routing-out "$OUT/routing.json"
}

main() {
  local target="${1:-}"; shift || true
  [ -n "$target" ] || usage
  local skip_docker=0
  for arg in "$@"; do [ "$arg" = "--skip-docker" ] && skip_docker=1; done

  local abis
  if [ "$target" = "all" ]; then abis=(arm64 arm x86 x86_64); else abis=("$target"); fi
  for abi in "${abis[@]}"; do [ -n "${ABI_TO_TERMUX[$abi]:-}" ] || die "unsupported target: $abi"; done

  verify_lock
  [ -f "$FILE_SOURCES" ] || die "missing $FILE_SOURCES"
  fetch_termux_packages
  fetch_pinned_source sidecar "$SIDECAR_REPO" "$SIDECAR_COMMIT" "$WORK/src/sidecar"
  fetch_pinned_source leveldb "$SIDECAR_REPO" "$LEVELDB_COMMIT" "$WORK/src/leveldb"
  mkdir -p "$OUT"
  rm -f "$OUT/routing.json"

  for abi in "${abis[@]}"; do fetch_legacy "$abi"; done
  for abi in "${abis[@]}"; do
    if [ "$skip_docker" = 0 ]; then
      build_modern_packages "$abi"
    else
      [ -d "$WORK/modern/$abi" ] || die "--skip-docker set but no modern build for $abi"
    fi
    extract_sysroot "$abi"
    stage_prefix_for_meta "$abi"
  done
  build_ndk_components "${abis[@]}"
  for abi in "${abis[@]}"; do assemble "$abi"; done
  echo ">> candidate bundles in $OUT"
  (cd "$OUT" && sha256sum ./*.zip routing.json)
}

main "$@"
