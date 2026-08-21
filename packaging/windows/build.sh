#!/usr/bin/env bash
# Build QuickBrowser-Setup.exe — the Windows installer.
#
#   packaging/windows/build.sh [downloads_dir] [outdir]
#
# v1 policy (mirrors nothing on Linux — the deb is a from-source build): the
# payload is the OFFICIAL ungoogled-chromium Windows x64 release pinned in
# windows-pin.txt, repackaged byte-identical with QuickOpen branding around it.
# Runs fine on a Linux build host: makensis + ImageMagick + unzip only.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
ROOT="$(cd "$REPO/../.." && pwd)"
DL="${1:-$ROOT/winbuild/downloads}"
OUT="${2:-$ROOT/winbuild/dist}"
WORK="$ROOT/winbuild/work/quick-browser"

pin(){ awk -F= -v k="$1" '$1==k{print $2}' "$HERE/windows-pin.txt" | tr -d ' \r'; }
TAG="$(pin tag)"            # e.g. 151.0.7922.108-1.1
SHA256="$(pin sha256)"
VER="${TAG%-*}"             # chromium version, e.g. 151.0.7922.108
REV="${QUICK_BROWSER_WIN_REV:-1}"
DISPLAYVER="$VER-$REV"
ZIP="$DL/ungoogled-chromium_${TAG}_windows_x64.zip"

command -v makensis >/dev/null || { echo "makensis missing (apt install nsis)" >&2; exit 1; }
command -v convert  >/dev/null || { echo "ImageMagick convert missing" >&2; exit 1; }
[ -f "$ZIP" ] || { echo "missing $ZIP — download the pinned upstream zip first" >&2; exit 1; }

echo "== QuickBrowser-Setup.exe  $DISPLAYVER  (upstream $TAG)"
echo "$SHA256  $ZIP" | sha256sum -c - >/dev/null || { echo "!! sha256 mismatch on $ZIP" >&2; exit 1; }
echo "   upstream sha256 ok"

rm -rf "$WORK" && mkdir -p "$WORK" "$OUT"
unzip -q "$ZIP" -d "$WORK/unz"
# the zip wraps everything in one versioned top dir — that dir IS the payload
PAYLOAD="$(find "$WORK/unz" -maxdepth 2 -name chrome.exe -printf '%h\n' | head -1)"
[ -n "$PAYLOAD" ] && [ -f "$PAYLOAD/chrome.exe" ] || { echo "no chrome.exe in zip" >&2; exit 1; }

# our licences + notices ride INSIDE the install dir (same rule as the deb:
# attribution ships with the app, not in a doc graveyard)
mkdir -p "$PAYLOAD/licenses"
cp "$REPO/NOTICE" "$REPO/LICENSING.md" "$PAYLOAD/"
cp "$REPO/LICENSE" "$PAYLOAD/LICENSE-quickopen.txt"
cp "$REPO"/licenses/* "$PAYLOAD/licenses/"

# THICK icon set -> multi-res .ico
ICO="$WORK/quick-browser.ico"
convert "$ROOT/publish/icons/quick-browser.png" -define icon:auto-resize=256,128,64,48,32,16 "$ICO"

# SIGNED PAYLOAD BINARIES. Two separate reasons a payload file needs replacing:
#
#   chrome.exe is MODIFIED — icon-patch.ps1 rebuilds its IDR_MAINFRAME group on
#   a real Windows box so the taskbar shows our icon (wine and rcedit both
#   corrupt the group directory), which invalidates any signature it had.
#
#   The other five (chrome_proxy, chrome_pwa_launcher, elevated_tracing_service,
#   elevation_service, notification_helper) are UNMODIFIED but ship UNSIGNED:
#   ungoogled-chromium signs nothing. Wrapping them in an EV-signed installer
#   does not make them signed — once on disk they are judged on their own bytes.
#
# Both cases are handled the same way now: an override TREE mirroring the
# payload layout, applied and then GATED, so a future upstream release that
# adds a binary fails the build instead of shipping unsigned.
"$ROOT/publish/scripts/apply-overrides.sh" "$PAYLOAD" "$ROOT/winbuild/overrides/quick-browser"

# WinShell NSIS plug-in (shortcut AUMID), pinned in windows-pin.txt
WINSHELL="$ROOT/winbuild/tools/WinShell/Plugins/x86-unicode"
if [ ! -f "$WINSHELL/WinShell.dll" ]; then
  mkdir -p "$ROOT/winbuild/tools" && cd "$ROOT/winbuild/tools"
  curl -sL -o WinShell.zip "$(pin winshell_url)"
  echo "$(pin winshell_sha256)  WinShell.zip" | sha256sum -c - >/dev/null || { echo "!! WinShell.zip sha mismatch" >&2; exit 1; }
  unzip -o -q WinShell.zip -d WinShell
  cd - >/dev/null
fi

EST_KB="$(du -sk "$PAYLOAD" | cut -f1)"
LICENSEFILE="$PAYLOAD/LICENSE"; [ -f "$LICENSEFILE" ] || LICENSEFILE="$REPO/LICENSE"
makensis -V2 \
  -DPAYLOAD="$PAYLOAD" \
  -DVERSION="$VER" \
  -DDISPLAYVERSION="$DISPLAYVER" \
  -DESTSIZE_KB="$EST_KB" \
  -DICOFILE="$ICO" \
  -DPLUGINDIR="$WINSHELL" \
  -DLICENSEFILE="$LICENSEFILE" \
  -DOUTFILE="$OUT/QuickBrowser-Setup.exe" \
  "$HERE/installer.nsi"

echo "   $(du -h "$OUT/QuickBrowser-Setup.exe" | cut -f1)  $OUT/QuickBrowser-Setup.exe"
