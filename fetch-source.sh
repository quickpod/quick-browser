#!/usr/bin/env bash
# Fetch the exact Chromium the pin names, and apply the ungoogled patches.
#
#   fetch-source.sh [workdir]        default ../../browser
#
# WHY THIS EXISTS RATHER THAN "just run fetch chromium"
# `fetch chromium` gives you TIP OF MAIN - it handed us 153.0.8007.0. The
# ungoogled-chromium patch series targets a STABLE release (151.0.7922.137),
# and a 108-patch series two majors away from its target does not apply; it
# explodes halfway through and leaves a tree nobody can reason about. So the
# checkout is pinned, both halves move together, and pin.txt is the only place
# either version is written down.
#
# Chromium ships a security release every two to four weeks. Bumping the pin is
# the routine act of maintaining this browser, not an exceptional one.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${1:-$HERE/../../browser}"
WORK="$(cd "$WORK" 2>/dev/null && pwd || { mkdir -p "$WORK" && cd "$WORK" && pwd; })"
SRC="$WORK/src-checkout/src"
UG="$WORK/ungoogled-chromium"

pin(){ awk -F= -v k="$1" '$1==k{print $2}' "$HERE/pin.txt" | tr -d ' '; }
CHROMIUM_TAG="$(pin chromium_tag)"
UNGOOGLED_TAG="$(pin ungoogled_tag)"
UNGOOGLED_URL="$(pin ungoogled_upstream)"
[ -n "$CHROMIUM_TAG" ] && [ -n "$UNGOOGLED_TAG" ] || { echo "pin.txt incomplete"; exit 1; }

export PATH="$WORK/depot_tools:$PATH"
command -v gclient >/dev/null || { echo "depot_tools not on PATH ($WORK/depot_tools)"; exit 1; }
[ -d "$SRC" ] || { echo "no checkout at $SRC - run: fetch --no-history chromium"; exit 1; }

echo "== pinning Chromium to $CHROMIUM_TAG"
cd "$SRC"
CURRENT="$(tr '\n' '.' < chrome/VERSION | sed 's/[A-Z]*=//g; s/\.$//')"
echo "   currently $CURRENT"
if [ "$CURRENT" != "$CHROMIUM_TAG" ]; then
  # The checkout is shallow (--no-history), so the tag has to be fetched
  # explicitly; a plain `git checkout <tag>` cannot find it.
  git fetch --depth 1 origin "refs/tags/$CHROMIUM_TAG:refs/tags/$CHROMIUM_TAG"
  git checkout -q --detach "refs/tags/$CHROMIUM_TAG"
  echo "   now $(tr '\n' '.' < chrome/VERSION | sed 's/[A-Z]*=//g; s/\.$//')"
  # DEPS pins every dependency per revision, so they must be re-synced to the
  # tag's versions. Without this the tree is Chromium 151 with 153's deps.
  echo "== syncing dependencies to the tag (slow)"
  gclient sync --no-history --force --reset
else
  echo "   already at the pinned tag"
fi

echo "== ungoogled-chromium $UNGOOGLED_TAG"
if [ ! -d "$UG/.git" ]; then
  git clone --depth 1 --branch "$UNGOOGLED_TAG" "$UNGOOGLED_URL" "$UG"
else
  git -C "$UG" fetch --depth 1 origin "refs/tags/$UNGOOGLED_TAG:refs/tags/$UNGOOGLED_TAG" 2>/dev/null || true
  git -C "$UG" checkout -q --detach "refs/tags/$UNGOOGLED_TAG"
fi
WANT="$(cat "$UG/chromium_version.txt")"
[ "$WANT" = "$CHROMIUM_TAG" ] || {
  echo "!! ungoogled $UNGOOGLED_TAG targets Chromium $WANT, but pin.txt says $CHROMIUM_TAG"
  echo "   fix pin.txt so both halves match, then re-run."
  exit 1
}

echo "== restoring a pristine tree before patching"
# The series is applied ALL-OR-NOTHING from a clean tree, every time.
#
# `patch --forward` returns 1 on an already-applied hunk, so a series that was
# interrupted part-way cannot simply be re-run: the second attempt collides
# with the first attempt's own work and reports a failure that looks like a
# rebase conflict. (That is exactly what happened here - a killed run left 648
# modified files behind, and the re-run died on patch 3 of upstream-fixes.)
#
# Three steps are needed, because they clean up different things:
#
#   (1) The dependency checkouts. A Chromium tree is NOT one git repo - DEPS
#       pulls ~200 more, and the series patches several of them (patch 11 hits
#       third_party/search_engines_data). `git -C src reset` cannot see inside
#       those, so their edits survive it and the next run reports "previously
#       applied" on a tree that looks clean.
#
#       Reset ONLY the nested repos the series actually touches. A blanket
#       `gclient sync --reset` here also clears the hook-built toolchains on
#       every run, so `gn gen` then dies on a missing rust-toolchain/VERSION
#       and repairing it costs a full runhooks (several GB) per patch attempt.
#       Touching just the handful of repos the patches modify is precise, and
#       leaves the toolchain alone. (`-D` is worse still and is never used: it
#       deletes hook-produced directories as "unmanaged". Note the ~247k
#       missing files seen while debugging this were NOT from sync at all -
#       measured, sync deletes zero - they are prune_binaries.py doing its job.)
python3 - "$UG/patches" "$SRC" <<'PY'
import os, subprocess, sys
patchdir, src = sys.argv[1:3]
src = os.path.abspath(src)
targets = set()
for root, _, files in os.walk(patchdir):
    for f in files:
        if not f.endswith(".patch"):
            continue
        for line in open(os.path.join(root, f), encoding="utf-8", errors="replace"):
            if line.startswith("+++ b/"):
                targets.add(line[6:].strip().split("\t")[0])
# Walk up from each patched file to the git repo that owns it.
repos = set()
for t in targets:
    d = os.path.dirname(os.path.join(src, t))
    while len(d) > len(src):
        if os.path.exists(os.path.join(d, ".git")):
            repos.add(d)
            break
        d = os.path.dirname(d)
for r in sorted(repos):
    subprocess.run(["git", "-C", r, "checkout", "--", "."],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print("   reset %d nested dependency repo(s)" % len(repos))
PY
#   (2) The main repo's tracked edits.
git -C "$SRC" reset --hard "refs/tags/$CHROMIUM_TAG" --quiet
#   (3) The files the series CREATES, which are untracked and so survive
#       reset --hard entirely. Deleting exactly the paths the patches add is
#       precise; `git clean -fd` is not, and would take gclient's dependency
#       checkouts with it.
python3 - "$UG/patches" "$SRC" <<'PY'
import os, sys
patchdir, src = sys.argv[1:3]
removed = 0
for root, _, files in os.walk(patchdir):
    for f in sorted(files):
        if not f.endswith(".patch"):
            continue
        prev = ""
        for line in open(os.path.join(root, f), encoding="utf-8", errors="replace"):
            if line.startswith("+++ ") and prev.startswith("--- /dev/null"):
                p = line[4:].strip().split("\t")[0]
                if p.startswith("b/"):
                    t = os.path.join(src, p[2:])
                    if os.path.exists(t):
                        os.remove(t)
                        removed += 1
            prev = line
print("   removed %d file(s) left by a previous run" % removed)
PY
find "$SRC" \( -name '*.rej' -o -name '*.orig' \) -delete 2>/dev/null || true

# ORDERING IS LOAD-BEARING: hooks must run BEFORE pruning.
#
# prune_binaries.py deletes ~247k files - that is its job, it strips iOS,
# Android, ChromeCast and unused third_party. But it also removes
# android_webview/, and DEPS declares a CIPD dep whose `version_file` is the
# git-tracked android_webview/tools/android-webview-arm.orderfile.txt. gclient
# reads that file while parsing DEPS, regardless of the dep's condition, so
# after a prune EVERY `gclient sync` and `gclient runhooks` dies with
# FileNotFoundError on it. The clang toolchain, Rust toolchain, node and the
# sysroot are all installed by hooks - so if hooks have not run by this point
# they never will, and the failure only shows up much later as `gn gen` unable
# to read rust-toolchain/VERSION.
echo "== running hooks (toolchains) before pruning"
gclient runhooks >/dev/null 2>&1 || { echo "!! gclient runhooks failed"; exit 1; }

echo "== applying $(find "$UG/patches" -name '*.patch' | wc -l) patches"
# ungoogled ships an ordered series; applying them out of order fails.
python3 "$UG/utils/patches.py" apply "$SRC" "$UG/patches" \
  || { echo "!! patch series failed - do NOT build this tree"; exit 1; }

echo "== pruning binaries ungoogled flags as non-free"
python3 "$UG/utils/prune_binaries.py" "$SRC" "$UG/pruning.list" || true

echo
echo "== source ready"
echo "   chromium   $(tr '\n' '.' < "$SRC/chrome/VERSION" | sed 's/[A-Z]*=//g; s/\.$//')"
echo "   ungoogled  $UNGOOGLED_TAG"
echo "   next: configure-quick-browser.sh"
