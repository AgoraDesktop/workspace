# workspace

**Workspace is Agora's file manager and desktop** — the Finder's role: the windows that browse the filesystem
and the wallpaper-and-icons surface behind everything.

Agora is an installable desktop environment for Linux and the BSDs; see the project README in the parent
directory (`../README.md`). Workspace is an **application**: it consumes the AppKit as a built package
(`AgoraApp::App`) and installs no package of its own.

## Status

**W0 and W1 are done — and the desktop is TWO LEVELS: Workspace owns the ICON layer, not the wallpaper.** It
launches from its bundle, opens one borderless window at `kCGDesktopIconWindowLevel` — **TRANSPARENT** — and
draws only the items of a directory. The WALLPAPER is a separate window at `kCGDesktopWindowLevel`, and it is the
**Dock's** to draw.

```
$ .../Workspace.app/Contents/MacOS/Workspace --seconds 3
workspace: desktop window at level -2147483628, frame 1280x720 at (0,0)
```

`-2147483628` is `kCGDesktopWindowLevel` (`INT32_MIN + 20`, from `libagora-drawing`'s `CGWindowLevel.h`) — the
level **below every ordinary window**, which is what makes this the desktop rather than a window. The frame is
the whole screen, `[NSScreen frame]` and not `visibleFrame`, because the Dock and the menu bar are drawn
*over* the wallpaper.

### What is measured, not assumed

`ctest` runs one suite, `tests/run-desktop.sh` + `tests/check.py`, against **Agora's own window server**,
headless. It runs the **bundle's** executable (the bundle path is part of what W0 proves), then places a
**normal** window over the desktop with the server's own test client, and reads the server's screenshot.
**9 checks, 0 fail**:

- the **wallpaper window** (at `kCGDesktopWindowLevel`) covers the screen, at its own level;
- **Workspace's icon window is TRANSPARENT** — the wallpaper shows through it wherever there is no icon;
- an **icon** is drawn where its sidecar says it goes;
- a **normal window created *after* the desktop is composited *over* it** — which can only be the level.

### W1: the desktop's icons

Three objects, and the Finder **window's** views will be built from the same three:

- **`WSItemModel`** — one directory's items, and the one model every view reads (`WORKSPACE-PLAN.md` §6).
- **`WSIconLayout`** — pure geometry: a column-major grid, the nearest-free snap a drop lands on, an arrange
  order, and a hit test. It needs no view, which is why it is checked **offscreen**.
- **`WSMetadataStore`** — the per-folder `.agora` sidecar: icon positions and the icon size.

**Positions are TOP-LEFT SCREEN COORDINATES** (the Finder's own convention, and what the store persists); the
view converts to Cocoa only to draw and to hit-test. The sidecar is **XML**, because that is what this tree's
`NSPropertyListSerialization` writes — MEASURED: it refuses the binary format — and a sidecar that diffs is one a
person can inspect.

### The one thing W0 does not fix, measured rather than assumed away

`window-server/src/output.c` draws its menu-bar strip **before** the windows and says so: *"until the strip has
a LEVEL of its own such a window covers it. The level is the next step."* A full-screen desktop window is
exactly such a window, so **the strip is currently covered by the desktop**. Giving the strip a level of its
own is the menubar's task, not the desktop's, and the suite accepts either the strip or the wallpaper in the
top rows while refusing the background — so the fact is measured, not hidden.

## What is here (W0 and W1)

```
src/
  main.m            the entry point: NSApplication, the controller, a timed pump
  WSApplication.m   the controller that owns the desktop; why it is not an NSApplication subclass is in its header
  WSDesktopWindow.m the borderless window at kCGDesktopWindowLevel, the size of the screen
  WSDesktopView.m   the ICONS only — selection, rubber band, drag, double-click open (transparent; no wallpaper)
  WSIconLayout.m    the grid, the snap, the arrange order and the hit test — pure geometry
  WSItemModel.m     one directory's items, the one model every view reads
  WSMetadataStore.m the per-folder `.agora` sidecar: icon positions and the icon size
Info.plist.in       the bundle's Info.plist
tests/              the three suites: run-desktop.sh + check.py (pixels), desktop_layout, metadata_store
```

## What is deliberately not here yet

The plan's later stages: the file **window** and its views (W2–W5), file operations and the Trash (W6), drag and
drop (W7), Get Info (W8), Quick Look (W9), search (W10), volumes (W11) and the shell integration (W13). Their
substrate — Launch Services, Icon Services and the change stream — is already built
(`../libagora-launchservices`, `../libagora-iconservices`, `../libagora-watch`).

**What W1 does not do yet, named:** the desktop is not LIVE (`libagora-watch` is built, but `WSItemModel`
reloads on demand rather than from a stream callback); a folder double-click is a Finder window, which is W2; a
document's icon is its TYPE's generic and not its own content (`AGIconCreateWithURL` already prefers an
application's declared icon); and the sidecar holds the icon size and the positions, not yet grid spacing or
label placement.

## Build and run

```sh
cmake -S . -B build -DCMAKE_C_COMPILER=/usr/bin/clang-19 -DCMAKE_OBJC_COMPILER=/usr/bin/clang-19 \
      -DCMAKE_PREFIX_PATH=../build-prefix -DCMAKE_INSTALL_PREFIX=../build-prefix
cmake --build build
cd build && ctest -R workspace-desktop --output-on-failure
```

The AppKit must be built and **installed** into the prefix first (`cmake --install ../libagora-app/build`);
W0 is the first component to consume it as a package, and doing so is what turned AppKit's previously-unrun
install rules on.

## Licence

MIT — see [`LICENSE`](LICENSE).
