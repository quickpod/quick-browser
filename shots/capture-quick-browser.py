#!/usr/bin/env python3
r"""Dual-theme screenshots of Quick Browser for the portal listing.

Modelled on quickoffice-engine/shots/capture-quickoffice.py — same X-level
approach, because this is likewise a native binary rather than one of the tk
apps. Three things differ and each one matters:

  * THEME IS A FLAG, NOT A GTK THEME. Quick Office switches appearance by
    seeding a user profile, and the fleet's other native capture leans on
    GTK_THEME=Adwaita:dark. This host has only the "Default" and "Emacs" GTK
    themes installed, so that lever does nothing here. Chromium's own
    --force-dark-mode (plus WebUIDarkMode for the chrome:// pages) is what
    actually darkens the UI, and it is also closer to what a user toggles.
  * CAPTURE RUNS AS A NON-ROOT USER, ON PURPOSE. Chromium refuses to start as
    root unless it is given --no-sandbox, and that flag paints a yellow
    "unsupported command-line flag" banner across the top of every window —
    straight into the store listing. So instead of suppressing the banner we
    remove its cause: the browser is launched as $CAPTURE_USER with a SUID
    chrome-sandbox, which is also exactly how the shipped deb runs it. The
    screenshots are therefore of the configuration users actually get.
  * chrome:// URLS CANNOT BE PASSED ON THE COMMAND LINE. Chromium silently
    drops them and opens the New Tab page instead (this is a deliberate
    restriction, and it is also why --dump-dom chrome://credits returns the
    NTP). They have to be typed into the omnibox like a user would, hence the
    ctrl+l / type / Return dance below.
  * WAIT FOR THE WINDOW TO SETTLE, AND DO NOT RESIZE IT. Chromium maps its
    window before painting the tab strip and omnibox, so grabbing on first
    sight yields a grey rectangle. Resizing after the page has laid out is
    worse: the capture catches the old layout mid-reflow, with content clipped
    at the right edge. Ask for the final size up front via --window-size and
    never touch it again.

    capture-quick-browser.py [builddir] [outdir]
"""

import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_BUILD = "/home/ubuntu/quickopen/browser/src-checkout/src/out/QuickBrowser"
DEFAULT_OUT = "/home/ubuntu/quickopen/publish/screenshots/quick-browser"
DISPLAY = ":97"          # :96 is quickoffice's, so both can run in one session
WIN_W, WIN_H = 1600, 1000
# The screen is the window size: with no window manager running, a window that
# is smaller than the screen sits on a black field, and anything larger is
# clipped. Matching them makes the grab exactly the browser.
SCREEN = "%dx%dx24" % (WIN_W, WIN_H)
CAPTURE_USER = os.environ.get("CAPTURE_USER", "ubuntu")

# The scenes. chrome://credits earns its place: shipping a reachable credits
# page is how the BSD-3 attribution obligation is discharged, so photographing
# it is evidence the obligation is met, not decoration.
# quickopen.ai rather than a synthetic local page: the point of a browser
# screenshot is that it renders the real web, and using our own property keeps
# someone else's trademarks out of our store listing.
SCENES = [
    ("1", "https://quickopen.ai/"),
    ("2", "chrome://credits/"),
    ("3", "chrome://settings/privacy"),
]


def sh(cmd, **kw):
    return subprocess.run(cmd, shell=isinstance(cmd, str),
                          capture_output=True, text=True, **kw)


def start_xvfb():
    if sh(["xdpyinfo", "-display", DISPLAY]).returncode == 0:
        return None
    # -ac: the browser runs as CAPTURE_USER while this script (and `import`)
    # run as root, so the display has to accept both. It is a throwaway
    # in-memory display on a build host, not a session anyone logs into.
    p = subprocess.Popen(["Xvfb", DISPLAY, "-screen", "0", SCREEN,
                          "-dpi", "96", "-ac"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(2)
    return p


def make_suid_sandbox(build):
    """Install a SUID copy of chrome_sandbox and return its path.

    The build tree's own copy is not SUID (ninja cannot set that bit), and the
    sandbox binary must be root-owned mode 4755 or Chromium refuses to use it.
    """
    src = os.path.join(build, "chrome_sandbox")
    if not os.path.isfile(src):
        return None
    dst = "/tmp/quick-browser-capture-sandbox"
    shutil.copy2(src, dst)
    os.chown(dst, 0, 0)
    os.chmod(dst, 0o4755)
    return dst


def navigate(wid, url, env):
    """Type a URL into the omnibox. Required for chrome:// (see docstring)."""
    subprocess.run(["xdotool", "windowfocus", "--sync", wid],
                   env=env, capture_output=True)
    subprocess.run(["xdotool", "key", "--clearmodifiers", "ctrl+l"],
                   env=env, capture_output=True)
    time.sleep(1)
    subprocess.run(["xdotool", "type", "--clearmodifiers", "--delay", "30", url],
                   env=env, capture_output=True)
    subprocess.run(["xdotool", "key", "--clearmodifiers", "Return"],
                   env=env, capture_output=True)


def wait_for_window(env, timeout=90):
    """Return the window id once one exists AND has stopped changing size."""
    end, last, stable = time.time() + timeout, None, 0
    while time.time() < end:
        r = subprocess.run(["xdotool", "search", "--onlyvisible", "--name", "."],
                           capture_output=True, text=True, env=env)
        ids = [i for i in r.stdout.split() if i.strip()]
        if ids:
            wid = ids[-1]
            g = subprocess.run(["xdotool", "getwindowgeometry", wid],
                               capture_output=True, text=True, env=env).stdout
            if g == last and g.strip():
                stable += 1
                if stable >= 3:
                    return wid
            else:
                stable = 0
            last = g
        time.sleep(1)
    return None


def capture(build, outdir):
    chrome = os.path.join(build, "chrome")
    if not os.path.isfile(chrome):
        print("no browser at", chrome, "- has the build finished?")
        return 1
    os.makedirs(outdir, exist_ok=True)
    base_env = dict(os.environ, DISPLAY=DISPLAY, LANG="en_US.UTF-8")
    sandbox = make_suid_sandbox(build)
    if sandbox is None:
        print("no chrome_sandbox in", build,
              "- build it: ninja -C <out> chrome_sandbox")
        return 1
    rc = 0
    for scene, url in SCENES:
        for theme in ("light", "dark"):
            prof = tempfile.mkdtemp(prefix="qb-prof-")
            shutil.chown(prof, CAPTURE_USER, CAPTURE_USER)
            argv = [
                "sudo", "-n", "-u", CAPTURE_USER,
                "env", "DISPLAY=" + DISPLAY,
                "CHROME_DEVEL_SANDBOX=" + sandbox,
                chrome,
                "--user-data-dir=" + prof,
                "--no-first-run",
                "--no-default-browser-check",
                "--disable-gpu",             # Xvfb has no GL
                "--window-size=%d,%d" % (WIN_W, WIN_H),
                "--window-position=0,0",
            ]
            if theme == "dark":
                argv += ["--force-dark-mode",
                         "--enable-features=WebUIDarkMode"]
            # chrome:// is typed in later; anything else can be an argument
            cmdline_url = "about:blank" if url.startswith("chrome://") else url
            argv.append(cmdline_url)
            proc = subprocess.Popen(argv, env=base_env,
                                    stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL)
            wid = wait_for_window(base_env)
            if wid:
                if cmdline_url != url:
                    navigate(wid, url, base_env)
                # credits is a 19 MB document; give it room to lay out
                time.sleep(10 if "credits" in url else 6)
                out = os.path.join(outdir, "shot-%s-%s.png" % (scene, theme))
                g = subprocess.run(["import", "-display", DISPLAY,
                                    "-window", wid, out],
                                   capture_output=True, text=True)
                if g.returncode == 0 and os.path.isfile(out):
                    print("  wrote %s (%s)" % (os.path.basename(out), url),
                          flush=True)
                else:
                    print("  !! grab failed for scene", scene, theme,
                          g.stderr[:120])
                    rc = 1
            else:
                print("  !! no window for scene", scene, theme)
                rc = 1
            proc.terminate()
            try:
                proc.wait(timeout=20)
            except subprocess.TimeoutExpired:
                proc.kill()
            # the profile is owned by CAPTURE_USER; root can still remove it
            shutil.rmtree(prof, ignore_errors=True)
    return rc


def main():
    build = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_BUILD
    outdir = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_OUT
    x = start_xvfb()
    try:
        return capture(build, outdir)
    finally:
        if x is not None:
            x.terminate()


if __name__ == "__main__":
    sys.exit(main())
