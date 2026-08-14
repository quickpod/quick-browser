# Quick Browser — licensing verdict and obligations

**Question asked:** may QuickOpen build a browser from Chrome's open source and
ship it under our own brand?

**Verdict: YES, and this one is easier than Quick Office.** Chromium is
BSD-3-Clause — a permissive licence with no copyleft and no obligation to
publish our modifications. There are three conditions, all cheap. What follows
is the reasoning and the receipts.

---

## 1. Chrome is not Chromium, and only one of them is open source

This distinction is the whole basis of the project:

| | Google Chrome | Chromium |
|---|---|---|
| licence | proprietary | **BSD-3-Clause** (+ third-party licences per component) |
| branding | Google trademark, not in the source tree | open source, but still Google's mark |
| extras | Google API keys, sync, proprietary codecs, crash/usage reporting | none of it by default |

So the base is **Chromium**. "Building Chrome and rebranding it" is not a thing
that exists — Chrome's branding assets live in an internal Google repository
and a `is_chrome_branded=true` build cannot be produced outside Google. Every
derivative browser — Edge, Brave, Opera, Vivaldi, Thorium — starts from
Chromium for exactly this reason.

## 2. What BSD-3-Clause requires

The whole of it, from `LICENSE` in the Chromium tree:

1. **Keep the copyright notice** in source redistributions.
2. **Reproduce the notice** in the documentation or materials shipped with a
   binary. Chromium already has the mechanism for this — `about:credits`,
   generated from the licence metadata of every bundled component. It must
   keep working and stay reachable.
3. **The name clause:** *"Neither the name of Google LLC nor the names of its
   contributors may be used to endorse or promote products derived from this
   software without specific prior written permission."*

That is all. **No copyleft, no requirement to publish our source, no share-alike.**
We publish ours anyway because that is what QuickOpen is, but here it is a
choice rather than an obligation — the opposite of the Quick Office engine.

## 3. What the name clause actually forbids

It forbids using Google's name **to endorse or promote** Quick Browser. It does
not forbid stating a fact. So:

- ALLOWED: "Quick Browser is built from the Chromium open-source project."
- ALLOWED: "Based on Chromium." Technical, factual, in the About box.
- FORBIDDEN: "Quick Browser, from the makers of Chrome", "Google-powered",
  "Chrome-compatible browser by Google", or any layout implying endorsement.
- FORBIDDEN: the Chrome name, the Chrome logo, and the four-colour mark.
- AVOIDED BY CHOICE: the *Chromium* name and blue logo. Distributions do ship
  builds under that name, but our product is **Quick Browser** with our own
  identity, so the question does not arise.

Same shape as the LibreOffice/TDF situation in
[Quick Office](../quickoffice-engine/LICENSING.md): permissive on the code,
strict on the marks.

## 4. The obligations, and where each is discharged

| # | Obligation | Discharged by |
|---|---|---|
| 1 | BSD-3 copyright notice + third-party inventory shipped with the binary | [`NOTICE`](NOTICE) in every package, and `about:credits` left intact and linked from About |
| 2 | No use of Google's name to promote | Our own name, icon and About text; the only mention of Chromium is the factual "built from" line |
| 3 | Per-component licences for everything bundled | `about:credits` is generated from the tree at build time and covers all of them |

**No permission from Google is needed** for any of this, and none was sought.

## 5. Two things that are NOT licensing questions but decide the product

Recorded here because they get mistaken for licensing questions.

### Proprietary codecs — a PATENT question
Chromium builds without H.264/AAC unless you set `proprietary_codecs=true` and
`ffmpeg_branding="Chrome"`. The *code* is open; the **patents are not**. H.264
and AAC are covered by patent pools (Via LA, formerly MPEG-LA), and shipping a
decoder can require a licence depending on jurisdiction and distribution
volume. This is why Fedora's Chromium historically shipped without them and
why Chrome (which has the licences) does.

- **Without them:** smaller, unambiguous, and a meaningful share of video on
  the web will not play.
- **With them:** the browser behaves as users expect, and we take on the patent
  question ourselves.

There is no third option that is both complete and free of the question.

### Security updates — an operational commitment
Chromium ships security releases every two to four weeks, frequently for
vulnerabilities already being exploited. A browser fork is a standing promise
to rebase, rebuild and ship within days of each one. This is materially heavier
than the office suite, where an old build is merely dated rather than
dangerous. Any plan for Quick Browser has to include who does that and how
fast — a fork left three months behind upstream is not a privacy browser, it is
an unpatched one.

---

*Sources: the `LICENSE` file in the Chromium source tree (BSD-3-Clause),
chromium.googlesource.com/chromium/src, and the Chromium project's own
documentation on Google Chrome-branded builds.*
