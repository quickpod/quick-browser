#!/usr/bin/env bash
# stage-securevault-extension.sh — pre-install the SecureVault Autofill
# extension into a quick-browser package stage.
#
#   packaging/stage-securevault-extension.sh <stage-root>
#
# Installs, into <stage-root>:
#   /opt/quick-browser/quickopen-extensions/securevault/     unpacked copy
#       (reference + documented manual-load path for OTHER browsers; Quick
#        Browser itself loads the SIGNED .crx below, never this directory)
#   /opt/quick-browser/quickopen-extensions/securevault.crx  packed CRX3
#   /usr/share/chromium/extensions/<id>.json                 external install
#
# WHY THIS SHAPE. The shipped binary consults /usr/share/chromium/extensions
# (verified with strings(1) against the packaged chrome) — Chromium's external
# extensions mechanism, which installs the crx as a NORMAL packed extension:
# persistent across restarts/profiles, no developer mode, no unpacked-load
# warnings. The crx is signed with the QuickOpen CA-custody extension key
# (ca/apt/private/, same protection as the apt/root signing material); the
# extension manifest carries the matching pinned public key, so the packed,
# external-installed and dev-mode-unpacked extension all resolve to the SAME
# extension ID — which is what SecureVault's native-messaging host manifests
# allow.
#
# PUBLISH GATE (fails the build, never warns):
#   1. the packed crx must verify cryptographically (pack-crx3.py verify)
#      against its embedded key, and its derived ID must equal the pinned ID;
#   2. the pinned ID must be IDENTICAL everywhere it is referenced: the
#      extension manifest "key", all three securevault host manifests'
#      allowed_origins, and the external-extensions JSON filename.
#
# ungoogled-chromium note: external extensions are honoured by default; the
# fork adds chrome://flags/#block-external-extensions for users who want them
# off, which we deliberately leave in their hands.
set -euo pipefail

STAGE="${1:?usage: stage-securevault-extension.sh <stage-root>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS="$(cd "$HERE/../.." && pwd)"
ROOT="$(cd "$REPOS/.." && pwd)"

SV_REPO="$REPOS/securevault"
EXT_SRC="$SV_REPO/extension"
KEY="$ROOT/ca/apt/private/securevault-extension-signing.pem"
PACKER="$ROOT/ca/scripts/pack-crx3.py"

[ -d "$EXT_SRC" ] || { echo "no extension source at $EXT_SRC"; exit 1; }
sudo test -f "$KEY" || { echo "no CA-custody signing key at $KEY"; exit 1; }

# ---- the pinned ID, derived from the manifest's public key (never hardcoded)
PIN_ID="$(python3 - "$EXT_SRC/manifest.json" <<'PY'
import base64, hashlib, json, sys
key = json.load(open(sys.argv[1])).get("key") or ""
if not key:
    sys.exit("extension manifest has no pinned key")
der = base64.b64decode(key)
d = hashlib.sha256(der).digest()[:16]
print("".join(chr(ord('a')+(b>>4))+chr(ord('a')+(b&15)) for b in d))
PY
)"
echo "   pinned extension id: $PIN_ID"

# ---- gate 2a: every securevault host manifest must allow exactly this ID
for m in "$SV_REPO"/packaging/linux/rootfs/etc/*/native-messaging-hosts/com.securevault.autofill.json \
         "$SV_REPO"/packaging/linux/rootfs/etc/opt/*/native-messaging-hosts/com.securevault.autofill.json; do
  [ -f "$m" ] || continue
  grep -q "chrome-extension://$PIN_ID/" "$m" \
    || { echo "!! host manifest $m does not allow $PIN_ID"; exit 1; }
done
echo "   host manifests all pin $PIN_ID"

DEST="$STAGE/opt/quick-browser/quickopen-extensions"
mkdir -p "$DEST" "$STAGE/usr/share/chromium/extensions"

rm -rf "$DEST/securevault"
cp -a "$EXT_SRC" "$DEST/securevault"
find "$DEST/securevault" -name '__pycache__' -o -name '*.pyc' | xargs -r rm -rf

# ---- pack with the CA-custody key (root-held, like the apt signing material)
if [ -r "$KEY" ]; then
  OUT="$(python3 "$PACKER" "$DEST/securevault" "$KEY" "$DEST/securevault.crx")"
else
  OUT="$(sudo python3 "$PACKER" "$DEST/securevault" "$KEY" "$DEST/securevault.crx")"
  sudo chown "$(id -u):$(id -g)" "$DEST/securevault.crx"
fi
echo "   $OUT"

# ---- gate 1: cryptographic verification + pinned-ID equality
python3 "$PACKER" verify "$DEST/securevault.crx" "$PIN_ID" \
  || { echo "!! crx failed verification against the pinned id"; exit 1; }

VER="$(python3 -c "import json;print(json.load(open('$EXT_SRC/manifest.json'))['version'])")"
cat > "$STAGE/usr/share/chromium/extensions/$PIN_ID.json" <<EOF
{
  "external_crx": "/opt/quick-browser/quickopen-extensions/securevault.crx",
  "external_version": "$VER"
}
EOF
echo "   external install: /usr/share/chromium/extensions/$PIN_ID.json (v$VER)"
