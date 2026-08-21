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
SYSCA="${QUICKOPEN_SYSCA:-/etc/ssl/certs/ca-certificates.crt}"  # public roots, to READ the EV signer

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

# THE SIGNED UNINSTALLER (see installer.nsi's two-pass note). NSIS can only
# emit an uninstaller by RUNNING a built installer, so it cannot be produced
# here — the generator stub has to execute on Windows. This script therefore
# has two modes over ONE argument list, rather than a second copy of it that
# would drift:
#
#   QUICKOPEN_UNINST_STUB_ONLY=1   compile the payload-free pass-1 stub and stop
#   (default)                      the real installer, embedding the signed
#                                  uninstaller produced from that stub
#
# Round trip, because makensis lives here and the ssh route to the signing box
# lives on the dev box:
#   proc$    QUICKOPEN_UNINST_STUB_ONLY=1 packaging/windows/build.sh
#   dev$     publish/scripts/make-signed-uninstaller.sh --stub <stub> <out>
#   dev$     publish/scripts/sign-windows-artifact.sh <out>
#   proc$    packaging/windows/build.sh          # picks the signed one up below
NSIARGS=(
  -DPAYLOAD="$PAYLOAD"
  -DVERSION="$VER"
  -DDISPLAYVERSION="$DISPLAYVER"
  -DESTSIZE_KB="$EST_KB"
  -DICOFILE="$ICO"
  -DPLUGINDIR="$WINSHELL"
  -DLICENSEFILE="$LICENSEFILE"
)

if [ "${QUICKOPEN_UNINST_STUB_ONLY:-0}" = "1" ]; then
  STUB="$ROOT/winbuild/uninstallers/quick-browser/stub.exe"
  mkdir -p "$(dirname "$STUB")"
  # -DUNINSTALLER must be defined even though pass 1 skips the branch using it:
  # makensis resolves ${...} at parse time and an undefined symbol is an error.
  makensis -V2 -DUNINSTALLER_ONLY -DUNINSTALLER=/dev/null \
    "${NSIARGS[@]}" -DOUTFILE="$STUB" "$HERE/installer.nsi"
  echo "   pass-1 stub: $STUB ($(du -h "$STUB" | cut -f1))"
  echo "   next: run it on Windows, EV-sign the Uninstall.exe it writes, put it at"
  echo "         $ROOT/winbuild/uninstallers/quick-browser/Uninstall.exe, re-run this script"
  exit 0
fi

UNINST="$ROOT/winbuild/uninstallers/quick-browser/Uninstall.exe"
[ -f "$UNINST" ] || { echo "!! missing signed uninstaller at $UNINST" >&2
  echo "!! build it: QUICKOPEN_UNINST_STUB_ONLY=1 $0" >&2; exit 1; }
# Same gate, same reason, same pipefail trap as the payload overrides: capture
# osslsigncode's output and grep the capture, never pipe into grep -q.
EVOUT="$(osslsigncode verify -in "$UNINST" -CAfile "$SYSCA" 2>&1 || true)"
printf '%s' "$EVOUT" | grep -qi "CN=Dosvak LLC" || {
  echo "!! uninstaller is NOT EV-signed — refusing to build" >&2
  echo "!!   publish/scripts/sign-windows-artifact.sh $UNINST" >&2; exit 1; }
echo "   uninstaller: $(sha256sum "$UNINST" | cut -c1-16)... (EV: CN=Dosvak LLC)"

makensis -V2 "${NSIARGS[@]}" \
  -DUNINSTALLER="$UNINST" \
  -DOUTFILE="$OUT/QuickBrowser-Setup.exe" \
  "$HERE/installer.nsi"

echo "   $(du -h "$OUT/QuickBrowser-Setup.exe" | cut -f1)  $OUT/QuickBrowser-Setup.exe"
