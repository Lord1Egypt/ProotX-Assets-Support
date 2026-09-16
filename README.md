# ProotX-Assets-Support

Common assets used by every distribution and app in [ProotX](https://github.com/Lord1Egypt/ProotX):
the PRoot + Busybox support bundle, helper scripts, and the app catalog (icons, descriptions,
startup scripts).

## Releases

Per-architecture support bundles are published as release assets and are embedded into the
ProotX APK at build time:

- `arm64-v8a-assets.zip`
- `armeabi-v7a-assets.zip`
- `x86-assets.zip`
- `x86_64-assets.zip`

## App catalog

`apps/apps.txt` is the catalog the app fetches at runtime. Each entry has a matching
`apps/<name>/` directory with `<name>.png` (icon), `<name>.txt` (description) and
`<name>.sh` (startup script).

## Rebuilding the support bundle

```bash
./build-support.sh all          # or: arm64 | arm | x86 | x86_64
```

The modern lane (`.a10` slots, host API 29+) is built from pinned source at API 24 with
NDK r29 inside the pinned `ghcr.io/termux/package-builder` image. The normal slots and all
other files are the frozen v1.0.0 legacy inputs, verified against locked checksums and never
rebuilt here. Outputs are deterministic candidate bundles written to `dist/`; they are CI/local
artifacts only and are **not** published automatically.

All pins live in [`provenance/sources.lock.json`](provenance/sources.lock.json). See
[`docs/PROVENANCE.md`](docs/PROVENANCE.md) for the dual-lane model and the 16 KB packaging debt,
and [`docs/HISTORICAL_BUILDER.md`](docs/HISTORICAL_BUILDER.md) for the removed historical builder.

Publishing a release is a separate step (P1F3). The app build downloads the release pinned in
`app/build.gradle` (`downloadAssets` task) and remains on `v1.0.0`.

