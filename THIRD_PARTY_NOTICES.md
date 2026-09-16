# Third-Party Notices — ProotX Support Bundle

This file records the known third-party components contained in the ProotX support bundle.
It is an attribution summary, not a legal conclusion. Component licenses are those declared
by the upstream projects/recipes; consult each project for the authoritative text.

## Source-built (modern lane, API 24 / NDK r29)

| Component | Source | License |
|---|---|---|
| PRoot | `https://github.com/termux/proot` (tag `v5.1.107.92`) | GPL-2.0 |
| libtalloc | `https://www.samba.org/ftp/talloc/talloc-2.4.3.tar.gz` | GPL-3.0 (declared by the Termux recipe) |
| libandroid-shmem | `https://github.com/termux/libandroid-shmem` (tag `v0.7`) | BSD-3-Clause |

## Vendored (frozen legacy v1.0.0 inputs)

| Component | Approx. upstream origin | License (declared/known) |
|---|---|---|
| BusyBox (`busybox`, `busybox_static`) | BusyBox | GPL-2.0 |
| OpenSSL 1.1.x (`libcrypto.so.1.1`) | OpenSSL Project | Apache-2.0 (OpenSSL 3) / OpenSSL+SSLeay (1.1.x) |
| Dropbear (`dbclient`) | Dropbear SSH | MIT-style / Dropbear license |
| LevelDB (`libleveldb.so.1`) | Google LevelDB | BSD-3-Clause |
| libc++ (`libc++_shared.so`) | LLVM libc++ | Apache-2.0 with LLVM exception |
| libtalloc legacy (`libtalloc.so.2`) | Samba talloc | GPL-3.0 |
| PRoot legacy (`proot`, `loader`, `loader32`, `.a10`) | historical ProotX PRoot fork (unavailable) | GPL-2.0 |
| `libtermux-auth.so`, `libutil.so` | Termux packages | see Termux project |
| `proot_meta`, `proot_meta_leveldb` | **unknown / legacy-vendored** | unknown (GPL-2.0 presumed, PRoot derivative) |

The full bundle license text shipped by the support release remains `LICENSE` in this
repository. This notices file is additive; no existing license file is modified or removed.

Known gap: the exact source and license of `proot_meta` / `proot_meta_leveldb` are not
recoverable from this repository. They are retained only as frozen legacy compatibility inputs
and are not redistributed as source-reproducible artifacts.
