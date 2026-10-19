# Design — W0

**This is the smallest honest Workspace and the shape the rest is added to.** W0 is the desktop window; the
file windows, the views and the file operations are later stages that hang off the same objects.

## Three objects

- **`WSApplication` is a CONTROLLER, not an `NSApplication` subclass.** This tree's
  `+[NSApplication sharedApplication]` allocates an `NSApplication` itself, so a subclass would never be the
  application object. `WSApplication` owns what is the application's — the desktop — and drives the
  `NSApplication` the entry point makes. On the Mac the system file manager is likewise an application that owns a desktop,
  not a subclass of the application object.
- **`WSDesktopWindow` is the desktop.** Borderless, `kCGDesktopWindowLevel`, the size of `[NSScreen frame]`,
  never key and never main. **The level is what makes it the desktop**: everything else is above it, so the
  compositor draws it first and the Dock and the menu bar sit on top.
- **`WSDesktopView` draws the wallpaper**, and nothing else yet. Desktop icons are the first thing added to it
  (W1), and the reason it is a view of its own rather than a colour on the window.

## The decisions W0 makes

- **The desktop is TWO LEVELS, and Workspace draws only the icons.** The wallpaper is a lower window at
  `kCGDesktopWindowLevel` — the **Dock's** to draw, eventually — and Workspace's window is **TRANSPARENT** at
  `kCGDesktopIconWindowLevel`, drawing only the items of the desktop directory; the compositor blends it over
  the wallpaper. (W0 drew the wallpaper itself; the level split moved it out, so the desktop is a *shell*
  surface rather than a file manager's private background.)
- **`[NSScreen frame]`, not `visibleFrame`.** The desktop is what the Dock and the menu bar are drawn over, so
  sizing it to the work area would leave the wallpaper missing under their translucent parts.
- **The bundle is a deliverable, not a packaging detail.** A program with an `Info.plist` beside it *is* a
  bundle, which is what the launch path and `libagora-launchservices` read, so the build lays out
  `Workspace.app/Contents/` rather than leaving a bare executable.

## W1 — the desktop's icons

Three objects, and the file **window's** views will be built from the same three:

- **`WSItemModel`** — one directory's items, and the one model every view reads.
- **`WSIconLayout`** — pure geometry: a **top-to-bottom, RIGHT-TO-LEFT** grid (macOS's own desktop order), the
  nearest-free snap a drop lands on, an arrange
  order, and a hit test. It needs no view, which is why it is checked offscreen.
- **`WSMetadataStore`** — the per-folder `.agora` sidecar: icon positions and the icon size.

**Three decisions.** Positions are **TOP-LEFT SCREEN COORDINATES** — the reference file manager's own convention, and what the
store persists — so the view converts to Cocoa only to draw and to hit-test; the sidecar is **XML**, because
that is what this tree's `NSPropertyListSerialization` writes; and the grid's **ORIGIN IS THE TOP OF ITS AREA**,
not an inset it adds. The desktop hands it a rectangle already padded by **the menu bar's height plus ten
points** (`+[WSDesktopView topPadding]`, read from `NSStatusBar -thickness` rather than a constant), so the first
row clears the bar by ten and the CALLER — not the grid — says where the icons may begin.

**And one gap named rather than implied:** the desktop is not LIVE yet. `libagora-watch` (F3) is built, but the
model reloads on demand instead of from a stream callback — that wiring is the step after this surface.

## W1b — the application menu

**THE APPKIT OWNS THE MECHANISM AND WORKSPACE OWNS THE CONTENTS, AND THE SPLIT IS THE WHOLE DESIGN.**
`-[NSApplication setMainMenu:]` takes a menu, INSERTS the application's own menu at its front — titled with
`-[NSProcessInfo processName]`, because that rule is the HIG's and not each application's — moves Help to the back,
and builds the borderless window at `NSMainMenuWindowLevel` (24) whose `NSMenuView` draws the titles and opens one on
a click. What it cannot know is which menus a Mac file manager has; that is `src/WSMainMenu.m`, and it is the only
thing this stage added to the menu bar.

**FOUR DECISIONS, AND EACH IS A ROW THIS FILE DOES NOT BUILD.**

- **The application menu is FILLED AFTER THE INSTALL, not before it.** The submenu to fill does not exist until
  `-setMainMenu:` has made it; building it here would mean naming the application twice, and a bar reading
  the reference file manager's name above `Quit Workspace` is what two names for one thing looks like.
- **About and Preferences are the application's own doors.** `-[NSApplication orderFrontStandardAboutPanel:]` is a
  NAMED REFUSAL in this tree, and there is no preferences panel at all — so those two rows target `WSApplication`,
  which puts up `WSAboutPanel` (the icon, the name, the version and the identifier, every string read out of
  `Contents/Info.plist` through `NSBundle`) and `WSPreferencesWindow`.
- **Preferences changes a preference that EXISTS.** Workspace has exactly two settings: which directory is the
  desktop, and how big its icons are. The window shows both and lets a person change the second — the slider writes
  through `WSMetadataStore` and SAVES, so the size in the sidecar is the size the next launch lays out with. A
  window of controls wired to nothing would be worse than no window.
- **A ROW WITH NO TARGET IS A DISABLED ROW, AND THAT IS THE DESIGN.** `-[NSMenu update]` enables an item when its
  target answers its action, so every File/View/Go row — which names the reference file manager's own selector and has
  no implementer yet — is drawn GREY. W2's **New Workspace Window** is the first exception: the application answers
  it, so the walk enables that one row and the rest stay grey. That is how a Mac application shows a command it cannot offer right now, and how
  this bar says what Workspace can actually do instead of being a picture of the reference file manager. W2 gives New Workspace
  Window its target; each later stage lights its own rows the same way.

**AND ONLY THE ACTIVE APPLICATION'S MENUS SHOW.** The bar window is ordered front by the AppKit's activation, which
is the compositor's keyboard-focus decision — so a scene with an ordinary window in front of the desktop is a scene
where Workspace's menus are correctly absent. The suite measures both: the bar present when Workspace is the active
application, and the strip to the right of it still the server's own.

**AND THE LOOP IS THE APPKIT'S NOW, WHICH THE MENU BAR REQUIRED RATHER THAN MERELY ALLOWED.** `NSMenuView -mouseDown:`
begins a tracking session and fetches each next event only while `-[NSApplication isRunning]` — so an application
that pumps its own events gets a menu that is begun and never driven: it cannot be picked, dismissed or moved. W0's
hand-rolled pump was always standing in for the ordinary loop and the plan said so; `-runForSeconds:` now calls
`-[NSApplication run]`, and the suite's `--seconds` deadline rides the loop's per-pass `-applicationDidUpdate:`
notification, which is what Apple gives that pair for. The desktop's events, its window updates and its frame
pacing are the AppKit's from here on.

**Two findings about the AppKit are recorded in `PROVENANCE.md` rather than worked around here:** this tier's
`NSMenuItem` leaves a key equivalent's mask at zero where Apple's sets Command, so every row names its own mask; and
the Edit menu's five chain-routed rows come out enabled because the base `NSResponder` implements them as forwarders.

## W2 — the file window shell

**ONE MODEL, FOUR STRIPS.** `WSFileWindowController` owns the folder's `WSItemModel` and its `WSHistory`; the
title, the `NSPathControl`, the status bar and `WSFileIconView` are four renderings of that one model. A navigation
replaces it once and every strip follows, which is the property `tests/file_window.m` measures. The window is not
a view: it is the shell the later views (W3–W5) will be swapped into.

**THE HISTORY IS ITS OWN OBJECT.** `WSHistory` is the stack, the cursor and the rule that a new navigation drops
what was forward; the controller asks it only whether Back and Forward are possible. That is what lets
`tests/history.m` measure the semantics without a window, and it is the same split the plan's §8 asks for.

**THE PLACES ARE DATA.** `WSPlaces` names the two sections this stage has — PLACES (Desktop, Home, Applications) and
DEVICES (Computer) — and owns the desktop-path rule (`AGORA_DESKTOP`, else `~/Desktop`) so the application, the
sidebar and a second window cannot disagree. The sidebar is an `NSOutlineView` in an `NSSplitView`, with the
source-list highlight.

**ONLY ICON IS ENABLED, AND THE OTHER THREE SEGMENTS ARE DISABLED.** The four-way switcher is the platform's
`NSSegmentedControl` in a toolbar item; List, Columns and Cover Flow belong to W4 and W5, so their segments and
their menu rows answer NO rather than showing an empty mode. W2's Icon mode is a simple left-to-right grid; W3
replaces it with the icon view (rename, keyboard, type-select, drag/drop, spring-loading).

**THE CONTENT VIEW KEEPS COCOA'S y-UP DIRECTION.** The strips want a top-down layout, but this tier's live drawing
path enters a flipped ROOT view without mirroring it, so a flipped content view put its top strip at the bottom
(MEASURED in the first live run). The window therefore lays out path bar at the top edge, status bar at the bottom
and the split view between, in the ordinary coordinate system; the finding is recorded in `PROVENANCE.md`.

**A SECOND WINDOW IS A SECOND MODEL.** File > New Workspace Window is the application's action; the desktop's
folder double-click posts `WSDesktopViewOpenFolderNotification` and the application opens a controller at that
path. The window is the key window when it is front, and its `-nextResponder` is the controller — which is how the
View and Go menu rows (no target) reach the window that has a model.

## What W0 found that it did not set out to find

**The server's menu-bar strip needed a level of its own, and now has one.** `output.c` painted the strip before
the windows and said so — "until the strip has a LEVEL of its own such a window covers it. The level is the next
step" — which meant a full-screen window at *any* level, the desktop included, covered the bar. The strip is now
composited at `AWS_MENU_BAR_LEVEL` (24) in the level walk, and the suite measures what that fixed: the MENU BAR
is in the top rows, over the desktop, and the desktop's icons begin below it — padded by the bar's height plus
ten points, so the top row is not something other than what it looks like.
