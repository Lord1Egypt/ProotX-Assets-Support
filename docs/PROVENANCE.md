# ProotX Support Bundle Provenance

This document records how the ProotX support bundles are built, why the historical
build was not reproducible, and exactly which inputs are pinned.

Machine-readable lock: [`provenance/sources.lock.json`](provenance/sources.lock.json).
Legacy per-file checksums: [`provenance/legacy-v1.0.0.files.sha256`](provenance/legacy-v1.0.0.files.sha256).

## Why the historical builder was not reproducible

The former builder (`buildArch.sh`, `docker/Dockerfile`, `input/main.sh`, removed in P1F2)
could not be reproduced:

- it used `FROM ubuntu:latest` (floating base image);
- it cloned `https://github.com/Lord1Egypt/proot.git` branch `merge-it` — **this repository
  is currently unavailable (HTTP 404 / "Repository not found")**;
- it cloned `termux/termux-packages` branch `android-5` (floating branch, no commit pin);
- it mutated the checked-out `termux-packages` tree in place with unguarded `sed -i`;
- it copied prebuilt binaries from `assets/<arch>/` whose build recipes were not in the
  repository.

Because `Lord1Egypt/proot@merge-it` no longer exists, the historical PRoot binaries cannot be
rebuilt as documented. They are retained as **frozen legacy inputs** (see below) and are not
represented as reproducible from source.

## Dual-lane support runtime (P1F2 decision)

ProotX keeps application `minSdk 21`. The support runtime is split by *host* Android version,
selected by `ProotXFiles` (`*.a10` slots on host API >= 29, normal slots on API < 29). P1F2 does
not change that selection logic.

| Lane | Host Android | Slots | Disposition |
|---|---|---|---|
| Legacy | API 21–28 | `proot`, `loader`, `loader32`, `libtalloc.so.2` | frozen v1.0.0 binaries; verified, not rebuilt |
| Modern | API 29+ | `proot.a10`, `loader.a10`, `loader32.a10`, `libtalloc.so.2.a10` (+ `libandroid-shmem.so`) | rebuilt from pinned source at API 24 / NDK r29 |

> `.a10` is a **legacy ProotX filename** that denotes the modern host runtime slot. It does not
> mean API 10. The filename is preserved for compatibility with `ProotXFiles`.

The modern binary is compiled against **API 24** but is only selected on **API 29+** hosts, so it
does not raise `minSdk` and does not change runtime selection semantics.

## Pinned modern-lane inputs

| Component | Pin |
|---|---|
| Builder image | `ghcr.io/termux/package-builder@sha256:374fedda8d2ce7a8ab499735d39329301c4f2f18ea4411b3cf7c93d4668768ab` |
| termux-packages | commit `0ffca06c59752c6d52c646980d956b961064e1fc` |
| PRoot source | `termux/proot` tag `v5.1.107.92`, commit `7266fb3e8516535682f5a9c8f3a7e70f6506eddb`, archive SHA-256 `29385d1ddb619a9c4449ab512bfd55032034b22f724ddf98fc95ff300ea32135` |
| libtalloc | 2.4.3, archive SHA-256 `dc46c40b9f46bb34dd97fe41f548b0e8b247b77a918576733c528e83abd854dd` |
| libandroid-shmem | tag `v0.7` |
| NDK | r29 (bundled in the builder image) |
| Build API level | 24 |
| `SOURCE_DATE_EPOCH` | `1787437959` (`termux/proot v5.1.107.92` tag-commit timestamp, 2026-08-22T22:32:39Z) |

`termux/proot v5.1.107.92` supports the complete ProotX runtime contract used by
`assets/all/execInProot.sh`: `-r/--rootfs`, `-b/--bind`, `-v/--verbose`, `-0/--root-id`, `-H`,
`-l/--link2symlink`, `-L`, `-p`, `--sysvipc`, plus `PROOT_TMP_DIR`, `PROOT_LOADER`,
`PROOT_LOADER_32` and the `loader`/`loader32` outputs.

## Historical `.a10` origin and the modern replacement

The historical builder produced a second set of binaries after applying
`-DPROTECTED_ASHMEM=1` and switching the build API from 21 to 26. Those became the `.a10`
files. Modern `termux/proot` removes the compile-time split in favour of Android-aware
runtime ashmem/memfd handling, so a single modern build can fill the modern slots. The
runtime equivalence of the modern `.a10` slot on real devices is a **P1G physical-validation
item**; P1F2 only supplies the reproducible build and slots.

## Frozen legacy inputs (not source-reproducible)

- `proot`, `loader`, `loader32`, `libtalloc.so.2` (v1.0.0) — built by the removed historical
  pipeline; retained for host API 21–28.
- `proot_meta`, `proot_meta_leveldb` — **provenance unknown**. They are not produced by
  `termux-packages`; they are custom ProotX variants selected at runtime via
  `.proot_version` / `meta_db`. They are retained verbatim and are **not** rebuilt or replaced
  in P1F2. Any rebuild/removal/migration requires a separate explicit decision.
- All non-ELF `*.sh` helpers and `stat4`/`stat8`/`uptime` data files, and the other prebuilt
  binaries (`busybox`, `busybox_static`, `dbclient`, `libcrypto.so.1.1`, `libleveldb.so.1`,
  `libtermux-auth.so`, `libutil.so`, `libc++_shared.so`) are vendored v1.0.0 inputs.

Their exact SHA-256 values are locked in `provenance/legacy-v1.0.0.files.sha256` and verified
during the build.

## Remaining 16 KB packaging debt (explicit, not hidden)

Some **64-bit legacy normal-slot** ELFs (`proot`, `libtalloc.so.2`, `proot_meta`,
`proot_meta_leveldb`, and other vendored 64-bit binaries) still have 4 KB `PT_LOAD` alignment.
Even though ProotX does not select them on Android 15/16, they are still shipped through
`jniLibs` / `nativeLibraryDir`, which may block final whole-APK / Play 16 KB compliance. P1F2
builds a reproducible modern lane but does **not** claim whole-app 16 KB compatibility. A later
P1F3/P1F4 strategy (rebuild legacy 64-bit with 16 KB alignment, move legacy binaries outside
native-library packaging, or an approved support-floor change) must be chosen and proven before
P1F can close.

## Patches

No patch is required for the API 24 modern lane. Any future recipe adjustment must be a tracked
patch file applied with `patch --fuzz=0`; blind `sed` transformations are forbidden. The API-21
`libtalloc` test-graph patch developed during the P1F2 probe is recorded in the lock as
**diagnostic-only / not adopted**.
