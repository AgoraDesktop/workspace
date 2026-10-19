# workspace

**Workspace is Agora's file manager and desktop** — the file manager's role: the windows that browse the filesystem
and the wallpaper-and-icons surface behind everything.

Agora is an installable desktop environment for Linux and the BSDs; see the project README in the parent
directory (`../README.md`). Workspace is an **application**: it consumes the AppKit as a built package
(`AgoraApp::App`) and installs no package of its own.

## Status

**W0, W1 AND W1b ARE DONE; W2 IS PAUSED ON THE APPKIT.** The desktop (two levels), its icons, and the
application menu all work. The FILE WINDOW — toolbar, sidebar, path bar, view switcher — cannot be built yet,
because the AppKit has none of the classes it is made of; the inventory is in `WORKSPACE-PLAN.md` § W2p. What
exists to build on: `NSWindow`, `NSWindowController`, `NSView`/`NSViewController`, `NSScrollView`/`NSClipView`/
`NSScroller`, `NSTextField`/`Cell`, `NSButton`/`Cell`, `NSSlider`, `NSPopUpButton`, `NSTextView`, `NSImage`, the
`NSMenu` family, `NSPasteboard` and `NSTrackingArea`.

**The desktop is TWO LEVELS: Workspace owns the ICON layer, not the wallpaper.** It
launches from its bundle, opens one borderless window at `kCGDesktopIconWindowLevel` — **TRANSPARENT** — and
draws only the items of a directory. The WALLPAPER is a separate window at `kCGDesktopWindowLevel`, and it is the
**Dock's** to draw.

```
$ .../Workspace.app/Contents/MacOS/Workspace --seconds 3
workspace: desktop window at level -2147483628, frame 1280x720 at (0,0)
```

Two arguments, both TEST DOORS and named as ones: `--seconds N` ends the ordinary run loop after N seconds (a
desktop is a thing that stays, and the suite needs it to be able to leave), and `--show-about` opens the About panel
as part of starting up — the panel is otherwise reached by a menu action, and a synthetic click reaches a
compositor's motion path and not its button path on some hosts.

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

Three objects, and the file **window's** views will be built from the same three:

- **`WSItemModel`** — one directory's items, and the one model every view reads (`WORKSPACE-PLAN.md` §6).
- **`WSIconLayout`** — pure geometry: a **top-to-bottom, RIGHT-TO-LEFT** grid (macOS's own desktop order), the
  nearest-free snap a drop lands on, an arrange
  order, and a hit test. It needs no view, which is why it is checked **offscreen**.
- **`WSMetadataStore`** — the per-folder `.agora` sidecar: icon positions and the icon size.

**Positions are TOP-LEFT SCREEN COORDINATES** (the reference file manager's own convention, and what the store persists); the
view converts to Cocoa only to draw and to hit-test. The sidecar is **XML**, because that is what this tree's
`NSPropertyListSerialization` writes — MEASURED: it refuses the binary format — and a sidecar that diffs is one a
person can inspect. And the grid's **ORIGIN IS THE TOP OF ITS AREA**, not an inset it adds: the desktop hands it
a rectangle already padded by **the menu bar's height plus ten points** (`+[WSDesktopView topPadding]`, read from
`NSStatusBar -thickness`), so the first row clears the bar by ten.

### W1b: the application menu

**THE APPLICATION HAS A MENU BAR, AND IT IS THE ONE A MAC APPLICATION HAS.** Seven titles, built by
`src/WSMainMenu.m`: the application's own menu — About, Preferences…, Services, Hide, Hide Others, Show All, Quit —
and File, Edit, View, Go, Window, Help beside it. The AppKit draws it: `-[NSApplication setMainMenu:]` inserts the
application menu, moves Help last, and builds the window at `NSMainMenuWindowLevel` whose `NSMenuView` draws the
titles and opens one on a click.

**About and Preferences are real windows, not stubs.** `WSAboutPanel` shows the application's own icon, its name, its
version and its bundle identifier — every string read out of `Contents/Info.plist`, so the box cannot disagree with
the bundle it describes — and `WSPreferencesWindow` shows the one preference the application actually has and lets a
person change it: the desktop icons' size, written through `WSMetadataStore` into the folder's `.agora` sidecar, so
it survives the process. The two are the application's own doors because the AppKit's
`-orderFrontStandardAboutPanel:` is a NAMED REFUSAL and there is no preferences panel at all.

**AND THE MENUS BESIDE IT ARE A SKELETON, DELIBERATELY.** Every File, Edit, View and Go row names the selector the
reference file manager's own row sends and has **no target yet** — so the enabling walk draws it greyed. That is the honest state of
a command whose feature is not written, and it is MEASURED rather than asserted: `workspace-main-menu` runs the walk
and checks the outcome, and the desktop suite reads the ink off the strip in two scenes — one where Workspace is the
active application and one where an ordinary window is in front of it, where its menus are correctly absent.

### The strip that needed a level of its own — now fixed, and measured

`window-server/src/output.c` drew its menu-bar strip **before** the windows and said so: *"until the strip has
a LEVEL of its own such a window covers it. The level is the next step."* A full-screen desktop window is
exactly such a window, so the strip *was* covered by the desktop. The strip now has `AWS_MENU_BAR_LEVEL` (24)
and is composited in the level walk, so the suite measures the fix instead: the bar is in the top rows, OVER the
desktop, and the desktop's first icon row begins a menu-bar's height plus ten points down.

## What is here (W0, W1 and W1b)

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
reloads on demand rather than from a stream callback); a folder double-click is a file window, which is W2; a
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
