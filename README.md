# workspace

**Workspace is Agora's file manager and desktop** — the Finder's role: the windows that browse the filesystem
and the wallpaper-and-icons surface behind everything.

Agora is an installable desktop environment for Linux and the BSDs; see the project README in the parent
directory (`../README.md`). Workspace is an **application**: it consumes the AppKit as a built package
(`AgoraApp::App`) and installs no package of its own.

## Status

**W0 is done: Workspace launches from its bundle and owns the desktop.**

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

- the desktop window **covers the screen** — the corners are the wallpaper, not the compositor's background;
- the wallpaper is a vertical **ramp the right way up**: an upper row is lighter than a lower one, and each row
  matches the ramp's value at that height;
- a **normal window created *after* the desktop is composited *over* it** — which can only be the level;
- and the top rows are the wallpaper or the server's bar, never the compositor's background.

### The one thing W0 does not fix, measured rather than assumed away

`window-server/src/output.c` draws its menu-bar strip **before** the windows and says so: *"until the strip has
a LEVEL of its own such a window covers it. The level is the next step."* A full-screen desktop window is
exactly such a window, so **the strip is currently covered by the desktop**. Giving the strip a level of its
own is the menubar's task, not the desktop's, and the suite accepts either the strip or the wallpaper in the
top rows while refusing the background — so the fact is measured, not hidden.

## What is here (W0)

```
src/
  main.m            the entry point: NSApplication, the controller, a timed pump
  WSApplication.m   the controller that owns the desktop; why it is not an NSApplication subclass is in its header
  WSDesktopWindow.m the borderless window at kCGDesktopWindowLevel, the size of the screen
  WSDesktopView.m   the Argentum wallpaper, a vertical ramp
Info.plist.in       the bundle's Info.plist
tests/              run-desktop.sh + check.py — the W0 suite
```

## What is deliberately not here yet

The plan's later stages: desktop **icons** (W1), the file **window** and its views (W2–W5), file operations and
the Trash (W6), drag and drop (W7), Get Info (W8), Quick Look (W9), search (W10), volumes (W11) and the shell
integration (W13). Their substrate — Launch Services, Icon Services and the change stream — is already built
(`../libagora-launchservices`, `../libagora-iconservices`, `../libagora-watch`).

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
