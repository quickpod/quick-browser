#!/usr/bin/env bash
# stage-securevault-extension.sh — pre-install the SecureVault Autofill
# extension into a quick-browser package stage.
#
#   packaging/stage-securevault-extension.sh <stage-root>
#
# Installs, into <stage-root>:
#   /opt/quick-browser/quickopen-extensions/securevault/     unpacked copy
#       (reference + documented manual-load path; the browser does not load
#        this copy directly)
#   /opt/quick-browser/quickopen-extensions/securevault.crx  packed CRX3
#   /usr/share/chromium/extensions/<id>.json                 external install
#
# WHY THIS SHAPE. The shipped binary consults /usr/share/chromium/extensions
# (verified with strings(1) against the packaged chrome) — Chromium's external
# extensions mechanism, which persists across restarts and profiles and needs
# no wrapper flags. That mechanism takes a PACKED crx, self-signed here with
# the project key in ca/private/; the extension manifest carries the matching
# pinned public key, so the packed, external-installed and dev-mode-unpacked
# extension all resolve to the SAME extension ID — which is what the
# securevault deb's native-messaging host manifests allow.
#
# ungoogled-chromium note: external extensions are honoured by default; the
# fork adds chrome://flags/#block-external-extensions for users who want them
# off, which we deliberately leave in their hands.
set -euo pipefail

STAGE="${1:?usage: stage-securevault-extension.sh <stage-root>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS="$(cd "$HERE/../.." && pwd)"
ROOT="$(cd "$REPOS/.." && pwd)"

EXT_SRC="$REPOS/securevault/extension"
KEY="$ROOT/ca/private/securevault-extension-signing.pem"
PACKER="$ROOT/ca/scripts/pack-crx3.py"

[ -d "$EXT_SRC" ] || { echo "no extension source at $EXT_SRC"; exit 1; }
[ -f "$KEY" ] || { echo "no signing key at $KEY"; exit 1; }
python3 -c "import json,sys; m=json.load(open('$EXT_SRC/manifest.json')); sys.exit(0 if m.get('key') else 1)" \
  || { echo "extension manifest has no pinned key — run the key setup first"; exit 1; }

DEST="$STAGE/opt/quick-browser/quickopen-extensions"
mkdir -p "$DEST" "$STAGE/usr/share/chromium/extensions"

rm -rf "$DEST/securevault"
cp -a "$EXT_SRC" "$DEST/securevault"
find "$DEST/securevault" -name '__pycache__' -o -name '*.pyc' | xargs -r rm -rf

OUT="$(python3 "$PACKER" "$DEST/securevault" "$KEY" "$DEST/securevault.crx")"
echo "   $OUT"
EXT_ID="$(printf '%s' "$OUT" | sed -n 's/.*id=\([a-p]\{32\}\).*/\1/p')"
[ -n "$EXT_ID" ] || { echo "could not derive extension id"; exit 1; }
VER="$(python3 -c "import json;print(json.load(open('$EXT_SRC/manifest.json'))['version'])")"

cat > "$STAGE/usr/share/chromium/extensions/$EXT_ID.json" <<EOF
{
  "external_crx": "/opt/quick-browser/quickopen-extensions/securevault.crx",
  "external_version": "$VER"
}
EOF
echo "   external install: /usr/share/chromium/extensions/$EXT_ID.json (v$VER)"
