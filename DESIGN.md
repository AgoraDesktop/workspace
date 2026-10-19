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
title, the `NSPathControl`, the status bar and `WSIconView` are four renderings of that one model. A navigation
replaces it once and every strip follows, which is the property `tests/file_window.m` measures. The window is not
a view: it is the shell the later views (W3–W5) will be swapped into.

**THE HISTORY IS ITS OWN OBJECT.** `WSHistory` is the stack, the cursor and the rule that a new navigation drops
what was forward; the controller asks it only whether Back and Forward are possible. That is what lets
`tests/history.m` measure the semantics without a window, and it is the same split the plan's §8 asks for.

**THE PLACES ARE DATA.** `WSPlaces` names the two sections this stage has — PLACES (Desktop, Home, Applications) and
DEVICES (Computer) — and owns the desktop-path rule (`AGORA_DESKTOP`, else `~/Desktop`) so the application, the
sidebar and a second window cannot disagree. The sidebar is an `NSOutlineView` in an `NSSplitView`, with the
source-list highlight.

**ALL THREE VIEWS ARE ENABLED.** The three-way switcher is the platform's `NSSegmentedControl` in a toolbar item.
W2's simple icon grid is W3's icon view now; W4 adds `WSListView`; W5 adds `WSColumnView`, an `NSBrowser` with the
preview panel. Each is a content view over the same per-directory model.

**THE CONTENT VIEW KEEPS COCOA'S y-UP DIRECTION.** The strips want a top-down layout, but this tier's live drawing
path enters a flipped ROOT view without mirroring it, so a flipped content view put its top strip at the bottom
(MEASURED in the first live run). The window therefore lays out path bar at the top edge, status bar at the bottom
and the split view between, in the ordinary coordinate system; the finding is recorded in `PROVENANCE.md`.

**A SECOND WINDOW IS A SECOND MODEL.** File > New Workspace Window is the application's action; the desktop's
folder double-click posts `WSDesktopViewOpenFolderNotification` and the application opens a controller at that
path. The window is the key window when it is front, and its `-nextResponder` is the controller — which is how the
View and Go menu rows (no target) reach the window that has a model.

## W3 — the icon view

**THE SHARED ENGINE HAS TWO ORDERS.** `WSIconLayout` already owned the cell size, the margins, the hit test and the
arrange arithmetic. W3 adds `WSIconOrderLeftToRightRows` for the file window and keeps
`WSIconOrderRightToLeftColumns` for the desktop; the view chooses the order, the engine stays the only copy of the
geometry. The file window's first cell is (16,16), the second (96,16), and the fifth wraps to (16,104) — measured in
`tests/icon_view.m`.

**THE ICON VIEW OWNS ITS SELECTION AND ITS KEYBOARD.** A click selects; Shift extends from an anchor; Command
toggles; Command-A selects all. The arrows move by one item or one row of the grid's columns, Home/End go to the
ends, and the selected icon wears a focus ring while the view is first responder. TYPE-SELECT accumulates a prefix
for one second and searches from the selection, wrapping; `d` then `do` is `delta.txt` then `Documents`, not two
restarts.

**RENAME IS A FIELD OVER THE LABEL.** Return opens an `NSTextField` where the label is, with the base name selected
and the extension left alone. Commit performs one `NSFileManager` move, reloads the model and selects the renamed
item; cancel, empty names, slashes, `.`/`..` and collisions are refused. The field ends through
`NSTextMovementCancel`/the field's action, so a click-away commits and Escape cancels.

**DRAG AND DROP IS THE TIER'S SESSION, NOT A PRIVATE LOOP.** The view is the source (paths on `NSDragPboard` as
`NSFilenamesPboardType`, one dragging item per icon) and every `WSIconView` is a destination. The destination is the
folder icon under the pointer or the window's own folder, and the policy is a function of the two volumes and the
modifiers: Move within a volume, Copy across, Option Copy, Command across Move, Command-Option Link. Every
destination is preflighted before anything moves, so a conflict refuses the whole drop instead of leaving a partial
one; a successful drop reloads both models. A real cross-window session is part of the probe.

**THE ALIAS IS THE ONE DEVIATION.** The Mac's alias is a bookmark record (`WORKSPACE-PLAN.md` §5.2), and `WSAlias`
is W6's. The Link operation therefore makes a symbolic link today; the header and `PROVENANCE.md` say so rather than
calling a symlink a Mac alias.

**SPRING-LOADING IS A NOTIFICATION.** A 0.6-second hover over a folder icon posts
`WSIconViewRequestFolderWindowNotification`; the application opens the folder's window, the same request the desktop
makes for a folder double-click. Moving the in-flight drag into that window is not implemented, and the icon view has
no rubber band; both are named in the README.

## W4 — the list view

**ONE MODEL PER DIRECTORY, AND CHILDREN ARE CHILD MODELS.** `WSListView` is an `NSOutlineView` whose root is the
window's `WSItemModel`; expanding a folder makes another `WSItemModel` for that path and caches it. Nothing was
added to the model's shape — no parent pointer, no recursive walk — so the "one model every view reads" rule still
means one model per directory.

**THE COLUMNS ARE THE ITEM'S FACTS.** Name, Date Modified, Size and Kind. The first two are the model's; the date
and size come from `NSFileManager` attributes, read once on first ask. Kind is Launch Services'
`LSCopyKindStringForURL`; a directory is "Folder", and an internal `dyn.…`/`public.…` answer is replaced by the
extension (or "Document") rather than shown to a person as if it were a kind.

**SORTING IS `WSItemSort`'S.** Directories first in BOTH directions, then natural name order (`file2` before
`file10`), date, size or Kind, with the natural name as the tie-break. The header's sort prototypes produce the
descriptors; the data source maps the first descriptor to the sort key and reloads. `setSortKey:ascending:` is the
same path for a caller that does not have a header click.

**EXPANSION IS REMEMBERED BY PATH.** `NSOutlineView`'s expanded set is by item identity; a reload makes new
`WSItem` objects. The view keeps the open paths, re-expands the matching new items after a reload (parents first),
and restores the selected paths. That is the difference between an outline that survives a model change and one
that collapses whenever the folder changes.

**RENAME IS THE TABLE'S FIELD EDITOR.** The Name column is editable; Return starts the session. The table ends an
edit through its own data-source door with a row, not the outline's item door, so `WSListView` implements both and
routes them to one `NSFileManager` move, a parent-model reload, the expansion restore and the new row's selection.

## W5 — the column view

**THE BROWSER IS `libagora-app`'S; THE COLUMNS ARE THE MODEL'S.** `WSColumnView` owns an `NSBrowser`; each column's
rows are a sorted `WSItemModel` — the root's for column zero, and a child model made on demand for a selected folder.
The browser's delegate fills the `NSBrowserCell`s and the selection loads the next column; a leaf returns zero rows
and opens nothing.

**THE PREVIEW IS A FIXED RIGHTMOST PANEL.** It shows the selected item's icon, name, Kind, size and modification
date. Selecting a folder previews it and loads its children; selecting a file previews the file. The panel stays
while the browser's columns scroll, which is the shape this stage calls the preview column; a Quick Look preview
inside the column is W9's.

**THE BROWSER IS TABLE-BACKED, WITH THE 10.6 DELEGATE SURFACE.** Apple's class is an `NSMatrix` of `NSBrowserCell`s;
this tree has no `NSMatrix`, so `NSBrowser` is one `NSScrollView` of side-by-side `NSTableView`s with
`numberOfRowsInColumn:`, `willDisplayCell:atRow:column:`, `selectedColumn`, `path`, column width and horizontal
scrolling. The old `createRowsForColumn:inMatrix:` form is absent and named in its header.

**A RELOAD REBUILDS THE COLUMNS FROM THE ROOT.** `-reloadData` clears child models and the column cache, reloads the
root and asks for column zero; the selection in the test is then made again, so a new child appears where it belongs.

## What W0 found that it did not set out to find

**The server's menu-bar strip needed a level of its own, and now has one.** `output.c` painted the strip before
the windows and said so — "until the strip has a LEVEL of its own such a window covers it. The level is the next
step" — which meant a full-screen window at *any* level, the desktop included, covered the bar. The strip is now
composited at `AWS_MENU_BAR_LEVEL` (24) in the level walk, and the suite measures what that fixed: the MENU BAR
is in the top rows, over the desktop, and the desktop's icons begin below it — padded by the bar's height plus
ten points, so the top row is not something other than what it looks like.
