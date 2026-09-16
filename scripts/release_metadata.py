#!/usr/bin/env python3
"""Generate release metadata for a ProotX support bundle release.

Produces, deterministically:
  - SHA256SUMS              (sorted; over the four ZIPs + manifest + sbom)
  - provenance/releases/<v>.json   (release manifest)
  - <sbom>                  (SPDX 2.3 JSON component inventory)

The per-file inventory is regenerated from the actual archive contents; it is not
taken from any earlier milestone.
"""
import argparse, hashlib, json, os, subprocess, sys, time, zipfile

ARCHIVES = ["arm64-v8a-assets.zip", "armeabi-v7a-assets.zip", "x86-assets.zip", "x86_64-assets.zip"]
MODERN_SUFFIXES = (".a10",)
MODERN_EXACT = {"libandroid-shmem.so"}

# Known components and licenses (declared by upstream recipes; unknown where not established).
COMPONENTS = [
    {"name": "proot", "version": "5.1.107.92", "license": "GPL-2.0",
     "source": "https://github.com/termux/proot", "scope": "modern .a10 source-built"},
    {"name": "libtalloc", "version": "2.4.3", "license": "GPL-3.0",
     "source": "https://www.samba.org/ftp/talloc/talloc-2.4.3.tar.gz", "scope": "modern .a10 source-built"},
    {"name": "libandroid-shmem", "version": "0.7", "license": "BSD-3-Clause",
     "source": "https://github.com/termux/libandroid-shmem", "scope": "modern source-built"},
    {"name": "busybox", "version": "NOASSERTION", "license": "GPL-2.0", "source": "NOASSERTION",
     "scope": "frozen legacy"},
    {"name": "dropbear/dbclient", "version": "NOASSERTION", "license": "NOASSERTION",
     "source": "NOASSERTION", "scope": "frozen legacy"},
    {"name": "openssl/libcrypto", "version": "1.1", "license": "OpenSSL", "source": "NOASSERTION",
     "scope": "frozen legacy"},
    {"name": "leveldb", "version": "NOASSERTION", "license": "BSD-3-Clause", "source": "NOASSERTION",
     "scope": "frozen legacy"},
    {"name": "libc++", "version": "NOASSERTION", "license": "Apache-2.0 WITH LLVM-exception",
     "source": "NOASSERTION", "scope": "frozen legacy"},
    {"name": "proot_meta", "version": "NOASSERTION", "license": "NOASSERTION",
     "source": "NOASSERTION", "scope": "frozen legacy, unknown provenance"},
    {"name": "proot_meta_leveldb", "version": "NOASSERTION", "license": "NOASSERTION",
     "source": "NOASSERTION", "scope": "frozen legacy, unknown provenance"},
]

def sha256(path):
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
        return {"elf": False, "file_type": ft}
    info = {
        "elf": True,
        "elf_class": "64" if "64-bit" in ft else ("32" if "32-bit" in ft else "?"),
        "machine": ("aarch64" if "aarch64" in ft else "arm" if "ARM" in ft
                    else "x86-64" if "x86-64" in ft else "i386" if "Intel 80386" in ft else "?"),
    }
    ph = run(["readelf", "-lW", path])
    loads, relro, interp = [], False, ""
    for line in ph.splitlines():
        s = line.strip()
        if s.startswith("LOAD"):
            t = s.split()
            if len(t) >= 8:
                loads.append(t[-1])
        if s.startswith("GNU_RELRO"):
            relro = True
        if s.startswith("INTERP"):
            interp = s.split()[-1]
    info["pt_load"] = loads
    info["gnu_relro"] = relro
    info["interp"] = interp
    dy = run(["readelf", "-dW", path])
    info["needed"] = [l.split("[")[1].rstrip("]") for l in dy.splitlines() if "(NEEDED)" in l and "[" in l]
    return info

def slot_of(name):
    if name.endswith(MODERN_SUFFIXES) or name in MODERN_EXACT or name.startswith("libandroid-shmem"):
        return "modern"
    return "legacy"

def is_modern_64_below(entry, tmpdir):
    if entry["slot"] != "modern" or not entry["elf"] or entry["elf_class"] != "64":
        return False
    return any(int(a, 16) < 0x4000 for a in entry["pt_load"])

def inventory_zip(zpath, workdir):
    entries = []
    with zipfile.ZipFile(zpath) as z:
        for name in sorted(z.namelist()):
            data = z.read(name)
            tmp = os.path.join(workdir, name.replace("/", "_"))
            with open(tmp, "wb") as f:
                f.write(data)
            info = elf_info(tmp)
            e = {"name": name, "size": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                 "slot": slot_of(name)}
            e.update(info)
            entries.append(e)
            os.remove(tmp)
    return entries

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dist", required=True)
    ap.add_argument("--version", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--source-commit", required=True)
    ap.add_argument("--repo-root", default=".")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    lock = json.load(open(os.path.join(a.repo_root, "provenance", "sources.lock.json")))
    work = os.path.join(a.out, ".inv")
    os.makedirs(work, exist_ok=True)

    archives = {}
    legacy_debt = []
    modern_64_fail = []
    all_entries = {}
    for zname in ARCHIVES:
        zpath = os.path.join(a.dist, zname)
        if not os.path.isfile(zpath):
            sys.exit(f"missing archive: {zpath}")
        entries = inventory_zip(zpath, work)
        all_entries[zname] = entries
        archives[zname] = {"size": os.path.getsize(zpath), "sha256": sha256(zpath),
                           "files": len(entries)}
        for e in entries:
            if is_modern_64_below(e, work):
                modern_64_fail.append(f"{zname}/{e['name']}")
            if e["slot"] == "legacy" and e["elf"] and e["elf_class"] == "64":
                if any(int(x, 16) < 0x4000 for x in e["pt_load"]):
                    legacy_debt.append(f"{zname}/{e['name']}")

    manifest = {
        "schemaVersion": 1,
        "releaseVersion": a.version,
        "sourceCommit": a.source_commit,
        "builderDigest": lock["builder"]["digest"],
        "termuxPackagesCommit": lock["termuxPackages"]["commit"],
        "proot": {"tag": lock["dependencies"][0]["tag"], "commit": lock["dependencies"][0]["commit"],
                  "archiveSha256": lock["dependencies"][0]["archiveSha256"]},
        "ndk": lock["toolchain"]["ndk"],
        "modernBuildApi": lock["modernSupportBuildApi"],
        "applicationMinSdk": lock["applicationMinSdk"],
        "legacySupportHostRange": lock["legacySupportHostRange"],
        "modernSupportHostRange": lock["modernSupportHostRange"],
        "sourceDateEpoch": lock["sourceDateEpoch"]["value"],
        "archives": archives,
        "modern64Bit16KAligned": len(modern_64_fail) == 0,
        "modern64BitBelow16K": modern_64_fail,
        "legacy64Bit4KDebt": sorted(legacy_debt),
        "unknownProvenanceFrozenFiles": ["proot_meta", "proot_meta_leveldb"],
        "wholeApp16KCompatible": False,
        "wholeApp16KNote": "4 KB 64-bit legacy normal-slot ELFs still ship through jniLibs/nativeLibraryDir; P1F4 owns packaging isolation.",
        "perFileInventory": all_entries,
    }
    if modern_64_fail:
        sys.exit(f"modern 64-bit 16KB gate FAILED: {modern_64_fail}")

    manifest_dir = os.path.join(a.repo_root, "provenance", "releases")
    os.makedirs(manifest_dir, exist_ok=True)
    manifest_path = os.path.join(manifest_dir, f"{a.version}.json")
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
        f.write("\n")
    # flat release-asset copy
    flat_manifest = os.path.join(a.out, f"{a.version}-provenance.json")
    with open(flat_manifest, "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
        f.write("\n")

    sbom = {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"ProotX-Assets-Support-{a.version}",
        "documentNamespace": f"https://github.com/Lord1Egypt/ProotX-Assets-Support/releases/{a.version}",
        "creationInfo": {"created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(lock["sourceDateEpoch"]["value"])),
                         "creators": ["Tool: scripts/release_metadata.py"]},
        "packages": [],
    }
    for c in COMPONENTS:
        sbom["packages"].append({
            "SPDXID": "SPDXRef-Package-" + c["name"].replace("/", "-").replace(".", "-"),
            "name": c["name"], "versionInfo": c["version"],
            "downloadLocation": c["source"], "licenseDeclared": c["license"],
            "licenseConcluded": "NOASSERTION", "copyrightText": "NOASSERTION",
            "comment": c["scope"],
        })
    sbom_path = os.path.join(a.out, f"{a.version}.spdx.json")
    with open(sbom_path, "w") as f:
        json.dump(sbom, f, indent=2, sort_keys=True)
        f.write("\n")

    # SHA256SUMS over the four archives + flat provenance manifest + sbom, sorted by name
    sums = []
    for zname in ARCHIVES:
        sums.append((zname, archives[zname]["sha256"]))
    sums.append((os.path.basename(flat_manifest), sha256(flat_manifest)))
    sums.append((os.path.basename(sbom_path), sha256(sbom_path)))
    sums.sort(key=lambda x: x[0])
    with open(os.path.join(a.out, "SHA256SUMS"), "w") as f:
        for name, digest in sums:
            f.write(f"{digest}  {name}\n")

    print(f"manifest: {manifest_path} sha256={sha256(manifest_path)}")
    print(f"flat manifest: {flat_manifest} sha256={sha256(flat_manifest)}")
    print(f"sbom:     {sbom_path} sha256={sha256(sbom_path)}")
    print(f"legacy 64-bit 4KB debt entries: {len(legacy_debt)}")
    print(f"modern 64-bit below 16K: {len(modern_64_fail)}")
    for zname in ARCHIVES:
        print(f"{zname}: {archives[zname]['size']} {archives[zname]['sha256']}")

if __name__ == "__main__":
    main()
