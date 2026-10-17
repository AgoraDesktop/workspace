#!/usr/bin/env python3
"""Read the window server's screenshot and assert that Workspace owns the desktop.

THE ASSERTION IS COVERAGE AND ORDER, NOT A PICTURE. The wallpaper is a vertical RAMP whose two endpoints are
ARGENTUM.md's own samples, so a sample can be compared against the ramp's value at its row — which is stronger
than a single colour, because it also proves the window is the right way UP. And a NORMAL window is created
after the desktop and must still be BELOW it, so the order can only come from the level.

THE MENU BAR IS MEASURED, NOT ASSUMED AWAY. `window-server/src/output.c` draws its strip FIRST and says "the
level is the next step", so a full-screen window at any level currently covers it. The check therefore accepts
EITHER the strip or the wallpaper in the top rows — and refuses the server's own aqua background, which would
mean the desktop window never covered the screen at all.
"""
import sys
from PIL import Image

SERVER_BG = (168, 222, 217)      # output.c's AWS_BACKGROUND
BAR = (235, 235, 235)            # server.h's AWS_MENU_BAR_COLOUR
BAR_H = 24
WALL_TOP = (108, 55, 29)         # ARGENTUM.md: the mockup's warm amber
WALL_BOTTOM = (18, 14, 5)        # ARGENTUM.md: its near-black corners
NORMAL_AT = (200, 200)
NORMAL_SIZE = (320, 200)
SCREEN = (1280, 720)


def ramp(row, height=SCREEN[1]):
    """The wallpaper's colour at a screen row, from the same two endpoints the view interpolates."""
    t = row / (height - 1.0)
    return tuple(round(a + (b - a) * t) for a, b in zip(WALL_TOP, WALL_BOTTOM))


def near(a, b, tol=12):
    return all(abs(x - y) <= tol for x, y in zip(a, b))


def icon_ink(px, x, y, size):
    """Whether the stored rectangle holds LIGHT ink. The F2 generic document is a light page, and the wallpaper
    at those rows is dark, so a light pixel inside the rectangle is the icon and nothing else."""
    for j in range(y + 2, y + size - 2):
        for i in range(x + 2, x + size - 2):
            r, g, b = px[i, j]
            if r > 200 and g > 200 and b > 200:
                return True
    return False


def main():
    if len(sys.argv) < 6:
        print("usage: check.py SHOT.ppm NORMAL-RRGGBB ICON-X ICON-Y ICON-SIZE")
        return 2

    path = sys.argv[1]
    normal = int(sys.argv[2], 16)
    icon_x = int(sys.argv[3])
    icon_y = int(sys.argv[4])
    icon_size = int(sys.argv[5])
    cnormal = ((normal >> 16) & 0xFF, (normal >> 8) & 0xFF, normal & 0xFF)
    im = Image.open(path).convert("RGB")
    px = im.load()

    over = (NORMAL_AT[0] + 10, NORMAL_AT[1] + 10)
    low = (NORMAL_AT[0] + NORMAL_SIZE[0] - 10, NORMAL_AT[1] + NORMAL_SIZE[1] - 10)
    # Clear of the bar's own shadow, which falls on the wallpaper just below the strip.
    upper_row = 80
    lower_row = 700

    checks = [
        (f"the output is {im.size[0]}x{im.size[1]}", im.size == SCREEN),

        ("the desktop COVERS the screen: the upper-left is the wallpaper, not the server's background",
         near(px[5, upper_row], ramp(upper_row), 16) and not near(px[5, upper_row], SERVER_BG, 10)),

        ("and the lower-left is the wallpaper's dark end",
         near(px[5, lower_row], ramp(lower_row), 16) and not near(px[5, lower_row], SERVER_BG, 10)),

        ("and the right edge, top to bottom",
         not near(px[SCREEN[0] - 5, upper_row], SERVER_BG, 10) and
         not near(px[SCREEN[0] - 5, lower_row], SERVER_BG, 10)),

        ("the wallpaper is a RAMP, the right way up: the upper row is lighter than the lower one",
         sum(px[640, upper_row]) > sum(px[640, lower_row]) + 40 and
         near(px[640, upper_row], ramp(upper_row), 16) and near(px[640, lower_row], ramp(lower_row), 16)),

        ("the desktop reaches the TOP rows too — they are the wallpaper or the server's bar, never the background",
         (near(px[640, 12], ramp(12), 24) or near(px[640, 12], BAR, 6)) and
         not near(px[640, 12], SERVER_BG, 10)),

        (f"a NORMAL window is composited OVER the desktop at {over}",
         near(px[over[0], over[1]], cnormal, 6)),

        ("and it is not the wallpaper showing through", not near(px[over[0], over[1]], ramp(NORMAL_AT[1] + 10), 24)),

        ("and the normal window reaches its own far corner, so it is the whole window on top",
         near(px[low[0], low[1]], cnormal, 6)),

        # THE DESKTOP'S OWN ITEM: a file placed on the desktop, whose sidecar says where its icon goes.
        (f"an icon IS DRAWN at the position its sidecar stores ({icon_x},{icon_y})",
         icon_ink(px, icon_x, icon_y, icon_size)),
        ("and it is not the wallpaper showing through there",
         not near(px[icon_x + icon_size // 2, icon_y + icon_size // 4], ramp(icon_y + icon_size // 4), 24)),
    ]

    failed = 0
    for name, ok in checks:
        print(f"  [{'ok' if ok else 'FAIL'}] {name}")
        failed += 0 if ok else 1
    print(f"check: {len(checks)} checks, {failed} failed" + (" -- all checks passed" if not failed else ""))
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
