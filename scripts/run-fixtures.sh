#!/usr/bin/env bash
#
# Run the P1F4A final-release compatibility fixtures on a booted Android
# emulator (API 30, x86_64). Invoked by CI after `adb` is available and the
# emulator reports sys.boot_completed=1.
#
# Usage: run-fixtures.sh <x86_64-assets.zip>
#
# Gates:
#   1. proot_meta sidecar parity   (legacy frozen vs modern source-built)
#   2. proot_meta_leveldb parity
#   3. UID/GID + mode parity, restart persistence, delete/recreate
#   4. static BusyBox compressFilesystem.sh / extractFilesystem.sh round-trip
#
set -euo pipefail

ZIP="${1:?usage: run-fixtures.sh <x86_64-assets.zip>}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
unzip -oq "$ZIP" -d "$WORK/cand"
LEG="$WORK/cand/legacy"
MOD="$WORK/cand/modern"
COM="$WORK/cand/common"

D=/data/local/tmp/p1f4a-fixtures
ADB="adb -s emulator-5554"
run_adb() { $ADB "$@"; }

# ---- fixture scripts -------------------------------------------------------
cat > "$WORK/fixture.sh" <<'EOF'
#!/system/bin/sh
export PATH=/system/bin
W="${FIXTURE_WORK:-/work}"
rm -rf "$W/fx"; mkdir -p "$W/fx"; cd "$W/fx" || exit 1
statline() { stat -c '%n mode=%a uid=%u gid=%g' "$1" 2>&1; }
touch a; chmod 741 a; chown 1234:5678 a
echo "STEP1"; statline a
ln a b; ln -s a c
echo "STEP2"; statline b
ls -l c 2>&1 | awk '{print "symlink_c ->", $NF}'
mv a d; chmod 600 d
echo "STEP3"; statline d
rm b
echo "STEP4"; statline d
echo "STEP5"
for f in .proot-meta-file.*; do [ -e "$f" ] || continue; printf '%s size=%s sha=%s\n' "$f" "$(wc -c < "$f" | tr -d ' ')" "$(sha256sum "$f" | cut -d' ' -f1)"; done
echo "STEP6"; ls -a1 | sort
echo "STEP7"; ls -1 /support 2>/dev/null | sort | grep -i meta || echo "no_meta_db"
echo "FIXTURE_END"
EOF
cat > "$WORK/read.sh" <<'EOF'
#!/system/bin/sh
export PATH=/system/bin
W="${FIXTURE_WORK:-/work}"
cd "$W/fx" || { echo "READBACK cd failed"; exit 1; }
echo "READBACK:"
stat -c 'd mode=%a uid=%u gid=%g' d 2>&1
echo "meta_db_present=$(ls -1 /support 2>/dev/null | grep -ci meta_db)"
echo "sidecar_count=$(ls -a1 | grep -c '^\.proot-meta-file\.')"
EOF
cp "$WORK/fixture.sh" "$LEG/fixture.sh"; cp "$WORK/fixture.sh" "$MOD/fixture.sh"
cp "$WORK/read.sh" "$LEG/read.sh";       cp "$WORK/read.sh" "$MOD/read.sh"
chmod -R 755 "$WORK/cand"

# ---- push candidates -------------------------------------------------------
run_adb shell "rm -rf $D" || true
run_adb shell "mkdir -p $D/legacy $D/modern $D/tmp"
run_adb push "$LEG/." "$D/legacy/" >/dev/null
run_adb push "$MOD/." "$D/modern/" >/dev/null
run_adb shell "chmod -R 755 $D; chmod 777 $D/tmp"

fail=0
check_parity() { # <name> <legacy-file> <modern-file>
  if diff <(grep -vE "WARNING|ignoring" "$2") <(grep -vE "WARNING|ignoring" "$3") >/dev/null; then
    echo "FIXTURE $1: PARITY PASS"
  else
    echo "FIXTURE $1: PARITY FAIL"; diff <(grep -vE "WARNING|ignoring" "$2") <(grep -vE "WARNING|ignoring" "$3") || true; fail=1
  fi
}

run_lane() { # <variant> <lane> <support-dir> <work-dir>
  local variant="$1" lane="$2" sup="$3" w="$4"
  run_adb shell "cd $D && unset LD_PRELOAD; rm -rf $sup $w; mkdir -p $sup $w; chmod 777 $sup $w
    FIXTURE_WORK=$w LD_LIBRARY_PATH=./$lane PROOT_TMP_DIR=$D/tmp \
    PROOT_LOADER=./$lane/loader PROOT_LOADER_32=./$lane/loader32 \
    ./$lane/$variant -r / -0 -l -L -v 0 -b /dev -b /proc -b /sys -b $sup:/support -w $w \
    /system/bin/sh $D/$lane/fixture.sh 2>&1" | grep -vE "WARNING|ignoring" > "$WORK/out-$variant-$lane.txt"
  run_adb shell "cd $D && unset LD_PRELOAD; FIXTURE_WORK=$w LD_LIBRARY_PATH=./$lane PROOT_TMP_DIR=$D/tmp \
    PROOT_LOADER=./$lane/loader PROOT_LOADER_32=./$lane/loader32 \
    ./$lane/$variant -r / -0 -l -L -v 0 -b /dev -b /proc -b /sys -b $sup:/support -w $w \
    /system/bin/sh $D/$lane/read.sh 2>&1" | grep -E "READBACK|d mode|meta_db_present|sidecar_count" > "$WORK/restart-$variant-$lane.txt"
}

for variant in proot_meta proot_meta_leveldb; do
  run_lane "$variant" legacy "$D/s-lg-$variant" "$D/w-lg-$variant"
  run_lane "$variant" modern "$D/s-md-$variant" "$D/w-md-$variant"
  check_parity "$variant" "$WORK/out-$variant-legacy.txt" "$WORK/out-$variant-modern.txt"
  check_parity "$variant-restart" "$WORK/restart-$variant-legacy.txt" "$WORK/restart-$variant-modern.txt"
done

# ---- static BusyBox compress/extract ---------------------------------------
BF="$WORK/bfx"
mkdir -p "$BF/support/common" "$BF/rootfs-c" "$BF/rootfs-x" "$BF/tmp"
cp "$MOD/busybox_static" "$BF/support/common/busybox_static"
cp "$COM/compressFilesystem.sh" "$COM/extractFilesystem.sh" "$BF/support/common/"
cp "$MOD/proot_meta" "$MOD/libtalloc.so.2" "$MOD/loader" "$MOD/loader32" "$BF/"
chmod -R 755 "$BF"
run_adb shell "rm -rf $D/bfx" || true
run_adb push "$BF/." "$D/bfx/" >/dev/null
run_adb shell "chmod -R 755 $D/bfx; chmod 777 $D/bfx/tmp
  C=$D/bfx/rootfs-c
  mkdir -p \$C/dir1/sub \$C/emptydir \$C/files \$C/etc/profile.d \$C/usr/local/bin \$C/sys \$C/dev \$C/proc \$C/data \$C/mnt \$C/host-rootfs \$C/sdcard \$C/bin \$C/usr/bin
  echo 'hello world' > \$C/hello.txt; printf 'abcdef' > \$C/files/data.bin; head -c 4096 /dev/zero > \$C/files/zeros.bin
  : > \$C/empty.txt; echo hidden > \$C/.hidden; echo deep > \$C/dir1/sub/deep.txt
  ln -s hello.txt \$C/link.txt
  chmod 741 \$C/hello.txt; chmod 600 \$C/files/data.bin; chmod 700 \$C/dir1
  for p in sys/kernel dev/null data/user etc/mtab etc/ld.so.preload etc/profile.d/prootx_profile.sh usr/local/bin/sudo; do echo EXCL > \$C/\$p; done
  for a in sh ln cat rm touch mkdir chmod chown ls cp mv tar gzip gunzip date echo grep find sed awk printf dd stat sleep kill; do ln -sf /support/common/busybox_static \$C/bin/\$a; done"
run_adb shell "cd $D/bfx && unset LD_PRELOAD; export PATH=/bin:/usr/bin:/support/common; LD_LIBRARY_PATH=. PROOT_TMP_DIR=$D/bfx/tmp PROOT_LOADER=$D/bfx/loader PROOT_LOADER_32=$D/bfx/loader32 TAR_PATH=/support/rootfs.tar.gz ./proot_meta -r $D/bfx/rootfs-c -0 -l -L -v 0 -b $D/bfx/support:/support -b /dev -b /proc -w / /support/common/compressFilesystem.sh >/dev/null 2>&1; echo rc=\$?"
run_adb shell "C=$D/bfx/rootfs-x; mkdir -p \$C/bin; for a in sh ln cat rm touch mkdir chmod chown ls cp mv tar gzip gunzip date echo grep find sed awk printf dd stat sleep kill; do ln -sf /support/common/busybox_static \$C/bin/\$a; done"
run_adb shell "cd $D/bfx && unset LD_PRELOAD; export PATH=/bin:/usr/bin:/support/common; LD_LIBRARY_PATH=. PROOT_TMP_DIR=$D/bfx/tmp PROOT_LOADER=$D/bfx/loader PROOT_LOADER_32=$D/bfx/loader32 ./proot_meta -r $D/bfx/rootfs-x -0 -l -L -v 0 -b $D/bfx/support:/support -b /dev -b /proc -w / /support/common/extractFilesystem.sh >/dev/null 2>&1; echo rc=\$?"
B="$D/bfx/support/common/busybox_static"
for rel in hello.txt empty.txt .hidden files/data.bin files/zeros.bin dir1/sub/deep.txt; do
  a=$(run_adb shell "$B cat $D/bfx/rootfs-c/$rel 2>/dev/null" | sha256sum | cut -c1-16)
  b=$(run_adb shell "$B cat $D/bfx/rootfs-x/$rel 2>/dev/null" | sha256sum | cut -c1-16)
  if [ "$a" = "$b" ] && [ -n "$a" ]; then echo "BUSYBOX round-trip $rel: MATCH"; else echo "BUSYBOX round-trip $rel: DIFF ($a/$b)"; fail=1; fi
done
perm=$(run_adb shell "cd $D/bfx && export PATH=/bin:/usr/bin:/support/common; LD_LIBRARY_PATH=. PROOT_TMP_DIR=$D/bfx/tmp PROOT_LOADER=$D/bfx/loader PROOT_LOADER_32=$D/bfx/loader32 ./proot_meta -r $D/bfx/rootfs-x -0 -l -L -v 0 -b $D/bfx/support:/support -b /dev -b /proc -w / /bin/stat -c '%n %a' /hello.txt /files/data.bin /dir1 2>/dev/null" | grep -v WARNING)
echo "BUSYBOX extracted perms: $perm"
echo "$perm" | grep -q "hello.txt 741" && echo "perm hello.txt PASS" || { echo "perm hello.txt FAIL"; fail=1; }

run_adb shell "rm -rf $D" || true
[ "$fail" -eq 0 ] && echo "ALL_FIXTURES_PASS" || { echo "FIXTURES_FAILED"; exit 1; }
