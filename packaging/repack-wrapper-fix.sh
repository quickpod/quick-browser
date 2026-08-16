#!/usr/bin/env bash
# repack-wrapper-fix.sh — rebuild a shipped Quick Browser .deb with ONLY the
# /usr/bin/quick-browser launcher wrapper replaced, and the revision bumped.
#
#   packaging/repack-wrapper-fix.sh <shipped.deb> [outdir]
#
# ---------------------------------------------------------------------------
# HONESTY NOTE — WHAT 151.0.7922.137-6 ACTUALLY IS
#
# -6 is a PACKAGING-ONLY REPACK of -5. Every binary in it — chrome, the
# sandbox helper, the whole /opt/quick-browser tree — is byte-for-byte the -5
# build. The only payload difference is the 26-line shell wrapper at
# /usr/bin/quick-browser, which gains --no-first-run (Quick OS 0.1.12
# regression sweep, A3-P1b: the first launch opened ungoogled-chromium's own
# first-run tab — upstream branding on the flagship app's very first window),
# plus the Version field in DEBIAN/control.
#
# WHY: the fix is one flag in one text file; a from-source Chromium rebuild is
# ~day-scale for it. The first-run page itself is compiled into the engine, so
# rebranding it properly stays on the engine-build backlog — this makes it
# never appear, which is the owner-desired behaviour anyway.
#
# WHAT IS OWED: the next full engine build regenerates this package from
# source with packaging/build-deb.sh (whose wrapper heredoc carries the same
# flag, so the fix persists). Do not treat -6 in dist/ as evidence a build ran.
# ---------------------------------------------------------------------------
#
# The script REFUSES to produce a deb if anything other than the wrapper and
# the control Version differs between input and output.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
IN="${1:?usage: repack-wrapper-fix.sh <shipped.deb> [outdir]}"
OUT="${2:-$REPO/dist}"

[ -f "$IN" ] || { echo "no such deb: $IN" >&2; exit 1; }
command -v dpkg-deb >/dev/null || { echo "dpkg-deb missing (apt install dpkg-dev)" >&2; exit 1; }
if [ "$(id -u)" != 0 ] && ! command -v fakeroot >/dev/null; then
  echo "run as root or install fakeroot — otherwise the repack re-owns the payload" >&2
  exit 1
fi

# Source of truth: the wrapper exactly as build-deb.sh would write it. Extract
# it from the build script's own heredoc so the two can never drift.
SRC_WRAP="$(mktemp)"; trap 'rm -f "$SRC_WRAP"' EXIT
sed -n "/^cat > \"\$STAGE\/usr\/bin\/quick-browser\" <<'WRAP'$/,/^WRAP$/p" \
  "$HERE/build-deb.sh" | sed '1d;$d' > "$SRC_WRAP"
grep -q -- '--no-first-run' "$SRC_WRAP" \
  || { echo "extracted wrapper lacks --no-first-run — heredoc anchor drifted?" >&2; exit 1; }
head -1 "$SRC_WRAP" | grep -q '^#!/bin/sh$' \
  || { echo "extracted wrapper does not start with a shebang — bad extraction" >&2; exit 1; }

PKG="$(dpkg-deb -f "$IN" Package)"
OLDVER="$(dpkg-deb -f "$IN" Version)"
NEWVER="${QUICK_BROWSER_DEB_VERSION:-${OLDVER%-*}-$(( ${OLDVER##*-} + 1 ))}"
echo "== $PKG  $OLDVER -> $NEWVER"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK" "$SRC_WRAP"' EXIT

# format parity with the shipped deb (see quick-mail's repack for the why)
OLD_MEMBERS="$(ar t "$IN" | tr '\n' ' ')"
case "$OLD_MEMBERS" in
  *data.tar.zst*) ZFLAGS=(-Z zstd) ;;
  *data.tar.xz*)  ZFLAGS=(-Z xz) ;;
  *data.tar.gz*)  ZFLAGS=(-Z gzip) ;;
  *) echo "unrecognised deb members: $OLD_MEMBERS" >&2; exit 1 ;;
esac

echo "== unpacking"
dpkg-deb -R "$IN" "$WORK/stage"

# --------------------------------------------------------- the ONE change
install -m 0755 "$SRC_WRAP" "$WORK/stage/usr/bin/quick-browser"
[ "$(id -u)" = 0 ] && chown root:root "$WORK/stage/usr/bin/quick-browser"

sed -i "s/^Version: .*/Version: $NEWVER/" "$WORK/stage/DEBIAN/control"
[ "$(dpkg-deb -f "$IN" Version)" != "$(sed -n 's/^Version: //p' "$WORK/stage/DEBIAN/control")" ] \
  || { echo "version bump did not take" >&2; exit 1; }

mkdir -p "$OUT"
DEB="$OUT/${PKG}_${NEWVER}_amd64.deb"
echo "== building $(basename "$DEB") (${ZFLAGS[*]})"
if [ "$(id -u)" = 0 ]; then
  dpkg-deb "${ZFLAGS[@]}" --build "$WORK/stage" "$DEB" >/dev/null
else
  fakeroot dpkg-deb "${ZFLAGS[@]}" --build "$WORK/stage" "$DEB" >/dev/null
fi

NEW_MEMBERS="$(ar t "$DEB" | tr '\n' ' ')"
[ "$NEW_MEMBERS" = "$OLD_MEMBERS" ] \
  || { echo "FAIL: member layout changed ($OLD_MEMBERS -> $NEW_MEMBERS)" >&2; rm -f "$DEB"; exit 4; }

# ------------------------------------------------- ASSERT the payload diff
echo "== diffing payloads"
dpkg-deb -R "$DEB" "$WORK/new"

hashes() {
  ( cd "$1" && find . -mindepth 1 -path ./DEBIAN -prune -o -type f -print0 \
    | LC_ALL=C sort -z | xargs -0 sha256sum )
}
dpkg-deb -R "$IN" "$WORK/old"
hashes "$WORK/old" > "$WORK/h.old"; hashes "$WORK/new" > "$WORK/h.new"
CHANGED="$( { diff "$WORK/h.old" "$WORK/h.new" || true; } | grep '^[<>]' | awk '{print $3}' | LC_ALL=C sort -u)"
echo "   payload files changed: ${CHANGED:-<none>}"
if [ "$CHANGED" != "./usr/bin/quick-browser" ]; then
  echo "FAIL: files other than the wrapper changed — REFUSING to publish." >&2
  rm -f "$DEB"; exit 7
fi
cmp -s "$WORK/new/usr/bin/quick-browser" "$SRC_WRAP" \
  || { echo "FAIL: shipped wrapper is not the build script's heredoc" >&2; rm -f "$DEB"; exit 8; }
[ -x "$WORK/new/usr/bin/quick-browser" ] \
  || { echo "FAIL: wrapper lost its exec bit" >&2; rm -f "$DEB"; exit 8; }

# control: only Version; control archive same member set
CTLDIFF="$( { diff "$WORK/old/DEBIAN/control" "$WORK/new/DEBIAN/control" || true; } | grep '^[<>]' || true)"
NCTL="$(printf '%s\n' "$CTLDIFF" | grep -c '^[<>]' || true)"
if [ "$NCTL" != 2 ] || [ "$(printf '%s\n' "$CTLDIFF" | grep -c 'Version: ')" != 2 ]; then
  echo "FAIL: DEBIAN/control differs by more than Version:" >&2
  printf '%s\n' "$CTLDIFF" >&2
  rm -f "$DEB"; exit 9
fi
OLDCTL_FILES="$(cd "$WORK/old/DEBIAN" && ls | LC_ALL=C sort | tr '\n' ' ')"
NEWCTL_FILES="$(cd "$WORK/new/DEBIAN" && ls | LC_ALL=C sort | tr '\n' ' ')"
[ "$OLDCTL_FILES" = "$NEWCTL_FILES" ] \
  || { echo "FAIL: control archive gained/lost files ($OLDCTL_FILES -> $NEWCTL_FILES)" >&2
       rm -f "$DEB"; exit 10; }

echo "   control: Version only ($OLDVER -> $NEWVER); control members unchanged ($NEWCTL_FILES)"
echo
echo "OK: $DEB"
echo "    $(du -h "$DEB" | cut -f1), payload identical to $(basename "$IN") except /usr/bin/quick-browser"
