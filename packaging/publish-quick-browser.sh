#!/usr/bin/env bash
# Publish Quick Browser to quickopen.ai.
#
#   packaging/publish-quick-browser.sh
#
# Mirrors repos/quickoffice-engine/packaging/publish-quickoffice.sh (see its
# header for why native-engine apps do not go through publish-app.sh): the
# Linux artifacts are already built, signed and verified, so this starts at
# GitHub release -> R2 -> register -> publish.
#
# Artifacts:
#   QuickBrowser-<ver>.usi                    PRIMARY - one-click, CMS-signed
#   quickopen-quick-browser_<ver>-<rev>_amd64.deb   the same payload for apt
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
REPOS="$(cd "$REPO/.." && pwd)"
ROOT="$(cd "$REPOS/.." && pwd)"
API="https://api.quickpod.org/quickopen"
GETMEANAI_ENV="/home/ubuntu/getmeanai/api.getmeanai.com/.env"
SLUG=quick-browser
NAME="Quick Browser"
VER="$(awk -F= '/^chromium_tag=/{print $2}' "$REPO/pin.txt" | tr -d ' \r')"
TAG="v$VER"
USI="$ROOT/ca/dist/usi/QuickBrowser-$VER.usi"
DEB="$(ls "$REPO"/dist/quickopen-quick-browser_${VER}-*_amd64.deb | sort | tail -1)"

getv(){ awk -F= -v k="$1" '$1==k{v=substr($0,index($0,"=")+1); gsub(/\r/,"",v); print v}' "$GETMEANAI_ENV" | tail -1; }
say(){ printf '== %s\n' "$*"; }

[ -f "$USI" ] || { echo "missing $USI"; exit 1; }
[ -f "$DEB" ] || { echo "missing $DEB"; exit 1; }
say "$NAME $TAG"
echo "   usi: $(du -h "$USI" | cut -f1)   deb: $(du -h "$DEB" | cut -f1)"

PW="$(awk -F= '/^QUICKOPEN_ADMIN_PASSWORD=/{print $2}' "$ROOT/backend/.admin-credentials")"
AT="$(curl -s -X POST $API/update/auth/login -H 'Content-Type: application/json' \
      -d "{\"email\":\"aksansanwal@hotmail.com\",\"password\":\"$PW\"}" \
      | python3 -c "import json,sys;print(json.load(sys.stdin)['authToken'])")"
[ -n "$AT" ] || { echo "portal login failed"; exit 1; }

export R2_ACCOUNT_ID="$(getv R2_ACCOUNT_ID)"
export AWS_ACCESS_KEY_ID="$(getv R2_ACCESS_KEY_ID)"
export AWS_SECRET_ACCESS_KEY="$(getv R2_SECRET_ACCESS_KEY)"

# 1. GitHub repo + release. The build workspace (browser/) is NOT in this repo,
#    so the public repo is the recipe: pin + patches + branding + packaging.
cd "$REPO"
if [ ! -d .git ]; then git init -q -b main; fi
git add -A
git -c user.name="QuickOpen" -c user.email="help@quickpod.io" \
    commit -q -m "$NAME $VER — Chromium + ungoogled-chromium, built by QuickOpen" || true
if ! gh repo view "quickpod/$SLUG" >/dev/null 2>&1; then
  gh repo create "quickpod/$SLUG" --public --source . --remote origin \
    --description "A fast web browser with the Google removed. 100% AI-built, published on QuickOpen." --push
else
  git remote get-url origin >/dev/null 2>&1 || git remote add origin "https://github.com/quickpod/$SLUG.git"
  git push -q origin main || true
fi

NOTES="Quick OS / Linux: double-click the .usi one-click installer (CMS-signed, verified against the QuickOpen Root CA), or \`apt install quickopen-quick-browser\` from the AIQuick repository.

Built from Chromium $VER with the ungoogled-chromium patch set. Free codecs only (VP8/VP9/AV1/Opus) — H.264/AAC are patent-encumbered and deliberately absent. Not Google Chrome, not Chromium; neither produced nor endorsed by Google. Engine licence: BSD-3-Clause."
gh release view "$TAG" --repo "quickpod/$SLUG" >/dev/null 2>&1 \
  && gh release upload "$TAG" "$USI" "$DEB" --repo "quickpod/$SLUG" --clobber >/dev/null \
  || gh release create "$TAG" "$USI" "$DEB" --repo "quickpod/$SLUG" \
       --title "$NAME $VER" --notes "$NOTES" >/dev/null
echo "   github release ok"

# 2. R2 + register
python3 - "$USI" "$DEB" "$SLUG" "$NAME" "$VER" <<'PY'
import hashlib, json, os, sys
import boto3
from botocore.config import Config
usi, deb, slug, name, ver = sys.argv[1:6]
tag = "v" + ver
s3 = boto3.client("s3",
    endpoint_url=f"https://{os.environ['R2_ACCOUNT_ID']}.r2.cloudflarestorage.com",
    region_name="auto", config=Config(signature_version="s3v4"))
bucket = "quickopen-artifacts"
arts = []
for path, primary in ((usi, True), (deb, False)):
    fn = os.path.basename(path)
    body = open(path, "rb").read()
    key = f"{slug}/{tag}/{fn}"
    s3.put_object(Bucket=bucket, Key=key, Body=body,
                  ContentType="application/octet-stream")
    arts.append({"filename": fn, "platform": "linux", "arch": "x64",
                 "sizeBytes": len(body),
                 "sha256": hashlib.sha256(body).hexdigest(),
                 "r2Key": key, "primary": primary})
    print(f"   R2: {fn} ({len(body)//1048576} MB)")
json.dump({"tag": tag, "name": f"{name} {ver}",
           "notes": "Quick OS / Linux: double-click the .usi one-click "
                    "installer (CMS-signed, verified against the QuickOpen "
                    "Root CA), or `apt install quickopen-quick-browser` from "
                    "the AIQuick repository. Built from Chromium with the "
                    "ungoogled-chromium patch set; free codecs only.",
           "prerelease": False, "artifacts": arts},
          open(f"/tmp/rel-{slug}.json", "w"))
PY

PAYLOAD="$(python3 -c "
import json
m = json.load(open('$REPO/.quickopen.json'))
print(json.dumps({'slug': m['slug'], 'name': m['name'], 'tagline': m['tagline'],
  'description': m['description'], 'categorySlug': m['categorySlug'],
  'license': m['license'], 'githubOwner': 'quickpod', 'githubRepo': m['slug'],
  'defaultBranch': 'main',
  'website': 'https://github.com/quickpod/' + m['slug'],
  'aiStack': m['aiStack']}))")"
curl -s -X POST $API/update/admin/projects -H "Authorization: Bearer $AT" \
     -H 'Content-Type: application/json' -d "$PAYLOAD" >/dev/null
curl -s -X POST $API/update/admin/projects/$SLUG/releases -H "Authorization: Bearer $AT" \
     -H 'Content-Type: application/json' -d @/tmp/rel-$SLUG.json >/dev/null
curl -s -X POST $API/update/admin/projects/$SLUG/status -H "Authorization: Bearer $AT" \
     -H 'Content-Type: application/json' -d '{"status":"published"}' >/dev/null

STATUS="$(curl -s $API/v1/projects/$SLUG | python3 -c "
import json,sys
p = json.load(sys.stdin); print(p.get('status'), p.get('latestVersion'))")"
echo "   portal: $STATUS -> https://quickopen.ai/projects/$SLUG"

say "icon + screenshots"
"$ROOT/publish/scripts/upload-icons.sh" "$SLUG" >/dev/null 2>&1 && echo "   icon ok" || echo "   !! icon upload failed"
"$ROOT/publish/scripts/refresh-screenshots.sh" "$SLUG" 2>&1 | tail -1
