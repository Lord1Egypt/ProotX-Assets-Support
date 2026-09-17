# ProotX support bundle v1.2.0 — complete dual-lane support release

This is the first **complete explicit dual-lane** support bundle. It replaces the
ambiguous flat layout of v1.0.0/v1.1.0 with an explicit, machine-readable
per-ABI schema:

```
common/      architecture-neutral non-native scripts/data
legacy/      API 21–28 executable/native compatibility payload (frozen)
modern/      API 29+ executable/native payload (source-built)
manifest.json
```

Each archive also carries an explicit **routing contract** (`manifest.json`
`routes`, and a top-level `routing.json`) so P1F4B can route every logical
runtime name deterministically instead of inferring behaviour from filenames.

## What changed

- **Legacy lane (host API 21–28).** The frozen v1.1.0/v1.0.0 native payload is
  preserved byte-for-byte and verified against
  `provenance/legacy-v1.0.0.files.sha256`. These files may remain 4 KB aligned;
  they are intentionally **not** packaged through Android `nativeLibraryDir`.
- **Modern lane (host API 29+).** Every native component is rebuilt from pinned
  source with NDK r29 (`29.0.14206865`) at API 24. All modern 64-bit ELFs have
  `PT_LOAD >= 0x4000`.
- **Historical metadata behaviour preserved.** `proot_meta` and
  `proot_meta_leveldb` are built from the binary-proven 2019
  `CypherpunkArmory/proot` lineages with the historical `-DUSERLAND` contract.
  Final-release fixtures reproduce the frozen `.proot-meta-file.` sidecar and
  `/support/meta_db` behaviour with byte-identical parity.
- **No filesystem migration.** `.proot_version = _meta` and
  `.proot_version = _meta_leveldb` semantics are unchanged; existing sessions are
  not converted and no metadata database is rewritten.
- **Modern static BusyBox.** `busybox_static` is reproducibly built from BusyBox
  1.38.0 with the pinned termux patch set; it is fully static (`NEEDED=0`) and
  the unmodified `compressFilesystem.sh` / `extractFilesystem.sh` fixtures pass.
- **Modern crypto/DB stack.** Dropbear 2026.94, OpenSSL 3.6.3, termux-auth
  1.5.0-1, LevelDB 1.23-4, libc++ (NDK r29), and their full dependency closure.

## Determinism

- `SOURCE_DATE_EPOCH=1787437959`.
- Two independent clean builds must produce byte-identical archives, routing
  manifests and release metadata.
- Per-file SHA-256, ELF metadata, build API, runtime host range, source identity
  and provenance status are recorded in every archive's `manifest.json`.

## Important

**This release is the support bundle only.** P1F4B is still required to integrate
this schema into the Android APK/AAB: legacy files must be packaged outside
`nativeLibraryDir` and modern files inside it. This release does **not** make the
ProotX APK/AAB fully 16 KB compatible.
