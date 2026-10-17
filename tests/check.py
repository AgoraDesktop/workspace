#!/usr/bin/env python3
"""Read the window server's screenshot and assert the desktop's two levels.

THE DESKTOP IS TWO WINDOWS NOW, and the interesting assertions are about their ORDER and the upper one's
TRANSPARENCY:

  * the WALLPAPER window (`kCGDesktopWindowLevel`) covers the screen;
  * Workspace's ICON window (`kCGDesktopIconWindowLevel`) is TRANSPARENT — the wallpaper shows through it
    wherever there is no icon — and an icon appears where its sidecar says it goes;
  * an ordinary window over both is on top.
"""
import sys
from PIL import Image

SERVER_BG = (168, 222, 217)      # output.c's AWS_BACKGROUND
BAR = (235, 235, 235)            # server.h's AWS_MENU_BAR_COLOUR — now composited at its own LEVEL, above the desktop
NORMAL_AT = (200, 200)
NORMAL_SIZE = (320, 200)
SCREEN = (1280, 720)
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
        print("usage: check.py SHOT NORMAL-RRGGBB WALL-RRGGBB ICON-X ICON-Y ICON-SIZE")
        return 2

    path = sys.argv[1]
    normal = int(sys.argv[2], 16)
    wall = int(sys.argv[3], 16)
    icon_x = int(sys.argv[4])
    icon_y = int(sys.argv[5])
    icon_size = int(sys.argv[6])
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
    ]

    failed = 0
    for name, ok in checks:
        print(f"  [{'ok' if ok else 'FAIL'}] {name}")
        failed += 0 if ok else 1
    print(f"check: {len(checks)} checks, {failed} failed" + (" -- all checks passed" if not failed else ""))
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
