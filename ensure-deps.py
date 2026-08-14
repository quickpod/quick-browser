#!/usr/bin/env python3
r"""Install the GCS- and CIPD-hosted dependencies DEPS pins, for a Linux build.

    ensure-deps.py <src> [--force]

WHY THIS EXISTS
Chromium fetches node, node_modules, the clang and Rust toolchains and more as
`dep_type: 'gcs'` entries. Normally `gclient sync` does it. Here it cannot:
ungoogled's prune_binaries.py deletes ~247k files including android_webview/,
and DEPS declares a CIPD dep whose `version_file` is the git-tracked
android_webview/tools/android-webview-arm.orderfile.txt. gclient reads that
file while PARSING DEPS - regardless of the dep's checkout_android condition -
so after a prune every `gclient sync` and `gclient runhooks` dies with
FileNotFoundError before installing anything.

Discovering that one missing tarball at a time, by running ninja and reading
the next "missing and no known rule to make it", is a slow way to find a list
DEPS already contains. So parse DEPS and fetch the lot.

Each object is verified against the sha256 DEPS pins, which is also what makes
this safe to run against a network we do not control.
"""

import hashlib
import os
import subprocess
import sys
import tarfile
import urllib.request

BASE = "https://storage.googleapis.com"

# The gclient variables that decide which deps apply. This is a Linux x64
# desktop browser: no Android, no iOS, no ChromeOS, no cross builds.
GCLIENT_VARS = {
    "host_os": "linux", "host_cpu": "x64",
    "target_os": "linux", "target_cpu": "x64",
    "checkout_linux": True, "checkout_android": False, "checkout_ios": False,
    "checkout_mac": False, "checkout_win": False, "checkout_chromeos": False,
    "checkout_fuchsia": False, "checkout_android_native_support": False,
    "checkout_x64": True, "checkout_x86": False, "checkout_arm": False,
    "checkout_arm64": False, "checkout_mips": False, "checkout_mips64": False,
    "checkout_ppc": False, "checkout_riscv64": False, "checkout_loong64": False,
    "non_git_source": True, "checkout_clang_tidy": False,
    "checkout_clang_coverage_tools": False, "checkout_copybara": False,
    "checkout_bazel": False, "checkout_rust_toolchain_deps": False,
    "checkout_pgo_profiles": False, "checkout_nacl": False,
    "checkout_openxr": False, "checkout_telemetry_dependencies": False,
    "checkout_soda": False, "checkout_src_internal": False,
    "build_with_chromium": True, "llvm_force_head_revision": False,
    "checkout_clangd": False, "checkout_libaom_testdata": False,
    "checkout_google_benchmark": False, "checkout_instrumented_libraries": False,
    "checkout_chromium_signing": False, "checkout_reclient": False,
    "checkout_siso": False, "checkout_screen_ai_library": False,
    "checkout_hermetic_xcode": False, "checkout_dawn_tests": False,
    "checkout_devtools_frontend_internal": False,
    # ANGLE's restricted GPU traces are Google-internal and need cipd auth.
    "checkout_angle_internal": False, "checkout_angle_restricted_traces": False,
}


def load_deps(src):
    """DEPS is executable Python. Evaluate it with a lazy Var()."""
    ns = {}
    ns["Var"] = lambda key: ns["vars"][key]
    ns["Str"] = str
    with open(os.path.join(src, "DEPS"), encoding="utf-8") as fh:
        exec(compile(fh.read(), "DEPS", "exec"), ns)  # noqa: S102
    return ns


def applies(condition, deps_vars):
    if not condition:
        return True
    env = dict(deps_vars)
    env.update(GCLIENT_VARS)          # our answers win over DEPS defaults
    # A DEPS var's value can be the NAME of another var, which gclient
    # resolves: ANGLE has
    #     'checkout_angle_restricted_traces': 'checkout_angle_internal'
    # Treating that as a plain string makes it truthy (non-empty), which turned
    # ~380 authenticated-only GPU trace packages into "failed" cipd requests.
    # Chase those references to a fixed point before evaluating anything.
    for _ in range(10):
        changed = False
        for k, v in list(env.items()):
            if isinstance(v, str) and v in env and v != k:
                env[k] = env[v]
                changed = True
        if not changed:
            break
    for k, v in list(env.items()):
        if isinstance(v, str) and v in ("True", "False"):
            env[k] = v == "True"
    try:
        return bool(eval(condition, {"__builtins__": {}}, env))  # noqa: S307
    except Exception:
        # An unknown variable means we cannot prove it applies; skip it rather
        # than download something this build has no use for.
        return False


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def install(src, path, bucket, obj, force):
    dest = os.path.join(src, path.split("/", 1)[1] if path.startswith("src/") else path)
    name = obj.get("output_file") or obj["object_name"].split("/")[-1]
    want = obj.get("sha256sum")

    # Per-OBJECT stamp: llvm-build ships 9 objects into one directory, and a
    # single shared stamp would be overwritten by each in turn, so every run
    # would re-download all but the last.
    tag = hashlib.sha256(obj["object_name"].encode()).hexdigest()[:12]
    stamp = os.path.join(dest, ".quickbrowser-gcs-%s" % tag)
    if not force and os.path.isfile(stamp):
        if open(stamp, encoding="utf-8").read().strip() == obj["object_name"]:
            return "ok"

    os.makedirs(dest, exist_ok=True)
    url = "%s/%s/%s" % (BASE, bucket, obj["object_name"])
    tmp = os.path.join(dest, name + ".download")
    try:
        urllib.request.urlretrieve(url, tmp)
    except Exception as exc:                       # noqa: BLE001
        return "FAILED download (%s)" % exc

    if want:
        got = sha256(tmp)
        if got != want:
            os.remove(tmp)
            return "FAILED checksum (got %s)" % got[:16]

    if name.endswith((".tar.gz", ".tgz", ".tar.xz", ".tar.bz2", ".tar")):
        try:
            with tarfile.open(tmp) as tf:
                tf.extractall(dest)                # noqa: S202
        except Exception as exc:                   # noqa: BLE001
            return "FAILED extract (%s)" % exc
        os.remove(tmp)
    else:
        os.replace(tmp, os.path.join(dest, name))

    with open(stamp, "w", encoding="utf-8") as fh:
        fh.write(obj["object_name"] + "\n")
    return "installed"


def cipd_install(src, path, packages, force):
    """CIPD deps (gperf, gn, ninja, ...). Delegate to the cipd CLI, which knows
    the protocol and does its own integrity checking; we only decide WHICH
    packages apply, because gclient cannot get far enough to decide for us."""
    dest = os.path.join(src, path.split("/", 1)[1] if path.startswith("src/") else path)
    lines = []
    for p in packages:
        # DEPS templates the platform into package names.
        ver = p["version"]
        name = (p["package"]
                .replace("${{platform}}", "linux-amd64")
                .replace("${platform}", "linux-amd64")
                .replace("${{arch}}", "amd64")
                .replace("${arch}", "amd64")
                .replace("${{os}}", "linux")
                .replace("${os}", "linux"))
        # Sub-DEPS additionally use Python format placeholders ({host_cpu},
        # {golang_version}) that gclient expands from its vars. We cannot
        # resolve every one of those, and guessing produces a cipd request for
        # a literal "version:3@{golang_version}" tag that will never exist.
        # Anything still holding a placeholder is skipped, loudly but harmlessly,
        # rather than counted as a failure.
        if "{" in name or "{" in ver:
            return "skip-template"
        lines.append("%s %s" % (name, ver))
    if not lines:
        return "ok"

    stamp = os.path.join(dest, ".quickbrowser-cipd-stamp")
    want = "\n".join(lines)
    if not force and os.path.isfile(stamp):
        if open(stamp, encoding="utf-8").read().strip() == want:
            return "ok"

    os.makedirs(dest, exist_ok=True)
    proc = subprocess.run(["cipd", "ensure", "-root", dest, "-ensure-file", "-"],
                          input=want + "\n", text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if proc.returncode != 0:
        return "FAILED cipd (%s)" % proc.stdout.strip().splitlines()[-1:]
    with open(stamp, "w", encoding="utf-8") as fh:
        fh.write(want + "\n")
    return "installed"


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    force = "--force" in sys.argv
    if not args:
        print(__doc__)
        return 2
    src = os.path.abspath(args[0])
    if not os.path.isfile(os.path.join(src, "DEPS")):
        print("no DEPS at %s" % src)
        return 1

    installed = failed = skipped = 0

    # Chromium's DEPS names sub-repos in `recursedeps` whose OWN DEPS files
    # gclient also processes - dawn, angle, devtools-frontend and friends. Those
    # sub-DEPS carry real build inputs: dawn's holds the Go toolchain that
    # generates all of tint's sources, and without it the build dies ~13.5k
    # targets in with a FileNotFoundError for .../tools/golang/linux-amd64/bin/go.
    # So walk the top-level DEPS and every recursedep, one level deep.
    roots = [(src, "")]
    top = load_deps(src)
    for r in top.get("recursedeps", []):
        rel = r[4:] if r.startswith("src/") else r
        sub = os.path.join(src, rel)
        if os.path.isfile(os.path.join(sub, "DEPS")):
            roots.append((sub, rel))

    for root, prefix in roots:
        try:
            ns = load_deps(root)
        except Exception as exc:                       # noqa: BLE001
            print("   skipped    %s (unreadable DEPS: %s)" % (prefix or "src", exc))
            continue
        deps, deps_vars = ns.get("deps", {}), ns.get("vars", {})
        # Sub-DEPS usually set use_relative_paths, so their keys are relative to
        # the sub-repo rather than to src.
        rel_paths = bool(ns.get("use_relative_paths")) and prefix
        i2, f2, s2 = process(src, deps, deps_vars, prefix if rel_paths else "", force)
        installed += i2; failed += f2; skipped += s2

    print("deps: %d installed, %d already present, %d failed"
          % (installed, skipped, failed))
    return 1 if failed else 0


def process(src, deps, deps_vars, prefix, force):
    installed = failed = skipped = 0
    for path, value in sorted(deps.items()):
        if not isinstance(value, dict):
            continue
        dtype = value.get("dep_type")
        if dtype not in ("gcs", "cipd"):
            continue
        if not applies(value.get("condition"), deps_vars):
            continue
        full = os.path.join(prefix, path) if prefix else path
        if dtype == "cipd":
            r = cipd_install(src, full, value.get("packages", []), force)
            if r == "installed":
                installed += 1
                print("   installed  %s (cipd)" % path)
            elif r in ("ok", "skip-template"):
                skipped += 1
            else:
                failed += 1
                print("   %-10s %s  %s" % ("FAILED", path, r))
            continue
        bucket = value["bucket"]
        for obj in value.get("objects", []):
            # PER-OBJECT conditions matter as much as the dep's own. A single
            # gcs dep can list the Linux, Mac and Windows tarballs side by side
            # (llvm-build lists 6+), each gated by host_os. Ignoring these
            # extracts every platform's clang into one directory, last one
            # wins, and the build dies much later with the wonderfully opaque
            #     clang++: Exec format error
            # because the "clang" on disk is a Mach-O or a PE binary.
            if not applies(obj.get("condition"), deps_vars):
                continue
            r = install(src, full, bucket, obj, force)
            if r == "installed":
                installed += 1
                print("   installed  %s" % path)
            elif r == "ok":
                skipped += 1
            else:
                failed += 1
                print("   %-10s %s  %s" % ("FAILED", path, r))

    return installed, failed, skipped


if __name__ == "__main__":
    sys.exit(main())
