#!/usr/bin/env python3
"""Assemble one ABI's v1.2.0 dual-lane ProotX support archive.

The archive layout is explicit and non-ambiguous:

    common/      architecture-neutral non-native scripts/data
    legacy/      API 21-28 executable/native compatibility payload (frozen)
    modern/      API 29+ executable/native payload (source-built)
    manifest.json

`manifest.json` records every released file with its lane, kind, ABI, size,
SHA-256, ELF metadata (class/machine/SONAME/NEEDED/PT_LOAD), build API, runtime
host range, source identity and provenance/reproducibility status. It also
contains the explicit P1F4B routing contract.

This script performs the modern dependency-closure gate: every NEEDED edge of
every modern ELF must resolve either to the Android platform or to another file
in this release's `modern/` lane. A modern edge that resolves only to `legacy/`
or not at all is a hard failure.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import zipfile

# Libraries provided by the Android platform; a NEEDED edge resolving here is
# allowed and is not shipped in the bundle.
ANDROID_PLATFORM_LIBS = {
    "libc.so", "libdl.so", "libm.so", "liblog.so", "libandroid.so",
    "libstdc++.so", "libz.so", "libGLESv1_CM.so", "libGLESv2.so", "libEGL.so",
    "libjnigraphics.so", "libOpenSLES.so", "libaaudio.so", "libnativewindow.so",
    "libsync.so", "libvulkan.so", "libcamera2ndk.so", "libmediandk.so",
}

# Root executables whose NEEDED closure defines the modern lane payload.
MODERN_ROOTS = [
    "modern/proot", "modern/loader", "modern/loader32",
    "modern/proot_meta", "modern/proot_meta_leveldb",
    "modern/busybox", "modern/busybox_static", "modern/dbclient",
]

COMMON_FILES = [
    "addNonRootUser.sh", "compressFilesystem.sh", "deleteFilesystem.sh",
    "execInProot.sh", "extractFilesystem.sh", "isServerInProcTree.sh",
    "killProcTree.sh", "stat4", "stat8", "uptime",
]

# Logical runtime-name mapping. `runtimeName` is the architecture-neutral
# contract name P1F4B routes on; the per-lane filename may differ (e.g. OpenSSL
# 3 ships libcrypto.so.3 while the frozen legacy stack ships libcrypto.so.1.1).
RUNTIME_NAME = {
    "proot": "proot", "loader": "loader", "loader32": "loader32",
    "libtalloc.so.2": "libtalloc.so.2", "libandroid-shmem.so": "libandroid-shmem.so",
    "busybox": "busybox", "busybox_static": "busybox_static", "dbclient": "dbclient",
    "libtermux-auth.so": "libtermux-auth.so", "libutil.so": "libutil.so",
    "libcrypto.so.1.1": "libcrypto", "libcrypto.so.3": "libcrypto",
    "libleveldb.so.1": "libleveldb", "libleveldb.so": "libleveldb",
    "libc++_shared.so": "libc++_shared.so",
    "libz.so": "libz.so", "libandroid-selinux.so": "libandroid-selinux.so",
    "libpcre2-8.so": "libpcre2-8.so", "libsnappy.so": "libsnappy.so",
    "proot_meta": "proot_meta", "proot_meta_leveldb": "proot_meta_leveldb",
}

PACKAGING_CLASS = {
    "common": "commonData",   # refined to commonScript for executable text
    "legacy": "legacyAsset",
    "modern": "modernNative",
}

ABI_TO_ANDROID = {
    "arm64": "arm64-v8a", "arm": "armeabi-v7a", "x86": "x86", "x86_64": "x86_64",
}


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout


def elf_info(path):
    ft = run(["file", "-b", path]).strip()
    if "ELF" not in ft:
        return {"elf": False, "fileType": ft}
    info = {
        "elf": True,
        "fileType": ft,
        "elfClass": "64" if "64-bit" in ft else ("32" if "32-bit" in ft else "?"),
        "machine": ("aarch64" if "aarch64" in ft else "arm" if "ARM" in ft
                    else "x86-64" if "x86-64" in ft else "i386" if "Intel 80386" in ft
                    else "?"),
    }
    ph = run(["readelf", "-lW", path])
    loads, relro, interp = [], False, ""
    for line in ph.splitlines():
        s = line.strip()
        if s.startswith("LOAD"):
            t = s.split()
            if len(t) >= 8:
                loads.append(t[-1])
        elif s.startswith("GNU_RELRO"):
            relro = True
        elif s.startswith("INTERP"):
            interp = s.split()[-1]
    info["ptLoad"] = loads
    info["gnuRelro"] = relro
    info["interp"] = interp
    dy = run(["readelf", "-dW", path])
    info["needed"] = [l.split("[")[1].rstrip("]") for l in dy.splitlines()
                      if "(NEEDED)" in l and "[" in l]
    info["soname"] = next((l.split("[")[1].rstrip("]") for l in dy.splitlines()
                           if "(SONAME)" in l and "[" in l), "")
    return info


def kind_of(lane, name, info):
    if not info["elf"]:
        return "script" if name.endswith(".sh") else "data"
    # Android PIE executables are also ET_DYN, so ELF type cannot separate them
    # from shared libraries. Name convention (lib*.so*) plus SONAME is the
    # reliable discriminator.
    if (name.startswith("lib") and ".so" in name) or info.get("soname"):
        return "shared-library"
    return "executable"


MODE_FOR_KIND = {"script": 0o755, "executable": 0o755,
                 "shared-library": 0o644, "data": 0o644}


def build_file_record(stage, archive_path, lane, abi, lock, sources):
    full = os.path.join(stage, archive_path)
    name = os.path.basename(archive_path)
    info = elf_info(full)
    kind = kind_of(lane, name, info)
    mode = MODE_FOR_KIND[kind]
    os.chmod(full, mode)
    runtime_name = RUNTIME_NAME.get(name, name)
    rec = {
        "runtimeName": runtime_name,
        "archivePath": archive_path,
        "lane": lane,
        "kind": kind,
        "abi": abi,
        "size": os.path.getsize(full),
        "sha256": sha256_file(full),
        "executable": bool(mode & 0o111),
        "elf": info["elf"],
    }
    if info["elf"]:
        rec.update({
            "elfClass": info["elfClass"],
            "machine": info["machine"],
            "soname": info["soname"],
            "needed": info["needed"],
            "ptLoad": info["ptLoad"],
            "gnuRelro": info["gnuRelro"],
            "interp": info["interp"],
        })
    if lane == "legacy":
        rec["buildApi"] = "21"
        rec["runtimeHostRange"] = "21-28"
    elif lane == "modern":
        rec["buildApi"] = "24"
        rec["runtimeHostRange"] = "29+"
    else:
        rec["buildApi"] = "n/a"
        rec["runtimeHostRange"] = "21+"
    src = sources.get(f"{lane}:{name}") or sources.get(name) or {}
    rec["sourceIdentity"] = src.get("source", "NOASSERTION")
    rec["provenanceStatus"] = src.get("provenanceStatus", "NOASSERTION")
    rec["reproducibilityStatus"] = src.get("reproducibilityStatus", "NOASSERTION")
    return rec


def compute_closure(stage, abi):
    """Return (resolved_set, errors). resolved_set is a set of modern/ paths."""
    providers = {}
    for lane in ("modern",):
        d = os.path.join(stage, lane)
        if not os.path.isdir(d):
            continue
        for root, _, files in os.walk(d):
            for f in files:
                p = os.path.join(root, f)
                info = elf_info(p)
                if not info["elf"]:
                    continue
                rel = os.path.relpath(p, stage)
                providers[f] = rel
                if info.get("soname"):
                    providers[info["soname"]] = rel
    resolved = set()
    errors = []
    queue = [r for r in MODERN_ROOTS if os.path.exists(os.path.join(stage, r))]
    seen = set()
    while queue:
        rel = queue.pop()
        if rel in seen:
            continue
        seen.add(rel)
        info = elf_info(os.path.join(stage, rel))
        if not info["elf"]:
            continue
        resolved.add(rel)
        for need in info["needed"]:
            if need in ANDROID_PLATFORM_LIBS:
                continue
            if need in providers:
                queue.append(providers[need])
            else:
                errors.append(f"{rel}: dangling modern NEEDED '{need}'")
    # Any staged modern ELF not in the closure is build-only / unused.
    return resolved, errors


def deterministic_zip(stage, manifest_path, dest, epoch):
    dt = time.gmtime(epoch)[:6]
    names = []
    for root, _, files in os.walk(stage):
        for f in files:
            rel = os.path.relpath(os.path.join(root, f), stage)
            if rel == "manifest.json":
                continue
            names.append(rel)
    names.append("manifest.json")
    names.sort()
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as z:
        for n in names:
            src = manifest_path if n == "manifest.json" else os.path.join(stage, n)
            data = open(src, "rb").read()
            zi = zipfile.ZipInfo(n, date_time=dt)
            zi.external_attr = (0o100755 if (os.stat(src).st_mode & 0o111) else 0o100644) << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(zi, data)
    return names


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--abi", required=True, choices=sorted(ABI_TO_ANDROID))
    ap.add_argument("--stage", required=True, help="dir with common/ legacy/ modern/")
    ap.add_argument("--lock", required=True)
    ap.add_argument("--sources", required=True, help="file_sources.json")
    ap.add_argument("--out-zip", required=True)
    ap.add_argument("--version", required=True)
    ap.add_argument("--routing-out", required=True, help="aggregate routing.json")
    a = ap.parse_args()

    android_abi = ABI_TO_ANDROID[a.abi]
    lock = json.load(open(a.lock))
    sources = json.load(open(a.sources))
    epoch = lock["sourceDateEpoch"]["value"]

    files = []
    for lane in ("common", "legacy", "modern"):
        d = os.path.join(a.stage, lane)
        if not os.path.isdir(d):
            continue
        for root, _, fs in os.walk(d):
            for f in sorted(fs):
                rel = os.path.relpath(os.path.join(root, f), a.stage)
                files.append(build_file_record(a.stage, rel, lane, android_abi, lock, sources))

    # --- modern dependency closure gate ---
    resolved, errors = compute_closure(a.stage, a.abi)
    staged_modern = {os.path.relpath(os.path.join(r, f), a.stage)
                     for r, _, fs in os.walk(os.path.join(a.stage, "modern")) for f in fs}
    # Build-only modern ELFs (not reachable from any runtime root) are pruned so
    # the release carries only runtime-required files.
    pruned = []
    for rel in sorted(staged_modern - resolved):
        full = os.path.join(a.stage, rel)
        if elf_info(full)["elf"]:
            os.remove(full)
            pruned.append(rel)
    if pruned:
        print(f"[{a.abi}] pruned build-only modern files: {pruned}")
    files = [f for f in files if f["archivePath"] not in pruned]
    unused = pruned
    # modern edge must never resolve only to legacy
    legacy_names = {f for r, _, fs in os.walk(os.path.join(a.stage, "legacy")) for f in fs}
    for e in errors:
        m = re.search(r"'(.*?)'", e)
        if m and m.group(1) in legacy_names:
            errors.append(f"{e} (resolves only to legacy/)")
    if errors:
        for e in errors:
            print("CLOSURE ERROR:", e, file=sys.stderr)
        sys.exit("modern dependency closure FAILED")

    # --- modern 16 KB gate (64-bit) ---
    below = []
    for rec in files:
        if rec["lane"] == "modern" and rec["elf"] and rec.get("elfClass") == "64":
            for align in rec["ptLoad"]:
                if int(align, 16) < 0x4000:
                    below.append(rec["archivePath"])
                    break
    if below:
        sys.exit(f"modern 64-bit below-16K: {below}")

    routes = []
    by_name = {}
    for rec in files:
        by_name.setdefault(rec["runtimeName"], {})[rec["lane"]] = rec["archivePath"]
    kind_by_path = {f["archivePath"]: f["kind"] for f in files}

    def packaging_class(path):
        if not path:
            return None
        if path.startswith("modern/"):
            return "modernNative"
        if path.startswith("legacy/"):
            return "legacyAsset"
        return "commonScript" if kind_by_path.get(path) == "script" else "commonData"

    for name in sorted(by_name):
        lanes = by_name[name]
        legacy = lanes.get("legacy") or lanes.get("common")
        modern = lanes.get("modern")
        routes.append({
            "runtimeName": name,
            "api21_28": legacy,
            "api21_28PackagingClass": packaging_class(legacy),
            "api29_plus": modern,
            "api29_plusPackagingClass": packaging_class(modern),
            "packagingClass": packaging_class(legacy) or packaging_class(modern),
        })

    manifest = {
        "schemaVersion": 2,
        "releaseVersion": a.version,
        "abi": android_abi,
        "lanes": ["common", "legacy", "modern"],
        "legacySupportHostRange": lock["legacySupportHostRange"],
        "modernSupportHostRange": lock["modernSupportHostRange"],
        "modernBuildApi": lock["modernSupportBuildApi"],
        "sourceDateEpoch": epoch,
        "commonFiles": sorted(f["archivePath"] for f in files if f["lane"] == "common"),
        "legacyFiles": sorted(f["archivePath"] for f in files if f["lane"] == "legacy"),
        "modernFiles": sorted(f["archivePath"] for f in files if f["lane"] == "modern"),
        "modernBuildOnlyPruned": unused,
        "modern64BitBelow16K": below,
        "routes": routes,
        "files": files,
    }
    manifest_path = os.path.join(a.stage, "manifest.json")
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
        f.write("\n")

    names = deterministic_zip(a.stage, manifest_path, a.out_zip, epoch)
    os.remove(manifest_path)

    # aggregate routing manifest
    routing = {}
    if os.path.exists(a.routing_out):
        routing = json.load(open(a.routing_out))
    routing.setdefault("schemaVersion", 2)
    routing.setdefault("releaseVersion", a.version)
    routing.setdefault("abis", {})[android_abi] = routes
    with open(a.routing_out, "w") as f:
        json.dump(routing, f, indent=2, sort_keys=True)
        f.write("\n")

    print(f"[{a.abi}] {a.out_zip} files={len(names)} common={len(manifest['commonFiles'])} "
          f"legacy={len(manifest['legacyFiles'])} modern={len(manifest['modernFiles'])} "
          f"sha256={sha256_file(a.out_zip)}")


if __name__ == "__main__":
    main()
