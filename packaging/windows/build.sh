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

# BRANDED chrome.exe (field defect: the taskbar shows the window icon, which
# comes from the exe's OWN icon-resource group, not from shortcut .ico files).
# icon-patch.ps1 rebuilds chrome.exe's IDR_MAINFRAME group from our .ico ON A
# REAL WINDOWS BOX (wine's and rcedit's resource rewriting are both broken —
# see the script header), and the result is Authenticode-signed with the
# QuickOpen CA on the signing box. This build refuses to pack an unbranded
# chrome.exe.
OVERRIDE="$ROOT/winbuild/overrides/quick-browser/chrome.exe"
[ -f "$OVERRIDE" ] || { echo "!! missing branded+signed chrome.exe at $OVERRIDE" >&2
  echo "!! prepare it with packaging/windows/icon-patch.ps1 + osslsigncode (see installer.nsi header)" >&2; exit 1; }
cp "$OVERRIDE" "$PAYLOAD/chrome.exe"
echo "   branded chrome.exe: $(sha256sum "$PAYLOAD/chrome.exe" | cut -c1-16)..."

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
