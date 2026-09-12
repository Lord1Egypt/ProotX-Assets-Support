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
./buildArch.sh <arch>   # arch in: arm arm64 x86 x86_64 all
```

Builds run in Docker (see `docker/`) and produce the release zips under `assets/<arch>/`.
Publish them as a GitHub release; the app build downloads the release pinned in
`app/build.gradle` (`downloadAssets` task).
