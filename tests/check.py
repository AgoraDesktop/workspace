# Copyright © 2026 Kyle J. Cardoza.
# SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
# SPDX-License-Identifier: GPL-3.0-or-later
# Portions of this file may derive from GNUstep; see THIRD-PARTY.md.

#!/usr/bin/env python3
"""Read the window server's screenshot and assert the desktop's two levels.

THE DESKTOP IS TWO WINDOWS NOW, and the interesting assertions are about their ORDER and the upper one's
TRANSPARENCY:

  * the WALLPAPER window (`kCGDesktopWindowLevel`) covers the screen;
  * Workspace's ICON window (`kCGDesktopIconWindowLevel`) is TRANSPARENT — the wallpaper shows through it
    wherever there is no icon — and an icon appears where its sidecar says it goes;
  * an ordinary window over both is on top;

AND THE MENU BAR IS NOW THREE SURFACES RATHER THAN ONE, and the third is the interesting one. The server owns the
strip and the System menu's square; an application's own menus are a window of ITS OWN at the same level, as wide as
its titles; and the CLOCK is an `NSStatusItem` — a window the APPLICATION draws that the SERVER PACKS against the
screen's right edge, because an application does not know what else is in the bar and therefore cannot know where its
own item goes. The last checks read all three off the pixels: ink where the server left room for the menus, none past
where the titles end, and the time packed in at the right end with the bar's own face around it.
"""
import os
import sys
from PIL import Image

SERVER_BG = (168, 222, 217)      # output.c's AWS_BACKGROUND
BAR = (235, 235, 235)            # server.h's AWS_MENU_BAR_COLOUR — now composited at its own LEVEL, above the desktop
NORMAL_AT = (200, 200)
NORMAL_SIZE = (320, 200)
SCREEN = (1280, 720)

# **WHERE AN APPLICATION'S OWN MENUS MAY BEGIN, AND HOW FAR THEY REACH.** The server names the region
# (`AWS_SYSTEM_MENU_WIDTH + AWS_SYSTEM_MENU_GAP` = 26 + 10) and the AppKit measures the titles into a window of
# their own width — MEASURED, 410.861 pt for the seven menus Workspace installs, and its own DIAG line prints the
# arithmetic (`APPKIT_MENUBAR_DIAG=1`). The glyph at x = 10..25 is the server's.
MENU_BAR_INK_LEFT = 36
MENU_BAR_INK_RIGHT = 440

# **HOW MUCH OF THE STRIP'S RIGHT END THE CLOCK MAY OCCUPY.** The item is as wide as the locale's short time plus ten
# points of air, so its width moves with the locale and the font — 44 points for "10:05" at 13-point Helvetica, 62 for
# "7:14 AM". A hundred and twenty is not a measurement of the clock; it is the room this suite allows one, and what is
# asserted INSIDE it is the measurement: ink, packed against the edge, on the bar's face.
CLOCK_ZONE = 120


def strip_ink(px, x0, x1):
    """Dark pixels in the menu-bar strip (rows 2..21). The strip is one flat colour and the only ink in it that is
    NOT an application's is the server's System glyph at x = 10..25 — so ink to the right of the glyph is a
    menu's."""
    return sum(1 for y in range(2, 22) for x in range(x0, x1) if all(c < 150 for c in px[x, y]))


def ink_columns(px, x0, x1):
    """The COLUMNS of the menu-bar strip that carry ink — the shape a packer's answer has, where `strip_ink`'s count
    is enough to say only that something is there."""
    return [x for x in range(x0, x1) if any(all(c < 150 for c in px[x, y]) for y in range(2, 22))]
# A point clear of the icon, of the normal window, and of any label — where a TRANSPARENT icon window must show
# the wallpaper straight through.
EMPTY_AT = (640, 400)


def near(a, b, tol=12):
    return all(abs(x - y) <= tol for x, y in zip(a, b))


def icon_ink(px, x, y, size):
    """Whether the stored rectangle holds LIGHT ink. The F2 generic document is a light page, and the wallpaper
    is a dark amber, so a light pixel inside the rectangle is the icon and nothing else."""
    for j in range(y + 2, y + size - 2):
        for i in range(x + 2, x + size - 2):
            r, g, b = px[i, j]
            if r > 200 and g > 200 and b > 200:
                return True
    return False


def main():
    if len(sys.argv) < 7:
        print("usage: check.py SHOT NORMAL-RRGGBB WALL-RRGGBB ICON-X ICON-Y ICON-SIZE [MENU-SHOT]")
        return 2

    path = sys.argv[1]
    normal = int(sys.argv[2], 16)
    wall = int(sys.argv[3], 16)
    icon_x = int(sys.argv[4])
    icon_y = int(sys.argv[5])
    icon_size = int(sys.argv[6])
    menu_shot = sys.argv[7] if len(sys.argv) > 7 and os.path.exists(sys.argv[7]) else None
    cnormal = ((normal >> 16) & 0xFF, (normal >> 8) & 0xFF, normal & 0xFF)
    cwall = ((wall >> 16) & 0xFF, (wall >> 8) & 0xFF, wall & 0xFF)

    im = Image.open(path).convert("RGB")
    px = im.load()
    over = (NORMAL_AT[0] + 10, NORMAL_AT[1] + 10)

    checks = [
        (f"the output is {im.size[0]}x{im.size[1]}", im.size == SCREEN),

        # 1. THE WALLPAPER WINDOW, at its own level below everything.
        ("the WALLPAPER window covers the screen at the wallpaper level",
         near(px[5, 400], cwall, 10) and near(px[SCREEN[0] - 5, 400], cwall, 10) and
         near(px[5, SCREEN[1] - 5], cwall, 10) and near(px[SCREEN[0] - 5, SCREEN[1] - 5], cwall, 10)),
        ("and it is the wallpaper window and not the server's own background",
         not near(px[5, 400], SERVER_BG, 8)),
        # THE MENU BAR IS THE SERVER'S AND IT IS ABOVE THE DESKTOP NOW: both desktop layers are painted first and
        # the bar covers their top rows, which is the LEVEL the server gives it.
        ("the SERVER'S menu bar is at the top, OVER the desktop", near(px[640, 12], BAR, 6)),

        # 2. THE ICON WINDOW IS TRANSPARENT — the wallpaper shows through where there is no icon.
        (f"THE ICON WINDOW IS TRANSPARENT: the wallpaper shows through at {EMPTY_AT}",
         near(px[EMPTY_AT[0], EMPTY_AT[1]], cwall, 10)),
        (f"an icon IS DRAWN at the position its sidecar stores ({icon_x},{icon_y})",
         icon_ink(px, icon_x, icon_y, icon_size)),
        ("and the icon's own pixel is not the wallpaper", not near(
            px[icon_x + icon_size // 2, icon_y + icon_size // 4], cwall, 10)),

        # 3. AN ORDINARY WINDOW, over both.
        (f"a NORMAL window is composited OVER the desktop at {over}",
         near(px[over[0], over[1]], cnormal, 6)),
        ("and it is not the wallpaper showing through",
         not near(px[over[0], over[1]], cwall, 10)),

        # 4. **THE CLOCK, WHICH IS AN APPLICATION'S AND NOT THE BAR'S.** A status item is placed by the SERVER and drawn
        # by the APPLICATION, and — unlike a menu bar — it stays on the strip when the application is not active,
        # because a clock that came and went with the front window would be a window and not a clock. This scene has
        # another client's window in front, so the menus are absent and the clock is not.
        ("THE CLOCK IS IN THE STRIP even with another application in front — a status item is not a window",
         len(ink_columns(px, SCREEN[0] - CLOCK_ZONE, SCREEN[0])) > 20),
    ]

    # 4. **THE APPLICATION'S MENU BAR, READ FROM A SCENE WHERE WORKSPACE IS THE ACTIVE APPLICATION.** A menu bar
    # belongs to the application the COMPOSITOR gave the keyboard to, and the scene above has an ordinary window
    # in front of the desktop — so Workspace's menus are correctly NOT on that strip. This is the OTHER scene: the
    # application alone, which is the one where its own bar has something to say.
    if menu_shot is not None:
        mim = Image.open(menu_shot).convert("RGB")
        mpx = mim.load()
        clock_ink = ink_columns(mpx, SCREEN[0] - CLOCK_ZONE, SCREEN[0])
        checks += [
            (f"the second scene is also {mim.size[0]}x{mim.size[1]}", mim.size == SCREEN),
            ("WITH WORKSPACE ALONE, its menu bar IS drawn in the strip, right of the System menu",
             strip_ink(mpx, MENU_BAR_INK_LEFT, MENU_BAR_INK_RIGHT) > 100),
            ("and its first title begins where the server said an application's menus may",
             strip_ink(mpx, MENU_BAR_INK_LEFT, MENU_BAR_INK_LEFT + 44) > 0),
            ("and the server's System menu still shows to its left",
             strip_ink(mpx, 10, 26) > 0),

            # **AND THE CLOCK IS THE THIRD SURFACE: THE SERVER'S STRIP, THE APPLICATION'S MENUS, AND AN ITEM THE
            # SERVER PACKS.** The item is the application's (the view and the digits are Workspace's) and the position
            # is not: it is flushed against the right edge, which is the one thing an application cannot ask for and
            # the strip's packer decides. What is measured is therefore three claims at once — that the item is there,
            # that its ink stops short of the edge by its own padding rather than being clipped by it, and that the
            # strip between the menus and the clock is the bar's face and nothing else.
            (f"THE CLOCK is in the strip's right end ({len(clock_ink)} column(s) of ink)", len(clock_ink) > 20),
            (f"and it is PACKED AGAINST THE EDGE: its last ink is at x = {max(clock_ink) if clock_ink else -1}",
             bool(clock_ink) and max(clock_ink) >= SCREEN[0] - 20),
            ("with its own padding before the edge, so the time is not clipped by the screen",
             bool(clock_ink) and max(clock_ink) < SCREEN[0] - 2),
            ("the strip between the menus and the clock is the bar's alone",
             strip_ink(mpx, 520, SCREEN[0] - CLOCK_ZONE) == 0),
            ("and the item paints the bar's own face out to the edge, so it is a piece of the bar",
             near(mpx[SCREEN[0] - 2, 12], BAR, 6)),
        ]

    failed = 0
    for name, ok in checks:
        print(f"  [{'ok' if ok else 'FAIL'}] {name}")
        failed += 0 if ok else 1
    print(f"check: {len(checks)} checks, {failed} failed" + (" -- all checks passed" if not failed else ""))
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
