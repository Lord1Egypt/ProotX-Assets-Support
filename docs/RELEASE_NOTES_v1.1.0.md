# ProotX support bundle v1.1.0

Reproducible, provenance-backed support bundle for ProotX. This release is produced by the
support toolchain introduced in P1F2.

## Highlights

- **Reproducible support toolchain.** Every modern-lane binary is built from pinned, checksummed
  inputs; two independent clean builds produce byte-identical binaries and archives.
- **Pinned provenance.** PRoot `termux/proot v5.1.107.92`
  (`7266fb3e8516535682f5a9c8f3a7e70f6506eddb`, source archive
  `29385d1ddb619a9c4449ab512bfd55032034b22f724ddf98fc95ff300ea32135`), `termux-packages`
  `0ffca06c59752c6d52c646980d956b961064e1fc`, builder image
  `ghcr.io/termux/package-builder@sha256:374fedda…`, NDK r29.
- **Modern lane rebuilt from source at API 24** and shipped in the existing `.a10` slots.
- **Host Android 29+** uses the modern `.a10` runtime; its arm64 and x86_64 native slots are
  **16 KB page aligned** (`PT_LOAD >= 0x4000`).
- **Host Android 21–28** keeps the frozen legacy normal-slot binaries; the ProotX application
  `minSdk` remains **21**.
- **v1.0.0 remains untouched** — this is an additional release, not a replacement.

## Compatibility statement

The **modern 64-bit runtime lane is 16 KB compatible**. This release is **not** a claim of
whole-app 16 KB compliance. Some frozen legacy x86_64 normal-slot ELFs remain 4 KB aligned and are
still transported through `jniLibs` / `nativeLibraryDir`; isolating or rebuilding them is owned by
**P1F4**.

## Runtime selection (unchanged)

`ProotXFiles` selects the `.a10` slots on host API ≥ 29 and the normal slots on host API < 29.
`.a10` is a legacy ProotX filename denoting the modern host runtime slot; it does not mean API 10.

## Assets

- `arm64-v8a-assets.zip`, `armeabi-v7a-assets.zip`, `x86-assets.zip`, `x86_64-assets.zip`
- `SHA256SUMS`
- `v1.1.0-provenance.json` (release manifest)
- `v1.1.0.spdx.json` (SPDX 2.3 component inventory)

## Notes

- `proot_meta` / `proot_meta_leveldb` remain unknown-provenance frozen compatibility inputs and
  are unchanged from v1.0.0.
- Published tags and assets are never mutated or replaced; corrections require a later release.
