# workspace

**Workspace is Agora's file manager and desktop** — the file manager's role: the windows that browse the filesystem
and the wallpaper-and-icons surface behind everything.

Agora is an installable desktop environment for Linux and the BSDs; see the project README in the parent
directory (`../README.md`). Workspace is an **application**: it consumes the AppKit as a built package
(`AgoraApp::App`) and installs no package of its own.

## Status

**W0, W1, W1b AND W2 ARE DONE.** The desktop (two levels), its icons, the application menu and the FILE WINDOW
shell all work. The window is assembled from the platform's parts — a toolbar, an `NSOutlineView` sidebar in an
`NSSplitView`, an `NSPathControl`, a status bar and an `NSSegmentedControl` — and every strip reads the SAME
`WSItemModel`. The Icon mode is W2's simple grid; W3 replaces it with the icon view proper, and List, Columns and
Cover Flow are W4's and W5's (their switcher segments are disabled).

**The desktop is TWO LEVELS: Workspace owns the ICON layer, not the wallpaper.** It
launches from its bundle, opens one borderless window at `kCGDesktopIconWindowLevel` — **TRANSPARENT** — and
draws only the items of a directory. The WALLPAPER is a separate window at `kCGDesktopWindowLevel`, and it is the
**Dock's** to draw.

```
$ .../Workspace.app/Contents/MacOS/Workspace --seconds 3 --file-window
workspace: file window for /home/kyle/Desktop
workspace: desktop window at level -2147483627, frame 1280x720 at (0,0)
```

Three arguments, all TEST DOORS and named as ones: `--seconds N` ends the ordinary run loop after N seconds (a
desktop is a thing that stays, and the suite needs it to be able to leave); `--show-about` opens the About panel as
part of starting up; and `--file-window` opens a file window on the desktop folder. The last two are otherwise
reached by menu actions, and a synthetic click reaches a compositor's motion path and not its button path on some
hosts.

`-2147483627` is `kCGDesktopIconWindowLevel` — one level above `kCGDesktopWindowLevel` (`-2147483628`, both from
`libagora-drawing`'s `CGWindowLevel.h`). The level is **below every ordinary window**, which is what makes this the
desktop rather than a window; the wallpaper is the window one level below it. The frame is
the whole screen, `[NSScreen frame]` and not `visibleFrame`, because the Dock and the menu bar are drawn
*over* the wallpaper.

### What is measured, not assumed

`ctest` runs **seven tests**. `workspace-desktop` is the pixel suite — `tests/run-desktop.sh` + `tests/check.py` —
against **Agora's own window server**, headless: it runs the **bundle's** executable (the bundle path is part of what
W0 proves), places a **normal** window over the desktop with the server's own test client, and reads the server's
screenshot. **9 checks, 0 fail**:

- the **wallpaper window** (at `kCGDesktopWindowLevel`) covers the screen, at its own level;
- **Workspace's icon window is TRANSPARENT** — the wallpaper shows through it wherever there is no icon;
- an **icon** is drawn where its sidecar says it goes;
- a **normal window created *after* the desktop is composited *over* it** — which can only be the level.

The other six are offscreen. `workspace-desktop-layout`, `workspace-metadata-store`, `workspace-main-menu`,
`workspace-go-menu` and — the shell's own — `workspace-history` (**15 checks**) and `workspace-file-window`
(**38 checks**). The last one is the W2 proof below.

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
reference file manager's own row sends and — except W2's **New Workspace Window**, which the application answers —
has **no target yet**, so the enabling walk draws it greyed. That is the honest state of
a command whose feature is not written, and it is MEASURED rather than asserted: `workspace-main-menu` runs the walk
and checks the outcome, and the desktop suite reads the ink off the strip in two scenes — one where Workspace is the
active application and one where an ordinary window is in front of it, where its menus are correctly absent.

### W2: the file window shell

**ONE FOLDER, ONE MODEL, FOUR STRIPS.** `WSFileWindowController` opens a folder, owns its `WSItemModel` and its
`WSHistory`, and gives the model to every part of the window: the title is the folder's name, the `NSPathControl` is
its URL, the status bar says the model's own count, and `WSFileIconView` draws the model's items. A navigation
replaces the model and tells all four; none of them has a directory of its own.

**THE CHROME IS THE PLATFORM'S.** The toolbar is an `NSToolbar` with Back, Forward and a custom `NSSegmentedControl`
view switcher. The sidebar is an `NSOutlineView` (source-list highlight) inside an `NSSplitView`, with two sections:
**PLACES** (Desktop, Home, Applications) and **DEVICES** (Computer), from `WSPlaces`. The path bar is an
`NSPathControl` in the Navigation Bar style; a component click navigates to that component's URL. The status bar is a
bordered-free `NSTextField` reading "N items".

**BACK AND FORWARD ARE `WSHistory`'S.** The stack, the cursor and the truncation rule are a separate object, and
`tests/history.m` measures them without a window: a new navigation drops everything that was forward, pushing the
current location is a no-op, and an arrow at the end of the stack does nothing. The controller only asks
`-canGoBack`/`-canGoForward` for the toolbar and the menu walk.

**ONLY ICON IS ENABLED.** The switcher has four segments because the Finder's does; List, Columns and Cover Flow are
the stages after this one, so their segments are disabled and their menu rows answer NO from
`-validateMenuItem:`. W2's Icon mode is a simple left-to-right grid (`WSFileIconView`) with selection and
double-click open; it is NOT W3's icon view — rename, keyboard navigation, type-select, drag and drop and
spring-loaded folders are W3's.

**A SECOND WINDOW IS A SECOND MODEL.** File > New Workspace Window creates another controller on the desktop
folder; a folder double-clicked on the desktop posts `WSDesktopViewOpenFolderNotification`, and `WSApplication`
opens it in a file window of its own. Each controller keeps its own folder, history and path bar, and closing one
removes it from the application's list without touching the desktop or the other windows.

**THE CONTENT VIEW IS NOT FLIPPED, AND THAT IS A MEASURED CHOICE.** The strips want a top-down layout, but this
tier's live drawing path enters the content view without mirroring a flipped ROOT, so a flipped content view placed
its top strip at the bottom. The window keeps Cocoa's y-up direction and the three strip frames do the arithmetic:
path bar at the top edge, status bar at the bottom, split view between. `tests/file_window.m` checks those frames
after a resize, and the finding is recorded in `PROVENANCE.md`.

`tests/file_window.m` is the proof: a temporary tree of folders, a file and a hidden file; the model's count and the
status bar's; the path bar's URL; the sidebar's two sections and four places; the switcher's four segments and their
enablement; the toolbar's items; Back disabled at the first location; a double-click that navigates and updates
every strip; Back/Forward and a new navigation's truncation; the resize's strip geometry; and a second controller
with its own model and history.

### The strip that needed a level of its own — now fixed, and measured

`window-server/src/output.c` drew its menu-bar strip **before** the windows and said so: *"until the strip has
a LEVEL of its own such a window covers it. The level is the next step."* A full-screen desktop window is
exactly such a window, so the strip *was* covered by the desktop. The strip now has `AWS_MENU_BAR_LEVEL` (24)
and is composited in the level walk, so the suite measures the fix instead: the bar is in the top rows, OVER the
desktop, and the desktop's first icon row begins a menu-bar's height plus ten points down.

## What is here (W0–W2)

```
src/
  main.m                   the entry point: NSApplication, the controller, the loop
  WSApplication.m          the controller that owns the desktop and the file windows
  WSDesktopWindow.m        the borderless window at kCGDesktopIconWindowLevel, the size of the screen
  WSDesktopView.m          the desktop's icons — selection, rubber band, drag, double-click open
  WSFileWindowController.m the file window: toolbar, sidebar, path bar, status bar and view switcher
  WSFileIconView.m         W2's icon grid over one model (W3 replaces it)
  WSHistory.m              Back/Forward: the stack, the cursor and the truncation
  WSIconLayout.m           the grid, the snap, the arrange order and the hit test — pure geometry
  WSItemIcons.m            Icon Services' CGImage as an NSImage
  WSItemModel.m            one directory's items, the one model every view reads
  WSMetadataStore.m        the per-folder `.agora` sidecar: icon positions and the icon size
  WSPlaces.m               the sidebar's PLACES and DEVICES, and the desktop path
Info.plist.in              the bundle's Info.plist
tests/                     the pixel suite (run-desktop.sh + check.py) and six offscreen suites
```

## What is deliberately not here yet

The plan's later stages: the icon view proper and drag/drop within it (W3), the list and column views (W4/W5),
file operations and the Trash (W6), the system-wide drag session (W7), Get Info (W8), Quick Look (W9), search
(W10), volumes (W11), network shares (W12) and the shell integration (W13). Their substrate — Launch Services, Icon
Services and the change stream — is already built (`../libagora-launchservices`, `../libagora-iconservices`,
`../libagora-watch`).

**What W2 does not do yet, named:** the Icon mode is the shell's simple grid, without inline rename, keyboard
navigation, type-select, drag and drop or spring-loaded folders (W3); List, Columns and Cover Flow are disabled
(W4/W5); the desktop is still not LIVE (`libagora-watch` is built, but `WSItemModel` reloads on demand rather than
from a stream callback); a document's icon is its TYPE's generic and not its own content
(`AGIconCreateWithURL` already prefers an application's declared icon); and the sidecar holds the icon size and the
positions, not yet grid spacing or label placement.

## Build and run

```sh
cmake -S . -B build -DCMAKE_C_COMPILER=/usr/bin/clang-19 -DCMAKE_OBJC_COMPILER=/usr/bin/clang-19 \
      -DCMAKE_PREFIX_PATH=../build-prefix -DCMAKE_INSTALL_PREFIX=../build-prefix
cmake --build build
cd build && ctest --output-on-failure
```

The AppKit must be built and **installed** into the prefix first (`cmake --install ../libagora-app/build`);
W0 is the first component to consume it as a package, and doing so is what turned AppKit's previously-unrun
install rules on.

## Licence

MIT — see [`LICENSE`](LICENSE).
