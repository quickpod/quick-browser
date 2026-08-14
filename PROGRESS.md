# Quick Browser — build status and how to resume

**Last updated: 2026-08-13.** Written mid-build so work can resume after a
reboot / disk change. Nothing here depends on a running session.

---

## Where it got to

| Stage | State |
|---|---|
| Licensing verdict | **done** — [LICENSING.md](LICENSING.md), BSD-3-Clause, permissive |
| Icon / branding assets | **done** — `branding/make-icon.py` |
| Source pinned to 151.0.7922.137 | **done** — `fetch-source.sh` |
| 108 ungoogled patches applied | **done** |
| Branding applied to the tree | **done** — 729 renames, icons, BRANDING |
| `gn gen` | **done** — free codecs only, official build |
| `ninja chrome` | **done** — 2026-08-14, 0 failures, ~4h; binary stripped 510→316 MB |
| deb / .usi / apt packaging | **done** — rev-2 deb (125 MB), signed .usi, live on r2.quickopen.io |
| Screenshots + portal listing | **done** — 6 shots (3 scenes × 2 themes), published on quickopen.ai |
| Verified on stock noble + Quick OS VM | **done** — apt install end-to-end, SUID sandbox intact |
| Windows .exe installer | **queued** — needs a Windows Chromium build host (MSVC); platforms stays ["linux"] until the 2-4-week security-rebuild cadence is provable there |

The build workspace is `../../browser/` (NOT in git). If the disk holding it is
replaced, everything under it is rebuildable from this repo — see below.

## Resume

```bash
cd /home/ubuntu/quickopen
export PATH=$PWD/browser/depot_tools:$PATH

# 0. Only if browser/ was lost:
#    git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git browser/depot_tools
#    (cd browser/depot_tools && ./ensure_bootstrap)
#    mkdir -p browser/src-checkout && cd browser/src-checkout && fetch --no-history chromium

./repos/quick-browser/fetch-source.sh                       # pin + patch + prune
python3 ./repos/quick-browser/branding/apply-branding.py browser/src-checkout/src
python3 ./repos/quick-browser/ensure-deps.py browser/src-checkout/src
./repos/quick-browser/configure-quick-browser.sh

cd browser/src-checkout/src
third_party/ninja/ninja -C out/QuickBrowser chrome          # hours; resumable
```

`ninja` is incremental — re-running after an interruption picks up where it
stopped. Nothing above needs to be redone unless the source tree itself is gone.

## Disk

This is the binding constraint, and it caught us out:

| Item | Size |
|---|---|
| `browser/src-checkout/src/.git` | **64 GB** (shallow, but unpacked+ungc'd) |
| working tree | ~29 GB |
| `out/QuickBrowser` at 10% of targets | 4.6 GB |
| depot_tools | 1.1 GB |

Budget **at least 120 GB** for the workspace. We were down to 17 GB free with
the build only 10% through, which is the main reason this needs a bigger disk.
`git gc --prune=now` inside `src-checkout/src` should reclaim a large part of
that 64 GB and is safe to run when no build is active.

## Traps already paid for — do not rediscover these

1. **`fetch chromium` gives you tip of main** (it handed us 153.0.8007.0). The
   ungoogled series targets stable 151.0.7922.137 and will not apply two majors
   away. `pin.txt` holds both halves; `fetch-source.sh` refuses to run if they
   disagree.
2. **Run gclient hooks BEFORE `prune_binaries.py`, never after.** Pruning
   deletes ~247k files by design (iOS, Android, ChromeCast, unused third_party)
   including `android_webview/`, which holds a git-tracked `version_file` that
   gclient reads while *parsing* DEPS — regardless of that dep's
   `checkout_android` condition. After a prune, every `gclient sync`/`runhooks`
   dies with `FileNotFoundError`, so clang/Rust/node/sysroot never install and
   the failure surfaces much later as `gn` unable to read
   `rust-toolchain/VERSION`. `fetch-source.sh` now orders this correctly.
3. **Never `gclient sync -D`.** It deletes hook-produced directories as
   "unmanaged". (Measured aside: plain `gclient sync` deletes *nothing* — the
   mass deletions we chased were pruning doing its job.)
4. **A killed patch run cannot simply be re-run.** `patch --forward` exits 1 on
   an already-applied hunk, so attempt 2 collides with attempt 1 and looks like
   a rebase conflict. `fetch-source.sh` always restores pristine first, and that
   needs three steps: reset the nested dep repos the series touches (`git -C src
   reset` cannot see inside them — patch 11 hits
   `third_party/search_engines_data`), `git reset --hard <tag>`, and delete the
   17 files the series *creates* (untracked, so reset misses them).
5. **`ensure-deps.py` exists because gclient can't be relied on here.** Three
   bugs were fixed in it and each cost a build:
   - CIPD deps, not just GCS (`gperf` was missing).
   - **Per-object conditions.** One GCS dep lists Linux, Mac *and* Windows
     tarballs (llvm-build has 6+), each gated on `host_os`. Ignoring them
     extracts every platform's clang into one directory, last one wins, and the
     build dies ~40 targets later with `clang++: Exec format error` because the
     `clang` on disk is a Mach-O binary.
   - **`recursedeps`.** dawn's own DEPS holds the Go toolchain that generates
     all of tint's sources; without it the build dies ~13.5k targets in.
   - Also: DEPS vars whose *value is the name of another var*
     (`'checkout_angle_restricted_traces': 'checkout_angle_internal'`) must be
     chased to a fixed point, or ~380 authenticated-only ANGLE trace packages
     look enabled.
6. **depot_tools needs `./ensure_bootstrap`** before `gn` runs. Its `luci-auth`
   error is harmless (RBE only).

## Decisions worth re-reading before shipping

- **Free codecs only** (`proprietary_codecs=false`, `ffmpeg_branding="Chromium"`).
  H.264/AAC are a *patent* question, not a licensing one. Some web video will
  not play. Recorded in `NOTICE` and LICENSING.md §5.
- **`enable_widevine=true`** comes from ungoogled's own `flags.gn` and was kept.
  It builds the DRM interface only; no proprietary CDM ships. Flagged to the
  user, not yet explicitly confirmed.
- **`platforms: ["linux"]`** in `.quickopen.json`. A browser is a standing
  security commitment (Chromium ships fixes for actively exploited bugs every
  2–4 weeks); Windows/macOS are not listed until we can rebuild and re-ship that
  fast.
- Three names must survive the rename and are asserted by `apply-branding.py`:
  `The Chromium Authors` (a copyright line — removing it would breach the BSD-3
  attribution we are obliged to keep), `ChromiumOS`, `chromium.org`.

## Next after the build lands

1. Verify branding in the binary: `out/QuickBrowser/chrome --version`, About box,
   and that `about:credits` still renders (it is how the BSD-3 notice
   requirement is met — never remove it).
2. Package: deb → `.usi` (`ca/scripts/build-usi.sh`) → apt repo on
   `r2.quickopen.io`, mirroring the Quick Office flow.
3. Screenshots (light + dark) and the quickopen.ai portal listing.
