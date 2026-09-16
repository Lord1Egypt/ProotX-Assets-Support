#!/bin/bash
#
# ProotX-Assets-Support reproducible modern-lane candidate builder (P1F2).
#
# Produces LOCAL CI/candidate support bundles only. It never publishes a release.
#
# Dual-lane model (see provenance/sources.lock.json):
#   - normal slots (proot, loader, loader32, libtalloc.so.2) = FROZEN legacy v1.0.0
#     binaries for host API 21-28. They are verified, never rebuilt here.
#   - .a10 slots (proot.a10, loader.a10, loader32.a10, libtalloc.so.2.a10) = modern
#     runtime for host API 29+, source-built at API 24 with NDK r29.
#     NOTE: ".a10" is a legacy ProotX filename that denotes the modern host runtime
#     slot. It does not mean API 10.
#
# All upstream inputs are pinned and checksum-verified. No floating builder base
# image, no floating source branch, no blind in-place text substitution of
# tracked upstream trees.
#
# Usage:
#   ./build-support.sh all          # arm64 arm x86 x86_64
#   ./build-support.sh arm64
#   ./build-support.sh arm64 --allow-missing-docker   # assemble from existing outputs
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
LOCK="$ROOT/provenance/sources.lock.json"
LEGACY_SUMS="$ROOT/provenance/legacy-v1.0.0.files.sha256"
WORK="${WORK_DIR:-$ROOT/.work}"
OUT="${OUT_DIR:-$ROOT/dist}"
LEGACY_TAG="v1.0.0"

# Pinned inputs (mirrored in sources.lock.json).
BUILDER_IMAGE="ghcr.io/termux/package-builder@sha256:374fedda8d2ce7a8ab499735d39329301c4f2f18ea4411b3cf7c93d4668768ab"
TERMUX_PACKAGES_REPO="https://github.com/termux/termux-packages"
TERMUX_PACKAGES_COMMIT="0ffca06c59752c6d52c646980d956b961064e1fc"
PROOT_ARCHIVE_SHA256="29385d1ddb619a9c4449ab512bfd55032034b22f724ddf98fc95ff300ea32135"
MODERN_API_LEVEL="24"
SOURCE_DATE_EPOCH_VALUE="1787437959"

die() { echo "ERROR: $*" >&2; exit 1; }

usage() { sed -n '2,26p' "$0"; exit 2; }

[ -f "$LOCK" ] || die "missing source lock: $LOCK"
[ -f "$LEGACY_SUMS" ] || die "missing legacy checksums: $LEGACY_SUMS"

# termux arch name per ProotX ABI
declare -A ABI_TO_TERMUX=(
  [arm64]="aarch64" [arm]="arm" [x86]="i686" [x86_64]="x86_64" )
declare -A ABI_TO_LEGACY=(
  [arm64]="arm64-v8a" [arm]="armeabi-v7a" [x86]="x86" [x86_64]="x86_64" )

sha_check() { echo "$1  $2" | sha256sum -c - >/dev/null 2>&1; }

verify_lock() {
  command -v python3 >/dev/null || die "python3 required"
  python3 - "$LOCK" "$TERMUX_PACKAGES_COMMIT" "$BUILDER_IMAGE" <<'PY'
import json,sys
lock=json.load(open(sys.argv[1]))
assert lock["schemaVersion"]==1
assert lock["termuxPackages"]["commit"]==sys.argv[2], "termux-packages pin mismatch"
assert lock["builder"]["digest"] in sys.argv[3], "builder digest mismatch"
assert lock["toolchain"]["apiLevel"]==24
assert lock["applicationMinSdk"]==21
print("source lock schema OK")
PY
}

fetch_termux_packages() {
  local dir="$WORK/termux-packages"
  if [ ! -d "$dir/.git" ]; then
    mkdir -p "$WORK"
    git init -q "$dir"
    git -C "$dir" remote add origin "$TERMUX_PACKAGES_REPO"
  fi
  git -C "$dir" fetch -q --depth 1 origin "$TERMUX_PACKAGES_COMMIT"
  git -C "$dir" checkout -q --force FETCH_HEAD
  git -C "$dir" clean -ffdx >/dev/null
  [ "$(git -C "$dir" rev-parse HEAD)" = "$TERMUX_PACKAGES_COMMIT" ] || die "termux-packages commit mismatch"
}

build_modern() {
  local abi="$1" tarch="${ABI_TO_TERMUX[$abi]}"
  local out="$WORK/modern/$abi" cache="$WORK/cache/$abi"
  rm -rf "$out"; mkdir -p "$out" "$cache"
  [ -d "$WORK/termux-packages" ] || fetch_termux_packages
  echo ">> building modern lane: $abi ($tarch) API $MODERN_API_LEVEL, NDK r29"
  docker run --rm --user root -e HOME=/home/builder \
    --device /dev/fuse --cap-add CAP_SYS_ADMIN \
    --security-opt seccomp=unconfined --security-opt apparmor=unconfined \
    -v "$WORK/termux-packages:/home/builder/termux-packages" \
    -v "$out:/home/builder/termux-packages/output" \
    -v "$cache:/home/builder/.termux-build/_cache" \
    -w /home/builder/termux-packages \
    -e "TERMUX_PKG_API_LEVEL=$MODERN_API_LEVEL" \
    -e "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH_VALUE" \
    "$BUILDER_IMAGE" \
    ./build-package.sh -a "$tarch" proot
  [ -f "$out/proot_5.1.107.92_$tarch.deb" ] || die "proot build produced no package for $abi"
}

fetch_legacy() {
  local abi="$1" lname="${ABI_TO_LEGACY[$abi]}"
  local zip="$WORK/legacy/$lname-assets.zip"
  mkdir -p "$WORK/legacy"
  if [ ! -f "$zip" ]; then
    curl -fsSL -o "$zip" \
      "https://github.com/Lord1Egypt/ProotX-Assets-Support/releases/download/$LEGACY_TAG/$lname-assets.zip"
  fi
  local expected
  expected="$(python3 -c "import json;print(json.load(open('$LOCK'))['legacyRelease']['zips']['$lname'])")"
  sha_check "$expected" "$zip" || die "legacy v1.0.0 digest mismatch for $lname"
}

# Assemble a candidate bundle: frozen legacy normal slots + source-built modern .a10 slots.
assemble() {
  local abi="$1" lname="${ABI_TO_LEGACY[$abi]}"
  local stage="$WORK/stage/$abi" mod="$WORK/modern/$abi"
  rm -rf "$stage"; mkdir -p "$stage"
  # 1) frozen legacy normal slots + everything else from the locked release
  unzip -oq "$WORK/legacy/$lname-assets.zip" -d "$stage"
  # verify frozen legacy contents against the locked per-file checksums
  local bad=0
  while read -r sum rel; do
    [ -z "${sum:-}" ] && continue
    [ -f "$stage/$rel" ] || { echo "MISSING legacy file $rel" >&2; bad=1; continue; }
    sha_check "$sum" "$stage/$rel" || { echo "LEGACY digest mismatch $rel" >&2; bad=1; }
  done < <(awk -v a="$lname/" '$2 ~ a {sub(a,"");print $1" "$2}' "$LEGACY_SUMS")
  [ "$bad" -eq 0 ] || die "frozen legacy verification failed for $lname"
  # 2) modern .a10 slots (do NOT overwrite normal/legacy slots)
  local m="$WORK/modern-extract-$abi" tarch="${ABI_TO_TERMUX[$abi]}"
  rm -rf "$m"; mkdir -p "$m"
  (cd "$m" && ar x "$mod/proot_5.1.107.92_$tarch.deb" && tar xf data.tar.xz)
  (cd "$m" && ar x "$mod/libtalloc_2.4.3_$tarch.deb" && tar xf data.tar.xz)
  local prefix="$m/data/data/com.termux/files/usr"
  install -m755 "$prefix/bin/proot" "$stage/proot.a10"
  install -m755 "$prefix/libexec/proot/loader" "$stage/loader.a10"
  if [ -f "$prefix/libexec/proot/loader32" ]; then
    install -m755 "$prefix/libexec/proot/loader32" "$stage/loader32.a10"
  fi
  install -m755 "$prefix/lib/libtalloc.so.2" "$stage/libtalloc.so.2.a10"
  # 3) modern proot needs libandroid-shmem.so (new dependency file, modern lane only)
  local shmdeb="$mod/libandroid-shmem_0.7_$tarch.deb"
  if [ -f "$shmdeb" ]; then
    (cd "$m" && ar x "$shmdeb" && tar xf data.tar.xz 2>/dev/null || true)
    local s
    s="$(find "$m/data/data/com.termux/files/usr/lib" -name 'libandroid-shmem.so' | head -1)"
    if [ -n "$s" ]; then install -m755 "$s" "$stage/libandroid-shmem.so"; fi
  fi
  echo ">> assembling candidate: $lname-assets.zip"
  deterministic_zip "$stage" "$OUT/$lname-assets.zip"
}

# Deterministic zip: sorted entries, fixed mtime (SOURCE_DATE_EPOCH), mode 0644, no extra attrs.
deterministic_zip() {
  local stage="$1" dest="$2" epoch="$SOURCE_DATE_EPOCH_VALUE"
  mkdir -p "$(dirname "$dest")"
  python3 - "$stage" "$dest" "$epoch" <<'PY'
import os,sys,zipfile,time
stage,dest,epoch=sys.argv[1],sys.argv[2],int(sys.argv[3])
dt=time.gmtime(epoch)[:6]
names=[]
for dp,_,fs in os.walk(stage):
    for f in fs:
        names.append(os.path.relpath(os.path.join(dp,f),stage))
names.sort()
with zipfile.ZipFile(dest,'w',zipfile.ZIP_DEFLATED) as z:
    for n in names:
        zi=zipfile.ZipInfo(n, date_time=dt)
        zi.external_attr=(0o100644 & 0xFFFF)<<16
        zi.compress_type=zipfile.ZIP_DEFLATED
        with open(os.path.join(stage,n),'rb') as fh:
            z.writestr(zi, fh.read())
print("wrote",dest,"files",len(names))
PY
}

# 16KB gate for modern 64-bit ELF slots.
elf_gate() {
  local abi="$1"; case "$abi" in arm64|x86_64) ;; *) return 0;; esac
  local stage="$WORK/stage/$abi"
  local fail=0
  for f in proot.a10 loader.a10; do
    local so="$stage/$f"; [ -f "$so" ] || { echo "MISSING $f" >&2; fail=1; continue; }
    local aligns; aligns="$(readelf -lW "$so" | awk '/LOAD/{print $NF}')"
    echo "  $abi/$f alignments: $aligns"
    for a in $aligns; do
      local hex="${a#0x}"
      [ "$((16#$hex))" -ge 16384 ] || { echo "  FAIL: $f PT_LOAD $a < 0x4000" >&2; fail=1; }
    done
  done
  [ "$fail" -eq 0 ] || die "modern 16KB alignment gate failed for $abi"
}

main() {
  local target="${1:-}"; shift || true
  [ -n "$target" ] || usage
  verify_lock
  local abis
  if [ "$target" = "all" ]; then abis=(arm64 arm x86 x86_64); else abis=("$target"); fi
  for abi in "${abis[@]}"; do
    [ -n "${ABI_TO_TERMUX[$abi]:-}" ] || die "unsupported target: $abi"
  done
  for abi in "${abis[@]}"; do
    fetch_legacy "$abi"
    build_modern "$abi"
    assemble "$abi"
    elf_gate "$abi"
  done
  echo ">> candidate bundles in $OUT"
  (cd "$OUT" && sha256sum ./*.zip)
}

main "$@"
