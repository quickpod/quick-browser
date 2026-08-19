#!/usr/bin/env bash
# stage-quicksearch-extension.sh — pre-install the Quick Search Setup extension
# into a quick-browser package stage.
#
#   packaging/stage-quicksearch-extension.sh <stage-root>
#
# WHY IT EXISTS. Quick Browser ships with no default search provider, by
# design: a browser that quietly forwards everything typed into the address bar
# to a search company is the thing this browser exists not to be. The cost of
# that decision was paid by the first person to use it — they typed a word,
# Chromium tried to resolve it as a hostname, and they got a dead error page
# with nothing to say the silence was deliberate (owner field report,
# 2026-08-19). This extension turns that dead end into a choice: it catches the
# resolution failure, explains, runs the search against a provider the user
# picks, and offers to make that provider the default.
#
# SHAPE — identical to stage-securevault-extension.sh, for the same reasons:
#   /opt/quick-browser/quickopen-extensions/quicksearch/     unpacked reference
#   /opt/quick-browser/quickopen-extensions/quicksearch.crx  packed CRX3
#   /usr/share/chromium/extensions/<id>.json                 external install
# The crx is signed with a CA-custody key (ca/apt/private/) and the manifest
# pins the matching public key, so packed, external-installed and dev-mode
# loads all resolve to the SAME extension ID.
#
# VERIFIED on Quick OS 0.2.4 in a VM, 2026-08-19: Chromium unpacked the crx
# into the profile through the external mechanism, and navigating to a
# single-label host produced the window title "Search is not connected".
set -euo pipefail

STAGE="${1:?usage: stage-quicksearch-extension.sh <stage-root>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$REPO/../.." && pwd)"

EXT_SRC="$REPO/extensions/quicksearch"
KEY="$ROOT/ca/apt/private/quicksearch-extension-signing.pem"
PACKER="$ROOT/ca/scripts/pack-crx3.py"

[ -d "$EXT_SRC" ] || { echo "no extension source at $EXT_SRC"; exit 1; }
sudo test -f "$KEY" || { echo "no CA-custody signing key at $KEY"; exit 1; }
[ -f "$PACKER" ] || { echo "no packer at $PACKER"; exit 1; }

# The ID is DERIVED from the manifest's pinned key, never hardcoded — the same
# derivation Chromium applies, so a key swap can never silently desync the
# external-extensions filename from the extension it installs.
PIN_ID="$(python3 - "$EXT_SRC/manifest.json" <<'PY'
import base64, hashlib, json, sys
key = json.load(open(sys.argv[1])).get("key") or ""
if not key:
    sys.exit("extension manifest has no pinned key")
d = hashlib.sha256(base64.b64decode(key)).digest()[:16]
print("".join(chr(ord('a') + (b >> 4)) + chr(ord('a') + (b & 15)) for b in d))
PY
)"

EXTDIR="$STAGE/opt/quick-browser/quickopen-extensions"
install -d "$EXTDIR" "$STAGE/usr/share/chromium/extensions"
rm -rf "$EXTDIR/quicksearch"
cp -a "$EXT_SRC" "$EXTDIR/quicksearch"

CRX="$EXTDIR/quicksearch.crx"
sudo python3 "$PACKER" "$EXT_SRC" "$KEY" "$CRX" >/dev/null
sudo chown "$(id -u):$(id -g)" "$CRX"
chmod 644 "$CRX"

# GATE, not a warning: the packed crx must verify against its embedded key and
# derive the pinned ID, or the deb would ship an extension Chromium refuses.
GOT_ID="$(python3 "$PACKER" verify "$CRX" 2>/dev/null | sed -n 's/.*id=\([a-p]\{32\}\).*/\1/p')"
if [ -n "$GOT_ID" ] && [ "$GOT_ID" != "$PIN_ID" ]; then
  echo "!! packed crx id $GOT_ID != manifest-pinned $PIN_ID"; exit 2
fi

VER="$(python3 -c "import json;print(json.load(open('$EXT_SRC/manifest.json'))['version'])")"
cat > "$STAGE/usr/share/chromium/extensions/$PIN_ID.json" <<JSON
{
  "external_crx": "/opt/quick-browser/quickopen-extensions/quicksearch.crx",
  "external_version": "$VER"
}
JSON
echo "   quicksearch extension staged (id=$PIN_ID, v$VER)"
