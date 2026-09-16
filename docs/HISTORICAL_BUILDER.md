# Historical Support Builder (removed in P1F2)

The original support-bundle builder was removed in P1F2 because it was not reproducible. For the
record, it consisted of:

- `buildArch.sh` — thin wrapper around `docker-compose`.
- `docker/Dockerfile` — `FROM ubuntu:latest` (floating base image).
- `docker/{main,arm,arm64,x86,x86_64}.yml` — compose files selecting the build command.
- `input/main.sh` — the actual build script.

## What `input/main.sh` did

1. `apt install` tooling inside the container.
2. `git clone https://github.com/Lord1Egypt/proot.git` then `git checkout merge-it`.
   **This repository is unavailable (HTTP 404).**
3. `git clone https://github.com/termux/termux-packages.git` then `git checkout android-5`
   (floating branch, no commit pin).
4. In-place `sed -i` mutations of the checked-out `termux-packages` tree:
   - `packages/proot/build.sh` (`TERMUX_PKG_SRCDIR` → `PROOT_DIR`, `make` clean insert,
     `-DARG_MAX` → `-DPROTECTED_ASHMEM=1 -DARG_MAX`),
   - `scripts/build/termux_step_setup_variables.sh` (`"21"` → `"26"`),
   - `packages/ca-certificates/build.sh` (hash substitution).
5. Build `libtalloc` + `proot` twice — once normally and once at API 26 with
   `PROTECTED_ASHMEM` — producing `proot`, `loader`, `loader32`, `libtalloc.so.2` and the
   `.a10` variants.
6. Copy prebuilt binaries from the committed `assets/<arch>/` and `assets/all/` directories
   into the bundle, then zip.

Because the PRoot source fork is gone and every input was floating, the resulting v1.0.0
binaries cannot be reproduced from source as documented. They are retained as frozen legacy
inputs; see [`PROVENANCE.md`](PROVENANCE.md).

The replacement is [`build-support.sh`](../build-support.sh), which pins the builder image
digest, the `termux-packages` commit, the PRoot tag/commit/archive checksum, verifies the
frozen legacy inputs, builds only the modern lane, and produces deterministic archives.
