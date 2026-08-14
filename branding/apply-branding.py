#!/usr/bin/env python3
r"""Turn a patched Chromium tree into Quick Browser.

    apply-branding.py <src>        e.g. ../../browser/src-checkout/src

Run AFTER fetch-source.sh, BEFORE configure. Idempotent: the first run stashes
the untouched strings file as chromium_strings.grd.upstream and every run
rewrites from THAT, so re-running cannot double-apply (which would otherwise
turn "Quick Browser" into "Quick Quick Browser" on the second pass).

WHAT GETS CHANGED, AND WHAT DELIBERATELY DOES NOT

Chromium has one supported branding hook -- chrome/app/theme/chromium/BRANDING
-- and it is nowhere near sufficient. It sets the product name for the
installer and a handful of build-time defines; the ~660 user-visible strings
are hardcoded in chromium_strings.grd. So this does three things:

  1. BRANDING            product/company identity, bundle id
  2. chromium_strings.grd  the strings a user actually reads
  3. theme/chromium/*.png  the icon, at every size Chromium asks for

Three names must SURVIVE the rename, and getting this wrong is the whole risk
of a blind find-and-replace:

  * "The Chromium Authors"  - a COPYRIGHT LINE. Rewriting it would strip the
    upstream attribution BSD-3-Clause requires us to keep, turning a licence
    obligation into a licence violation. This is the one that matters.
  * "ChromiumOS"            - refers to the OS, not to us. 17 occurrences.
  * "chromium.org"          - real URLs that must keep resolving.

google_chrome_strings.grd is NOT touched. It is only compiled when
is_chrome_branded=true, which is a Google-internal build we cannot produce and
would not want to; leaving it pristine keeps the diff honest.
"""

import io
import os
import re
import sys

import cairosvg
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
SVG = os.path.join(HERE, "quick-browser.svg")

PRODUCT = "Quick Browser"
COMPANY = "QuickOpen"
BUNDLE = "ai.quickopen.QuickBrowser"

BRANDING = """COMPANY_FULLNAME={company}
COMPANY_SHORTNAME={company}
PRODUCT_FULLNAME={product}
PRODUCT_SHORTNAME={product}
PRODUCT_INSTALLER_FULLNAME={product} Installer
PRODUCT_INSTALLER_SHORTNAME={product} Installer
COPYRIGHT=Copyright @LASTCHANGE_YEAR@ {company}. Based on Chromium, (c) The Chromium Authors.
MAC_BUNDLE_ID={bundle}
MAC_CREATOR_CODE=QkBr
MAC_TEAM_ID=
""".format(company=COMPANY, product=PRODUCT, bundle=BUNDLE)

# Replace "Chromium" EXCEPT where it is followed by "OS" or " Authors".
# One expression, so there is exactly one place to audit.
KEEP = re.compile(r"Chromium(?!OS)(?! Authors)")


def rename(text):
    return KEEP.sub(PRODUCT, text)


def png(path, size, mono=False):
    buf = io.BytesIO()
    cairosvg.svg2png(bytestring=open(SVG, "rb").read(), write_to=buf,
                     output_width=size, output_height=size)
    buf.seek(0)
    img = Image.open(buf).convert("RGBA")
    if mono:
        # Status-tray icons must be a single-colour silhouette: the tray tints
        # them, so any colour we bake in fights the theme.
        a = img.split()[3]
        img = Image.merge("RGBA", (
            Image.new("L", img.size, 255), Image.new("L", img.size, 255),
            Image.new("L", img.size, 255), a))
    img.save(path)
    return img


def xpm(path, size):
    """Chromium still ships a 32px XPM for older window managers, and PIL can
    read XPM but not write it, so emit one by hand.

    The colour budget is set by the ONE-CHARACTER code, not by taste: printable
    ASCII minus the quote and backslash leaves 93 usable codes, and one is
    reserved for transparent. Quantise above that and the writer runs off the
    end of the code table."""
    buf = io.BytesIO()
    cairosvg.svg2png(bytestring=open(SVG, "rb").read(), write_to=buf,
                     output_width=size, output_height=size)
    buf.seek(0)
    src = Image.open(buf).convert("RGBA")
    alpha = src.split()[3]
    q = src.convert("RGB").quantize(colors=92)
    pal = q.getpalette()
    # Printable ASCII, minus the quote and backslash that would need escaping.
    codes = [chr(c) for c in range(32, 127) if chr(c) not in '"\\']
    used, rows = {}, []
    for y in range(size):
        row = ""
        for x in range(size):
            if alpha.getpixel((x, y)) < 128:
                used.setdefault("none", codes[0])
                row += codes[0]
                continue
            i = q.getpixel((x, y))
            hexc = "#%02x%02x%02x" % tuple(pal[i * 3:i * 3 + 3])
            if hexc not in used:
                used[hexc] = codes[len(used)]
            row += used[hexc]
        rows.append(row)
    with open(path, "w", encoding="ascii") as fh:
        fh.write("/* XPM */\nstatic char * product_logo_%d_xpm[] = {\n" % size)
        fh.write('"%d %d %d 1",\n' % (size, size, len(used)))
        for k, v in used.items():
            fh.write('"%s c %s",\n' % (v, "None" if k == "none" else k))
        fh.write(",\n".join('"%s"' % r for r in rows))
        fh.write("};\n")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    src = os.path.abspath(sys.argv[1])
    theme = os.path.join(src, "chrome", "app", "theme", "chromium")
    grd = os.path.join(src, "chrome", "app", "chromium_strings.grd")
    if not os.path.isdir(theme) or not os.path.isfile(grd):
        print("not a Chromium source tree: %s" % src)
        return 1
    if not os.path.isfile(SVG):
        print("icon missing -- run make-icon.py first")
        return 1

    # 1. BRANDING
    with open(os.path.join(theme, "BRANDING"), "w", encoding="utf-8") as fh:
        fh.write(BRANDING)
    print("BRANDING          -> %s / %s" % (PRODUCT, COMPANY))

    # 2. strings. Keep a pristine copy the first time so re-runs rewrite from
    #    upstream rather than from our own output.
    orig = grd + ".upstream"
    if not os.path.exists(orig):
        os.replace(grd, orig)
    text = open(orig, encoding="utf-8").read()
    out = rename(text)
    open(grd, "w", encoding="utf-8").write(out)
    print("chromium_strings  -> %d renamed, %d ChromiumOS + %d Authors kept"
          % (len(KEEP.findall(text)),
             text.count("ChromiumOS"), text.count("Chromium Authors")))

    # 3. icons
    n = 0
    for size in (16, 24, 32, 48, 64, 128, 256):
        p = os.path.join(theme, "product_logo_%d.png" % size)
        if os.path.exists(p):
            png(p, size)
            n += 1
        p = os.path.join(theme, "linux", "product_logo_%d.png" % size)
        if os.path.exists(p):
            png(p, size)
            n += 1
    mono = os.path.join(theme, "product_logo_22_mono.png")
    if os.path.exists(mono):
        png(mono, 22, mono=True)
        n += 1
    x = os.path.join(theme, "linux", "product_logo_32.xpm")
    if os.path.exists(x):
        xpm(x, 32)
        n += 1
    import shutil
    shutil.copyfile(SVG, os.path.join(theme, "product_logo.svg"))
    n += 1
    print("icons             -> %d files replaced" % n)

    print("\nbranded. next: configure-quick-browser.sh")
    return 0


if __name__ == "__main__":
    sys.exit(main())
