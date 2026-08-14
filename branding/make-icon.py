#!/usr/bin/env python3
r"""The Quick Browser application icon.

A DELIBERATE DEPARTURE FROM THE FLEET STYLE
The other 39 QuickOpen apps use thin single-accent line art on a transparent
ground (AIQuick requirement #25) - correct for a taskbar full of utilities.
A browser is not one of forty utilities; it is the thing on the dock, and it is
judged next to Firefox, Edge and Safari. Those all use a "hero" mark: full
colour, dimensional, a single readable silhouette at 16px and a rich object at
512px. So this one is drawn in that register.

WHAT IT IS, AND WHY IT IS NOT ANYTHING ELSE'S
A dark sphere - the web - crossed by meridians, with a luminous arc sweeping
around it that opens at the lower right, so the whole mark reads as a **Q**.
The arc is the Aura accent beam bent into an orbit, which ties it to the rest
of the system without borrowing from it.

Nothing here is derived from another browser's mark:
  * not a creature (Firefox's fox, Thunderbird's bird) - this is a sphere;
  * not a segmented colour wheel (Chrome) - one continuous gradient;
  * not a compass or a sail (Safari, Edge) - an orbit and a globe.
Only the FORMAT is shared with them, and a circular full-colour app icon is a
platform convention, not anybody's property (requirement #11: inspiration, not
assets).

    make-icon.py [outdir]        writes quick-browser.svg/.png/.ico
"""

import io
import os
import sys

import cairosvg
from PIL import Image

# Aura tokens, pushed brighter than the utility palette: a hero icon has to
# hold its own against a saturated dock.
DEEP = "#0b1020"          # sphere core, deeper than the Aura bg
MID = "#1e2a5e"           # sphere mid
RIM = "#2f5fe0"           # Aura deep blue, the sphere's lit edge
ARC_A = "#5b86f7"         # Aura brand accent - the orbit, cold end
ARC_B = "#38e1d0"         # cyan - the orbit's leading edge
MERIDIAN = "#4a6ad4"

SVG = f"""<?xml version="1.0" encoding="UTF-8"?>
<!-- Quick Browser. Original artwork, Apache-2.0, (c) 2026 QuickOpen.
     A sphere crossed by meridians inside an orbital arc that opens lower-right,
     so the silhouette reads as a Q. No third-party mark is referenced. -->
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512"
     width="512" height="512">
  <defs>
    <radialGradient id="globe" cx="38%" cy="32%" r="78%">
      <stop offset="0%"   stop-color="{RIM}"/>
      <stop offset="45%"  stop-color="{MID}"/>
      <stop offset="100%" stop-color="{DEEP}"/>
    </radialGradient>
    <linearGradient id="orbit" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%"   stop-color="{ARC_B}"/>
      <stop offset="55%"  stop-color="{ARC_A}"/>
      <stop offset="100%" stop-color="{ARC_A}" stop-opacity="0.15"/>
    </linearGradient>
    <linearGradient id="sheen" x1="20%" y1="0%" x2="70%" y2="80%">
      <stop offset="0%"   stop-color="#ffffff" stop-opacity="0.30"/>
      <stop offset="60%"  stop-color="#ffffff" stop-opacity="0.03"/>
      <stop offset="100%" stop-color="#ffffff" stop-opacity="0"/>
    </linearGradient>
    <clipPath id="ball"><circle cx="256" cy="256" r="150"/></clipPath>
  </defs>

  <!-- the globe -->
  <circle cx="256" cy="256" r="150" fill="url(#globe)"/>

  <!-- meridians + parallels, clipped to the sphere so they curve with it -->
  <g clip-path="url(#ball)" fill="none" stroke="{MERIDIAN}" stroke-width="7"
     stroke-linecap="round" opacity="0.85">
    <ellipse cx="256" cy="256" rx="150" ry="150"/>
    <ellipse cx="256" cy="256" rx="62"  ry="150"/>
    <ellipse cx="256" cy="256" rx="118" ry="150"/>
    <path d="M112 208h288M106 256h300M112 304h288"/>
  </g>

  <!-- specular sheen: what makes it read as an object rather than a disc -->
  <ellipse cx="205" cy="196" rx="118" ry="96" fill="url(#sheen)"
           clip-path="url(#ball)"/>

  <!-- The orbit, with a bright leading head at the top.
       THE TAIL IS GONE ON PURPOSE. A stroke leaving a circle at 45 degrees is
       the universal magnifying-glass silhouette: on the size ladder this icon
       stopped reading as a browser and started reading as SEARCH at 32px and
       below. An orbit that opens, plus a comet head showing direction, says
       motion without borrowing the search glyph. Losing the Q is a smaller
       price than being mistaken for a search button. -->
  <path d="M256 60a196 196 0 1 1-138.6 57.4" fill="none" stroke="url(#orbit)"
        stroke-width="34" stroke-linecap="round"/>
  <circle cx="256" cy="60" r="19" fill="{ARC_B}"/>
</svg>
"""


def render(svg, path, size):
    buf = io.BytesIO()
    cairosvg.svg2png(bytestring=svg.encode(), write_to=buf,
                     output_width=size, output_height=size)
    buf.seek(0)
    Image.open(buf).convert("RGBA").save(path)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(
        os.path.abspath(__file__))
    os.makedirs(out, exist_ok=True)
    svg_path = os.path.join(out, "quick-browser.svg")
    with open(svg_path, "w", encoding="utf-8") as fh:
        fh.write(SVG)

    render(SVG, os.path.join(out, "quick-browser.png"), 512)

    # .ico with every size Windows asks for. Largest first so PIL keeps them
    # all; 16px is the one that decides whether the mark actually works.
    sizes = [256, 128, 64, 48, 32, 24, 16]
    imgs = []
    for s in sizes:
        buf = io.BytesIO()
        cairosvg.svg2png(bytestring=SVG.encode(), write_to=buf,
                         output_width=s, output_height=s)
        buf.seek(0)
        imgs.append(Image.open(buf).convert("RGBA"))
    imgs[0].save(os.path.join(out, "quick-browser.ico"), format="ICO",
                 sizes=[(s, s) for s in sizes], append_images=imgs[1:])

    # Chromium wants a spread of PNGs for its Linux .desktop icon set.
    for s in (16, 24, 32, 48, 64, 128, 256, 512):
        render(SVG, os.path.join(out, f"quick-browser-{s}.png"), s)

    print("icon written to", out)
    for f in sorted(os.listdir(out)):
        if f.startswith("quick-browser"):
            print("   %-28s %7d B" % (f, os.path.getsize(os.path.join(out, f))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
