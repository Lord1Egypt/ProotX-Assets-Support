# Third-Party Notices — ProotX Support Bundle

This file records the known third-party components contained in the ProotX support bundle.
It is an attribution summary, not a legal conclusion. Component licenses are those declared
by the upstream projects/recipes; consult each project for the authoritative text.

## Source-built — modern lane (API 24 / NDK r29, reproducible)

| Component | Source | License |
|---|---|---|
| PRoot (`proot`, `loader`, `loader32`) | `https://github.com/termux/proot` (tag `v5.1.107.92`) | GPL-2.0 |
| BusyBox (`busybox`, `busybox_static`, `libbusybox.so.1.38.0`) | `https://busybox.net/downloads/busybox-1.38.0.tar.bz2` + termux patch set | GPL-2.0 |
| Dropbear (`dbclient`) | termux-packages `dropbear` 2026.94 | MIT |
| OpenSSL (`libcrypto.so.3`) | OpenSSL 3.6.3 | Apache-2.0 |
| termux-auth (`libtermux-auth.so`) | `https://github.com/termux/termux-auth` 1.5.0-1 | GPL-3.0 |
| LevelDB (`libleveldb.so`) | termux-packages `leveldb` 1.23-4 | BSD-3-Clause |
| Snappy (`libsnappy.so`) | termux-packages `libsnappy` 1.3.0 | BSD-3-Clause |
| zlib (`libz.so.1`) | termux-packages `zlib` 1.3.2 | Zlib |
| PCRE2 (`libpcre2-8.so`) | termux-packages `pcre2` 10.47 | BSD-3-Clause |
| libandroid-selinux | termux-packages `libandroid-selinux` 14.0.0.11-1 | Apache-2.0 |
| libtalloc (`libtalloc.so.2`) | `talloc-2.4.3.tar.gz` (samba.org) | GPL-3.0 |
| libandroid-shmem | `https://github.com/termux/libandroid-shmem` (tag `v0.7`) | BSD-3-Clause |
| libc++ (`libc++_shared.so`) | Android NDK r29 `29.0.14206865` | Apache-2.0 WITH LLVM-exception |
| `proot_meta` | `CypherpunkArmory/proot` @ `2a7f6d9d46552ed75cf1f2cab2391816f004877b`, `-DUSERLAND` | GPL-2.0 |
| `proot_meta_leveldb` | `CypherpunkArmory/proot` @ `998dd31b6283e07233ec9004d585bce5ab1a4c27`, `-DUSERLAND` | GPL-2.0 |

## Frozen — legacy lane (API 21–28, v1.1.0/v1.0.0 payload)

| Component | Approx. upstream origin | License (declared/known) |
|---|---|---|
| BusyBox (`busybox`) | BusyBox | GPL-2.0 |
| BusyBox static (`busybox_static`) | BusyBox v1.29.3 (musl), via UserLAnd `01ba9276` | GPL-2.0 |
| OpenSSL 1.1.x (`libcrypto.so.1.1`) | OpenSSL Project | OpenSSL + SSLeay |
| Dropbear (`dbclient`) | Dropbear SSH | MIT-style / Dropbear license |
| LevelDB (`libleveldb.so.1`) | Google LevelDB | BSD-3-Clause |
| libc++ (`libc++_shared.so`) | LLVM libc++ | Apache-2.0 with LLVM exception |
| libtalloc legacy (`libtalloc.so.2`) | Samba talloc | GPL-3.0 |
| PRoot legacy (`proot`, `loader`, `loader32`) | historical ProotX PRoot fork | GPL-2.0 |
| `libtermux-auth.so`, `libutil.so` | Termux packages | see Termux project |
| `proot_meta`, `proot_meta_leveldb` | `CypherpunkArmory/proot` @ `2a7f6d9d…` / `998dd31b…` (binary-proven) | GPL-2.0 (PRoot derivative) |

## Provenance notes

- The historical `proot_meta` / `proot_meta_leveldb` are **no longer unknown-provenance**.
  The P1F4A R1 probe recovered their exact 2019 source lineage from binary evidence
  (compiler fingerprint `clang 7.0.2`, embedded `fake_id0.c` line references) and the
  historical `-DUSERLAND` build contract. The legacy lane keeps the **frozen 2019
  binaries**; the modern lane ships **source-built replacements** from those commits.
- The frozen 2019 binaries are **not claimed to be byte-reproducible** from modern
  tooling; only their behaviour is reproduced, and that is verified by the release
  fixtures.
- The full bundle license text shipped by the support release remains `LICENSE` in this
  repository. This notices file is additive; no existing license file is modified or
  removed.
