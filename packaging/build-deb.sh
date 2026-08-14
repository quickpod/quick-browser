#!/usr/bin/env bash
# build-deb.sh — the Quick Browser Debian package.
#
#   packaging/build-deb.sh [outdir] [builddir]
#       outdir    default ../dist
#       builddir  default ../../../browser/src-checkout/src/out/QuickBrowser
#
# WHY THIS EXISTS AND DOES NOT USE ca/scripts/build-deb.sh
# --------------------------------------------------------
# The shared builder is a PYTHON app spec: Architecture: all, copytree of the
# repo into /opt/quickopen/<slug>, Depends: quickopen-runtime + python3-tk, and
# a wrapper that execs `python3 <buildEntry>`. That is right for 36 of the apps
# and completely wrong here — Quick Browser is a ~200 MB compiled C++ binary
# with a runtime data payload (paks, ICU, snapshots, SwiftShader) and no Python
# anywhere. quickoffice-engine hit the same wall and solved it the same way, so
# this mirrors repos/quickoffice-engine/packaging/build-debs.sh deliberately.
# ca/scripts/build-usi.sh already accepts a prebuilt deb via
# QUICKOPEN_USI_PAYLOAD for exactly this case.
#
# SHAPE
#   quickopen-quick-browser  Architecture: amd64
#     /opt/quick-browser/...          the build output (binary + runtime data)
#     /opt/quick-browser/chrome-sandbox   SUID root, mode 4755 — see below
#     /usr/bin/quick-browser          launcher wrapper
#     /usr/share/applications/quick-browser.desktop
#     /usr/share/icons/hicolor/<size>/apps/quick-browser.png (+ scalable svg)
#     /usr/share/doc/quickopen-quick-browser/{NOTICE,LICENSING.md,licenses/}
#
# Depends are computed with dpkg-shlibdeps against the real binary rather than
# hand-written. Noble renamed a swathe of Chromium's runtime deps for the 64-bit
# time_t transition (libasound2t64, libatk1.0-0t64, libcups2t64, libglib2.0-0t64
# ...), and a hand-maintained list silently rots into either an uninstallable
# package or one that installs and then cannot start.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OUT="${1:-$REPO/dist}"
BUILD="${2:-$REPO/../../browser/src-checkout/src/out/QuickBrowser}"

command -v dpkg-deb >/dev/null || { echo "dpkg-deb missing (apt install dpkg-dev)"; exit 1; }

# Version: the Chromium release we are pinned to IS the product version — a
# browser's version number is a security claim, so it must name the upstream
# release its fixes came from. REV distinguishes a repackage of the same source.
VERSION="$(awk -F= '/^chromium_tag=/{print $2}' "$REPO/pin.txt" | tr -d ' \r')"
[ -n "$VERSION" ] || { echo "no chromium_tag in pin.txt"; exit 1; }
REV="${QUICK_BROWSER_DEB_REV:-1}"
DEB_VERSION="${VERSION}-${REV}"
PKG="quickopen-quick-browser"

[ -x "$BUILD/chrome" ] || { echo "no built browser at $BUILD/chrome — run ninja first"; exit 1; }

echo "== $PKG $DEB_VERSION"
echo "   from $BUILD"

STAGE="$OUT/stage"
rm -rf "$STAGE"
OPT="$STAGE/opt/quick-browser"
mkdir -p "$OPT" "$STAGE/DEBIAN" "$STAGE/usr/bin" \
         "$STAGE/usr/share/applications" \
         "$STAGE/usr/share/doc/$PKG" \
         "$STAGE/usr/share/icons/hicolor/scalable/apps"

# ---------------------------------------------------------------- the payload
# An explicit allow-list, not `cp -a out/*`. The build directory holds ~11 GB of
# object files, generated headers, test binaries and toolchain copies; the
# shippable product is a small named subset of it. Anything required that is
# missing is a hard error — a browser that starts and then cannot find its .pak
# files is a worse outcome than a build that refuses to package.
REQUIRED=(
  chrome                       # the browser
  icudtl.dat                   # ICU data
  v8_context_snapshot.bin      # V8 startup snapshot
  resources.pak                # UI resources
  chrome_100_percent.pak
  chrome_200_percent.pak
)
OPTIONAL=(
  chrome_crashpad_handler      # present even with reporting off; harmless
  libEGL.so libGLESv2.so       # ANGLE
  libvulkan.so.1
  libvk_swiftshader.so vk_swiftshader_icd.json   # software raster fallback
  libGLESv2_angle.so libEGL_angle.so
)

for f in "${REQUIRED[@]}"; do
  [ -e "$BUILD/$f" ] || { echo "!! required runtime file missing: $f"; exit 1; }
  cp -a "$BUILD/$f" "$OPT/"
done

# Strip the staged binary, never the one in the build tree. Even at
# symbol_level=0 the linker leaves a ~180 MB .symtab, which is 35% of the
# 510 MB binary and buys a shipped user nothing: with no debug info present
# those symbols cannot produce a usable stack trace anyway. Measured
# 510 MB -> 331 MB, and the stripped binary reports its version identically.
if command -v strip >/dev/null; then
  strip --strip-unneeded "$OPT/chrome"
  echo "   stripped chrome -> $(du -h "$OPT/chrome" | cut -f1)"
fi
for f in "${OPTIONAL[@]}"; do
  [ -e "$BUILD/$f" ] && cp -a "$BUILD/$f" "$OPT/" || true
done

# locales: every <lang>.pak. Without these the UI falls back to raw resource
# ids, which looks like a corrupt install.
if [ -d "$BUILD/locales" ]; then
  mkdir -p "$OPT/locales"
  find "$BUILD/locales" -maxdepth 1 -name '*.pak' -exec cp -a {} "$OPT/locales/" \;
fi
# optional data directories that ship when built
for d in MEIPreload PrivacySandboxAttestationsPreloaded WidevineCdm; do
  [ -d "$BUILD/$d" ] && cp -a "$BUILD/$d" "$OPT/" || true
done

# ---------------------------------------------------------------- the sandbox
# Chromium needs a sandbox or it must be started with --no-sandbox, which is
# not something a browser should ever ship doing. Two mechanisms exist:
# unprivileged user namespaces, and the SUID helper. Ubuntu 24.04 restricts the
# former by default (kernel.apparmor_restrict_unprivileged_userns=1), so an
# unconfined Chromium build fails to launch on a stock noble desktop. The SUID
# helper works on both stock noble and AIQuick, so it is what we ship.
# Mode 4755 is set here and re-asserted in postinst, because dpkg records the
# mode from the archive and a careless rebuild that loses it produces a browser
# that will not start.
if [ -e "$BUILD/chrome_sandbox" ]; then
  install -m 4755 "$BUILD/chrome_sandbox" "$OPT/chrome-sandbox"
else
  echo "!! chrome_sandbox not built — run: ninja -C $BUILD chrome_sandbox"
  exit 1
fi

# ---------------------------------------------------------------- the wrapper
# CHROME_DEVEL_SANDBOX points the browser at the SUID helper by absolute path.
# Everything else is left alone on purpose: no forced flags, no telemetry
# opt-outs to undo, nothing that would contradict the build's own config.
cat > "$STAGE/usr/bin/quick-browser" <<'WRAP'
#!/bin/sh
# Quick Browser launcher
export CHROME_DEVEL_SANDBOX=/opt/quick-browser/chrome-sandbox
exec /opt/quick-browser/chrome "$@"
WRAP
chmod 0755 "$STAGE/usr/bin/quick-browser"

install -m 0644 "$REPO/applications/quick-browser.desktop" \
        "$STAGE/usr/share/applications/quick-browser.desktop"

# icons: the full hicolor ladder, so the shell picks the right one per context
for size in 16 24 32 48 64 128 256 512; do
  src="$REPO/branding/quick-browser-$size.png"
  [ -f "$src" ] || continue
  d="$STAGE/usr/share/icons/hicolor/${size}x${size}/apps"
  mkdir -p "$d"
  install -m 0644 "$src" "$d/quick-browser.png"
done
[ -f "$REPO/quick-browser.svg" ] && install -m 0644 "$REPO/quick-browser.svg" \
    "$STAGE/usr/share/icons/hicolor/scalable/apps/quick-browser.svg"

# ---------------------------------------------------------------- the licences
# BSD-3-Clause obliges us to carry the copyright notice and the third-party
# inventory. about:credits inside the binary is the primary discharge of that;
# these files are the on-disk copy. Do not drop them.
#
# They are installed TWICE, and that is deliberate. AIQuick OS ships
# `path-exclude=/usr/share/doc/*` in /etc/dpkg/dpkg.cfg.d, which strips the
# whole of /usr/share/doc from every package at unpack time — verified on a
# live AIQuick 0.1 guest, where /usr/share/doc was completely empty and
# `dpkg -V quickopen-quick-browser` reported our NOTICE and licence texts
# "missing" immediately after a clean install. A licence file that the target
# OS deletes on install is not shipped. So the authoritative copy lives beside
# the binary in /opt, which no path-exclude touches, and the /usr/share/doc
# copy stays for Debian convention on stock Ubuntu.
install -m 0644 "$REPO/NOTICE" "$STAGE/usr/share/doc/$PKG/NOTICE"
install -m 0644 "$REPO/LICENSING.md" "$STAGE/usr/share/doc/$PKG/LICENSING.md"
cp -a "$REPO/licenses" "$STAGE/usr/share/doc/$PKG/licenses"

install -m 0644 "$REPO/NOTICE" "$OPT/NOTICE"
install -m 0644 "$REPO/LICENSING.md" "$OPT/LICENSING.md"
cp -a "$REPO/licenses" "$OPT/licenses"

# ---------------------------------------------------------------- the control
# dpkg-shlibdeps needs a debian/control to exist to resolve ${shlibs:Depends}.
# We run it in a throwaway tree and read the answer back out rather than
# adopting a full debhelper build, which would buy nothing else here.
echo "   computing Depends with dpkg-shlibdeps"
SHLIBDEPS=""
if command -v dpkg-shlibdeps >/dev/null; then
  TMPD="$(mktemp -d)"
  mkdir -p "$TMPD/debian"
  cat > "$TMPD/debian/control" <<EOF
Source: $PKG
Package: $PKG
Architecture: amd64
EOF
  : > "$TMPD/debian/substvars"
  # -x excludes our own bundled .so files from the dependency scan: they are
  # shipped inside the package, so resolving them against the system would
  # either fail or pull an unrelated package.
  ( cd "$TMPD" && dpkg-shlibdeps -O --ignore-missing-info \
      -xlibEGL.so -xlibGLESv2.so -xlibvk_swiftshader.so -xlibvulkan.so.1 \
      "$OPT/chrome" 2>/dev/null ) > "$TMPD/out" || true
  SHLIBDEPS="$(sed -n 's/^shlibs:Depends=//p' "$TMPD/out" | head -1)"
  rm -rf "$TMPD"
fi
if [ -z "$SHLIBDEPS" ]; then
  echo "   !! dpkg-shlibdeps produced nothing — falling back to a static list"
  echo "      (verify with: dpkg -I <deb> and a test install on stock noble)"
  SHLIBDEPS="libc6, libstdc++6, libgcc-s1, libglib2.0-0t64, libnss3, libnspr4, libdbus-1-3, libatk1.0-0t64, libatk-bridge2.0-0t64, libatspi2.0-0t64, libcups2t64, libdrm2, libgbm1, libexpat1, libxcb1, libx11-6, libxcomposite1, libxdamage1, libxext6, libxfixes3, libxrandr2, libxkbcommon0, libpango-1.0-0, libcairo2, libasound2t64"
fi

INSTALLED_SIZE=$(du -sk "$STAGE" | cut -f1)
TAGLINE="$(python3 -c "import json;print(json.load(open('$REPO/.quickopen.json'))['tagline'])")"

cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PKG
Version: $DEB_VERSION
Section: web
Priority: optional
Architecture: amd64
Maintainer: QuickOpen <help@quickpod.io>
Installed-Size: $INSTALLED_SIZE
Depends: $SHLIBDEPS
Recommends: fonts-liberation, xdg-utils, libu2f-udev
Provides: www-browser, gnome-www-browser
Homepage: https://quickopen.ai/projects/quick-browser
Description: Quick Browser — a web browser with the Google removed
 $TAGLINE
 .
 Built from the Chromium open-source project with the ungoogled-chromium
 patch set applied: no Google API keys, no Safe Browsing callbacks, no
 component updater, no field trials, no usage or crash reporting. It does
 not report to QuickOpen either.
 .
 Ships free codecs only (VP8, VP9, AV1, Opus). H.264 and AAC are absent
 because those formats are patent-encumbered, so some web video will not
 play. See /usr/share/doc/$PKG/LICENSING.md.
 .
 This is not Google Chrome and not Chromium. It is neither produced by nor
 endorsed by Google. Engine licence: BSD-3-Clause.
EOF

# The SUID bit is the thing most likely to be lost in a rebuild or a careless
# `cp`, and losing it means the browser does not start at all, so postinst
# re-asserts it rather than trusting the archive.
cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = "configure" ]; then
  if [ -e /opt/quick-browser/chrome-sandbox ]; then
    chown root:root /opt/quick-browser/chrome-sandbox || true
    chmod 4755 /opt/quick-browser/chrome-sandbox || true
  fi
  update-desktop-database -q /usr/share/applications 2>/dev/null || true
  gtk-update-icon-cache -qf /usr/share/icons/hicolor 2>/dev/null || true
  update-alternatives --install /usr/bin/x-www-browser x-www-browser \
      /usr/bin/quick-browser 100 2>/dev/null || true
fi
exit 0
EOF
cat > "$STAGE/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = "remove" ]; then
  update-alternatives --remove x-www-browser /usr/bin/quick-browser 2>/dev/null || true
fi
exit 0
EOF
cat > "$STAGE/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
update-desktop-database -q /usr/share/applications 2>/dev/null || true
gtk-update-icon-cache -qf /usr/share/icons/hicolor 2>/dev/null || true
exit 0
EOF
chmod 0755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm" "$STAGE/DEBIAN/postrm"

mkdir -p "$OUT"
DEB="$OUT/${PKG}_${DEB_VERSION}_amd64.deb"
# -Zxz: ~200 MB of binary compresses hard, and this is served from R2 to every
# installing machine.
dpkg-deb --build --root-owner-group -Zxz "$STAGE" "$DEB" >/dev/null
rm -rf "$STAGE"

echo "   built $(basename "$DEB") ($(du -h "$DEB" | cut -f1))"
cat <<EOF

Next:
  QUICKOPEN_USI_PAYLOAD=$DEB \\
  QUICKOPEN_USI_VERSION=$VERSION \\
    /home/ubuntu/quickopen/ca/scripts/build-usi.sh quick-browser
  /home/ubuntu/quickopen/ca/scripts/build-apt-repo.sh --add $DEB --publish
EOF
