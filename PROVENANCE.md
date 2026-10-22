# Provenance

**First-party: written for Agora, not extracted from anywhere.** No upstream revision to pin and no
third-party code to licence.

| what | where |
|---|---|
| the AppKit | consumed as the built package `AgoraApp::App` (`../libagora-app`), which brings Foundation, Core Graphics, Core Text and the Objective-C runtime on its interface |
| the window levels | `libagora-drawing`'s `CGWindowLevel.h` (`kCGDesktopWindowLevel`) |
| the wallpaper's endpoints | `window-server/ARGENTUM.md`'s own samples — `(108,55,29)` and `(18,14,5)` |
| the compositor it is a client of | `../window-server`, as `agora_shell` through the AppKit's seam |
| the icon art | **Frost v0.3.1** (MIT), vendored in `../libagora-iconservices/themes/Frost` and reached through Icon Services |
| third-party code | **none** |
| licence | MIT, per file (`LICENSE`) |

## What was decided

**The wallpaper is an application's, not the server's.** `ARGENTUM.md` records the server filling `#A8DED9`
"by request" and calls a vertical ramp "the honest next step". W0 takes that step in the place it belongs: the
desktop is a client, as the system file manager is on the Mac, so the ramp is a view in an application.

**`WSApplication` is a controller rather than an `NSApplication` subclass**, because this tree's
`+[NSApplication sharedApplication]` allocates an `NSApplication` and not the receiver's class. The header says
so at the class.

**The one piece of the AppKit never exercised until now.** `libagora-app` had install rules but had never been
`cmake --install`ed — W0 is the first component to consume the AppKit as a *package* rather than as an in-tree
target, and doing so is what turned those rules on. On this machine the install needed
`-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON`, because the install-time relink wanted a `CMakeFiles/CMakeRelink.dir`
copy it did not produce; that is a fact about this build tree and is recorded rather than hidden.

## W1

**The sidecar is XML, and that was MEASURED rather than chosen.** The plan said "binary plist"; this tree's
`NSPropertyListSerialization` writes XML and REFUSES the binary format — measured, as a `save` that returned NO —
so `.agora` is a text property list, which also diffs, which a binary one would not.

**Icon positions are TOP-LEFT SCREEN COORDINATES**, the reference file manager's own convention and what the store persists;
Cocoa's bottom-left appears only in the view's drawing and hit-testing, converted in one place.

**An icon is an `IconRef` from `libagora-iconservices` (F2), cached per item.** `AGIconCreateWithURL` already
prefers an application bundle's declared icon and falls back to the type's generic; a document's own icon is a
later step. **The art is Frost**: `libagora-iconservices` vendors the MIT theme and the demo points
`AGORA_ICON_THEME` at the checkout's `themes/Frost`, so the desktop's folders and file types are Frost's even
before the library is installed. And the desktop is **not LIVE yet**: `libagora-watch` (F3) is built, and
wiring its stream to `WSItemModel` is the step after this surface.

**And the labels are centred GEOMETRICALLY, because the text system does not honour ALIGNMENT.** MEASURED, the
hard way: `-drawInRect:withAttributes:` never mentions alignment in `libagora-app/NSStringDrawing.m`, so a
paragraph style's `NSCenterTextAlignment` left the text exactly where it was. The view now measures the string
with `-sizeWithAttributes:` and hands `-drawInRect:` a rectangle of exactly that width, centred on the icon.

**AND AN ICON IS UP-RIGHT IN BOTH OF WORKSPACE'S COORDINATE SYSTEMS.** The Desktop draws y-up and the file
window's flipped `WSIconView` draws y-down; `NSImageRep -drawInRect:` used to hand the same rect to
`CGContextDrawImage` in both, so Frost's folder icons were upright in one and upside-down in the other.
MEASURED with the vendored theme; fixed in the AppKit with the y-up mirror, and `libagora-app/tests/image_draw.m`
is the regression. See `../libagora-app/PROVENANCE.md` §24.

## The desktop is two levels

**The desktop is TWO LEVELS, and this is the change that made the icon window TRANSPARENT.**
`kCGDesktopWindowLevel` is the WALLPAPER — a window of its own, the Dock's to draw — and
`kCGDesktopIconWindowLevel` is the icons, which are Workspace's. Making a window transparent needed the AppKit to
carry an ALPHA channel it did not have: `AGWindowSetTransparent` in the seam (ARGB8888 buffers, which the
compositor already BLENDED source-over) and `NSWindow`'s backing store switching to
`kCGImageAlphaPremultipliedFirst` when `-setOpaque:NO`. See `../libagora-app/PROVENANCE.md`.

## The desktop's top padding — the icon grid's origin is its AREA, not an inset

**MEASURED BUG:** the first row of icons was placed at the grid's `WSIconGridMargin` (16 pt) from the view's top
edge — which is *under* the menu bar, whose strip is 24 pt tall. Icons belong below it.

**FIX:** `WSIconLayout` no longer adds a top inset; the **bounds' ORIGIN is the top of the area it fills**, and
the caller says where that is. `WSDesktopView` hands it `-layoutBounds` — the view less
`+[WSDesktopView topPadding]` — and the padding is **the menu bar's height plus ten points**, read from
`NSStatusBar -thickness` rather than hard-coded, so it follows the bar. MEASURED after the change: the first
icon's BOX begins at y = 34 (24 + 10) and its page glyph's ink at y = 42, the art carrying its own 8 pt inset.
`tests/desktop_layout.m` now checks the first cell sits at the AREA'S origin, not at a margin.

## The application menu — four findings, three of them the AppKit's

W1's menu bar is Workspace's own code in `src/WSMainMenu.m`, and it is assembled from doors the AppKit already
had. What it MEASURED on the way is below; the ones that are the AppKit's are recorded here because that is where
the fix belongs, and named so the next reader does not re-derive them.

**1. THE KEY EQUIVALENT'S MASK IS ZERO BY DEFAULT, WHERE APPLE'S IS COMMAND.**
`-[NSMenuItem initWithTitle:action:keyEquivalent:]` sets the title, the action and the key string and leaves
`_keyEquivalentModifierMask` at ZERO — Apple's sets `NSCommandKeyMask`. MEASURED in `NSMenu -performKeyEquivalent:`,
which compares `[item keyEquivalentModifierMask] & mask` against the event's: with the mask at zero **Command-Q does
not match and a bare `q` does**, so every item a portable application builds with the convenience factory answers
the wrong keystroke. `WSMainMenu` therefore names `NSCommandKeyMask` on every row (`WSRow` in its implementation),
and `workspace-main-menu` asserts it — "and its shortcut is COMMAND-Q, not a bare q". The AppKit fix is to the item's
default and not to a caller, which is why it is recorded rather than worked around silently.

**2. THE BAR'S WINDOW WAS A RACE, AND IS FIXED IN THE APPKIT.** `-setMainMenu:` can run before the compositor has
sent the menu-bar region, and then it builds nothing; `-run` re-measured, but a loop of the application's own never
goes through `-run`. Fixed at `-nextEventMatchingMask:` — see `../libagora-app/PROVENANCE.md` § 7. Before the fix
Workspace showed a menu bar in some runs and not in others.

**3. THE EDIT MENU'S FIVE CHAIN-ROUTED ROWS COME OUT ENABLED, AND NOTHING HERE ANSWERS THEM.** This tier's
`NSResponder` implements `-cut:`, `-copy:`, `-paste:`, `-delete:` and `-selectAll:` in the BASE as forwarders to the
next responder, where Apple leaves a plain view answering none of them — so the enabling walk's
`-targetForAction:` finds an answer at every responder and leaves the row live. Apple's own Copy is disabled with no
text view focused. The menu is right (a system file manager's Edit menu is chain-routed) and the CHAIN is over-permissive; the
fix belongs to `-targetForAction:` or to the base. `workspace-main-menu` PINS the measured outcome so that the day
it changes, the change is visible.

**4. THE APPLICATION MENU WAS OPENED AND THEN LOST — DIAGNOSED, AND FIXED IN TWO COMPONENTS.** Clicking the bar's
first title DOES open it: MEASURED, a window at **level 101** (a popup menu's), 180x246 at (36, 450), visible. It
then went away at once, and the AppKit's own diagnostic said why in two steps:

- **This application never entered `-[NSApplication run]`.** W0 pumped its own events, which was enough for a
  desktop that only had to stay on the screen — but `NSMenuView`'s bar loop fetches each next event only while
  `-[NSApplication isRunning]`, so the session was BEGUN and never driven. MEASURED: `APPKIT_MENU_DIAG` printed
  `the menu is on screen now` and then not one line of the loop that would have handled the click. W0's pump was
  always standing in for the ordinary loop and the plan said so; `-runForSeconds:` now uses the real one, with the
  suite's deadline riding the loop's per-pass `-applicationDidUpdate:` notification.
- **And a RELEASE ended the session.** With the loop running, the trace showed the session ending on a `type 2`
  three times running: the rule was written for a menu that owns its own loop, and a bar's loop drains every
  window's queue instead. Fixed in the AppKit — see `../libagora-app/PROVENANCE.md` § 8.

The nested-X11 probe used to demonstrate this by hand is unreliable for its own reasons (a compositor gives the
pointer a focus on a MOTION, and a probe that teleports to its target races that enter), so what verifies the fix is
the AppKit's menu suites — `appkit-menu-headless`, `appkit-menu-activation` and `appkit-popup-menu` all pass — plus
the trace above, rather than a photograph.

## The menu bar's clock — a status item, and what it measured

**`WSMenuBarClock` is the first thing in this tree that drives `NSStatusBar`/`NSStatusItem` end to end from an
application**, and the reason to build it was the door rather than the time: a status item is the one piece of an
application that has a LENGTH and NO POSITION, so the strip is packed by the server and drawn by the client, and that
arrangement had only ever been exercised by `libagora-app`'s probe — which makes an item and puts a coloured mark in
it, where no measurement said the mark reached the glass. A clock is the smallest thing that is both useful and a
real user of the door: a view, a width that CHANGES, and a value that has to be refreshed while nothing happens.

**WHAT THE DESKTOP SUITE NOW MEASURES**, in the scene where Workspace is the active application: the time's ink in
the strip's right end, its last inked column within twenty points of the screen's edge (so the SERVER packed it and
the application did not place it), a gap of the bar's own face between the menus and the clock, and the bar's face
again in the item's last two columns (so the item is a piece of the bar rather than a box on it). MEASURED on a
1280-point output: the item is 62 points wide at x = 1218..1279 with `7:13 a.m.` inked at 1223..1272. In the OTHER
scene — an ordinary window in front, Workspace not active — the clock is STILL there while the menus are not, which
is the difference between a status item and a window and is asserted rather than assumed.

**1. `-setContentView:` RESIZES THE VIEW, SO THE WIDTH HAS TO BE MEASURED AFTER THE VIEW IS INSTALLED.**
`NSVariableStatusItemLength` is resolved by asking the view how wide it is, which is why the view is measured and
resized BEFORE the item is made — and that measurement is then thrown away: `-[NSWindow setContentView:]` lays the
content view out at the window's own content rectangle, which for an item made with no view yet is the SQUARE the
sentinel fell back to. MEASURED, in that order: the item came out 24 points wide — the bar's thickness — with the
time drawn straight through the right edge of the screen, which reads like the server packing an item wrongly and was
this ordering. The door that states the width (`-cg_resizeToWidth:`) is therefore called again after `-setView:`, and
it moves three things together: the view (what a later sentinel resolution measures), the item's WINDOW (it owns the
backing store the compositor blits, and a window narrower than its item clips the new digit) and then the server
(`-setLength:`).

**2. `NSTimer` IS INERT UNDER `-[NSApplication run]`, SO THE CLOCK RIDES THE LOOP'S OWN PASSES.** The loop blocks on
the compositor's connection (`-nextEventMatchingMask:` → `AGWindowWaitForEvent`) and never enters `NSRunLoop`, so a
scheduled timer is valid, scheduled and never fired — a clock written the ordinary Cocoa way would have kept showing
the minute it started in. What the loop does do is announce `NSApplicationDidUpdateNotification` once per frame, which
is the AppKit's own "a place to change what is shown between passes", so the clock reads the time once per pass and
formats a string only when the minute moved. MEASURED over a 75-second run: the item read `7:13 a.m.` at the start
and `7:16 a.m.` in the screenshot written at the end, across 4196 loop passes. **The AppKit gap is recorded here
rather than fixed there**: an application that wants a timer, a `-performSelector:withObject:afterDelay:` or a
run-loop source of any kind has no clock in this tier, and the fix belongs to the loop.

**3. THE CLOCK IS THE APPLICATION'S, AND IT IS NOT A WINDOW.** Every other surface Workspace owns appears and
disappears with the application's activation — the menu bar's titles are ordered in and out by
`-activate`/`-deactivate`. The clock does not: it is `NSStatusItem`'s own window at `NSStatusWindowLevel`, ordered
front when its view is set, and the compositor places it for as long as the process is alive. That is the right
answer for a clock (a clock that came and went with the front window would be a window) and it is a DIVERGENCE from
the reference system, whose clock belongs to the window server and is therefore there when no application is.

**4. NO MENU, BECAUSE THE DOOR IS A NAMED REFUSAL.** `-[NSStatusItem popUpStatusItemMenu:]` needs the menu tracking
session that `NSMenu -popUpContextMenu:` also needs and that this tier does not have, so clicking the clock does
nothing at all — which is stated in the header rather than papered over with a menu that could not be tracked.

## W2 — the file window, and a drawing finding

**`WSFileWindowController`, `WSIconView`, `WSListView`, `WSColumnView`, `WSFileOperations`, `WSTrash`,
`WSProgressWindow`, `WSConflictSheet`, `WSItemSort`, `WSItemKind`, `WSHistory`, `WSItemIcons` and `WSPlaces` are
this repository's own
code.** The window is assembled from the AppKit's classes — `NSToolbar`/`NSToolbarItem`, `NSSplitView`, `NSOutlineView`,
`NSPathControl`, `NSSegmentedControl`, `NSTextField` and `NSWindowController` — and the model/history/places are
separate so each can be measured without the others. **The sidebar is resizable, and its divider is a GUTTER:** the
split view uses `NSSplitViewDividerStylePaneSplitter`, the same eighteen-point, three-ring grip the browser's columns
use. The sidebar's rows fit, so its vertical bar is autohidden too (`NSScrollView -autohidesScrollers`), and the
content pane's bar follows the same rule: a grid whose rows fit wears no bar, which `tests/file_window.m` checks.
Every scroll view the shell creates is set to autohide.
**A VIEW SWAP RESETS THE CONTENT CLIP'S ORIGIN:** the clip view keeps its bounds origin when its document is replaced,
so a scrolled icon grid would have handed that offset to the column browser and drawn the browser as if it were
scrolled to the same place. `WSFileWindowController`'s swap resets it to (0, 0) after setting the new document;
`tests/file_window.m` scrolls the grid before Column -> Icon -> Column and checks the browser is back at column zero.

**THE FINDING: A FLIPPED ROOT CONTENT VIEW IS PLACED AS IF IT WERE UNFLIPPED IN THE LIVE DRAWING PATH.**
`NSWindow -cg_drawContentInContext:` calls `[_contentView displayRect:]` directly, while the offscreen walk
(`fn_draw_view`) is the one that enters a root view's own coordinate system and mirrors a flipped one. MEASURED:
the first live screenshot put the path bar at the bottom and the status bar at the top; the frames were correct
for a flipped view, the DRAW was not. The window keeps an unflipped content view and lays the three strips out in
Cocoa's y-up space. This is an AppKit-side defect for the next time the view tree is touched; it is recorded here
rather than fixed by making the shell's layout depend on an accident.

**AND THE CONTENT VIEW'S STRIPS ARE CONSTRAINTS, BECAUSE THE RESIZE HOOK NEVER RAN.** The first shell laid the path
bar (24 points), the status bar (22) and the split view between them in `-resizeSubviewsWithOldSize:` — and this
tier's `NSView -setFrame:` does NOT call that hook, while a window resize sets the content view's FRAME. The strips
kept the geometry they were born with. They are Auto Layout constraints now: the path bar is pinned to the content's
top with its height, the status bar to the bottom with its, and the split view fills the band and the width. The
split view's delegate answers `-splitView:shouldAdjustSizeOfSubview:` with YES only for the content pane, so the
sidebar keeps its width and the content absorbs the resize; `-splitViewDidResizeSubviews:` then refreshes the
document view inside the scroll view. `tests/file_window.m` resizes the window to 700×400 and then 1000×500, checks
every strip and both panes, and follows the icon view into its new clip width.

**AND THE ENGINE NEEDED A FIX TO MAKE THAT TRUE.** A control's intrinsic size contributes optional hugging and
compression constraints, and a leading/trailing pair shares the control's x and width. One required projection per
sweep left a control pinned to both edges of a 700-point parent at x=76 with an intrinsic width of 10: the trailing
projection moved the x the leading one had just set, and the optional pull was never fully overridden. The solver
now projects the required rows to convergence inside each sweep and measures convergence by the NET move across the
sweep; `tests/auto_layout.m` case 16 is the regression. The outer break is in points (1e-5), which is what stopped an
ordinary file window from spending its whole 400-sweep budget on a fraction of a point.

## W3 — the icon view, the drag session and the alias gap

**`WSIconView` IS THIS REPOSITORY'S OWN CODE**, built over the AppKit's `NSDraggingSession`, `NSTextField` and the
`WSItemModel`/`WSIconLayout` pair. Four decisions are worth recording here because they are not visible from the
class list:

- **THE ORDER IS AN ENGINE PARAMETER, NOT A SECOND ENGINE.** `WSIconLayout` gained
  `WSIconOrderLeftToRightRows`; the desktop keeps right-to-left columns and the file window reads rows. The cell
  size, margin, hit test and arrange arithmetic stayed in one place, which is what "the shared engine is shared"
  means in the test.
- **THE RENAME IS ONE MOVE, NOT A COPY.** `-commitRenaming` validates the name (empty, `/`, `.`/`..`, existing
  destination) and calls `NSFileManager -moveItemAtPath:toPath:error:`, then reloads the model and selects the new
  name. The extension is left unselected when the rename begins; a directory's whole name is selected.
- **THE DRAG IS THE TIER'S SESSION.** The view puts selected paths on `NSDragPboard` as `NSFilenamesPboardType`,
  starts a session with one item per icon, and is a registered destination for the same type. The operation is
  `Move` within a volume, `Copy` across, `Option` Copy, `Command` across Move and `Command-Option` Link; the
  destination is a folder icon or the window's folder; all destinations are preflighted before anything moves.
- **THE LABEL IS CUT TO ITS CELL, IN THE MIDDLE.** The first version measured the name and centred that width on
  the icon, so a long directory name was wider than its cell and its two halves landed in the neighbouring cells.
  `WSIconLabelText` (`WSIconLabel.h`) binary-searches the longest head/tail pair that fits `cellWidth - 4`, keeping
  an ellipsis; `WSIconView` and `WSDesktopView` then clip the drawing to the cell. `tests/icon_view.m` pins a short
  name unchanged, a long name shortened with an ellipsis, and the truncated width inside the cell.
- **A LINK IS A SYMBOLIC LINK UNTIL `WSAlias`.** The plan's alias is a bookmark record and that class is W6's, so
  the Link operation is `symlink(2)` today. This is stated in `WSIconView.h`, `DESIGN.md` and the README rather than
  presenting a symlink as a Mac alias.

**SPRING-LOADING ASKS, AND THE APPLICATION OPENS.** A 0.6-second hover posts
`WSIconViewRequestFolderWindowNotification`; `WSApplication` observes it and opens a file window at the folder — the
same path a desktop folder double-click uses. The view never makes a window, and the in-flight drag is not yet
transferred into the spring-loaded one.

`tests/icon_view.m` measures the order and document height, every keyboard movement, Shift/Command selection, the
prefix type-select, a successful rename, a cancel and three refusals, the source pasteboard and a live session, the
five drop-policy answers, Move/Copy/Link on `/tmp` and `/dev/shm`, a refused conflict, a drop on a folder icon, the
spring notification, and a real drag from one window's icon view into another's.

## W4 — the list view, and the field editor's door

**`WSListView`, `WSItemSort` AND `WSItemKind` ARE THIS REPOSITORY'S OWN CODE.** `WSListView` is an `NSOutlineView`
whose tree is made of per-directory `WSItemModel`s; `WSItemSort` owns the directories-first/natural-name rules; and
`WSItemKind` owns the Launch Services answer and its readable fallback. `WSItem` gained lazy modification-date and
size accessors — read once from `NSFileManager` attributes rather than at every listing.

**THE KIND FALLBACK HIDES AN INTERNAL NAME.** `LSCopyKindStringForURL` answers a human description for a declared
type ("Plain Text"), but for an extension no Agora bundle declares it can answer the dynamic `dyn.…` UTI. That is
not a Kind a person should see, so a UTI-shaped answer (a dot and no space) falls back to the extension — "MD" for
`todo.md` — or "Document". The live W4 scene is where the `dyn.15r7hj1` answer was found.

**THE FINDING: AN OUTLINE'S FIELD EDITOR ENDS THROUGH THE TABLE'S DATA-SOURCE DOOR.**
`NSTableView -textDidEndEditing:` writes an edited cell through
`-tableView:setObjectValue:forTableColumn:row:`. `NSOutlineView` does not translate that to its own
`-outlineView:setObjectValue:forTableColumn:byItem:`, so a cell-based outline's edit reached a data source that
implements Apple's outline method and did nothing. `WSListView` implements BOTH doors (the table one maps row to
item and calls the same rename), and the gap is recorded here as an AppKit-side one rather than hidden in the
view. The probe drives the field editor, so this is measured.

**EXPANSION AND SELECTION ARE PATH-BASED.** A reload clears the child models and the sort cache, re-expands the
remembered paths (sorted by depth, parents first) against the new item objects, and restores selected paths. The
expanded set is not persisted to disk; that is W5's outline autosave, if it is wanted.

`tests/list_view.m` measures the name, size, date and Kind orders over a deliberately dated and sized tree; the
four column values; a folder open across a reload with its child visible; a rename through the field editor; the
Return/Right/Left/Command-Down keys; a 16-point icon on the Name cell and none on the other columns; and an
undeclared `.md` file's kind not being a `dyn.…` UTI. Still absent: list drag/drop.

**THE NAME CELL'S ICON IS A CELL-CLASS DECISION, AND `--list-view` HAD A SETTER BUG.** `WSListNameCell` draws its
`NSImage` through `-drawingRectForBounds:` so the field editor inherits the same inset, and `WSListView` fills it
through `willDisplayCell` rather than making the data source return a compound value. The flag that opens the scene
was a second finding: both `WSApplication` mode setters assigned the mode unconditionally, so the fixed list-then-column
call order reset `--list-view` to 0; a false flag now leaves the other mode standing. MEASURED in the demo's
`--list-view` window.

## W5 — the column view, and the browser it stands on

**`WSColumnView` IS THIS REPOSITORY'S OWN CODE; `NSBrowser` IS `libagora-app`'S.** The browser is table-backed
because this tree has no `NSMatrix`: one horizontal `NSScrollView` whose document holds one vertical `NSScrollView` per
column, each with an `NSTableView`, and the 10.6 delegate surface and `NSBrowserCell`. The workspace's view owns the
child models, the cell contents, the selection-to-next-column relationship and the preview.

**THE COLUMNS SCROLL AND RESIZE INDIVIDUALLY, AND THE VIEW ASKS FOR THE LATTER.** The browser builds Finder's
256-column pool, so empty slots are visible columns to the right and a column's width survives stepping away from
it; only the visible slots size the horizontal document. A tall folder's vertical scroller
moves that column alone; the browser's outer scroll view is horizontal only. A column whose rows fit HIDES its bar
(`-autohidesScrollers:YES`), so an empty or short column is all content and a bar appears only when it is needed.
`WSColumnView` sets `NSBrowserUserColumnResizing`, which turns the gap between columns into a drag handle: `NSBrowser`
draws the same eighteen-point, three-ring gutter the split view's pane splitter uses, tracks the drag,
consults the delegate's `-browser:shouldSizeColumn:forUserResize:toWidth:`, and re-tiles from the running sum of
per-column widths. `tests/column_view.m` checks the mode, that each column owns a vertical scroller, and that a
three-row column hides it; `libagora-app/tests/browser.m` measures the scroll independence and a forty-point
separator drag.

**THE PREVIEW IS A FIXED RIGHTMOST PANEL, NOT A BROWSER COLUMN.** The plan's "preview column" is satisfied visually
and functionally: it is the rightmost column of the window, it follows the browser's selection, and it stays put while
the columns scroll. Putting a Quick Look preview *inside* the browser would need W9's generators and panel; this
panel shows metadata only, and `README.md` names that boundary.

**NAVIGATING INTO A FOLDER SCROLLS THE COLUMNS ALL THE WAY OVER.** Selecting a branch opens the column to its right;
the browser's own `-scrollColumnToVisible:` only promised that the SELECTED column was in view, so the new column could
sit past the right edge. `NSBrowser` now scrolls its clip view to the document's end after any successful selection,
which puts the newest column against the right edge; `tests/column_view.m` checks the clip view's origin against the
document's maximum. A leaf truncates the columns to its right, so the selected column is the last one and the same
rule shows it.

**AND THE BROWSER'S FRAME SET DID NOT RE-TILE ITS OWN SCROLL VIEW.** `WSColumnView` lays the browser beside the
preview by setting the browser's FRAME; this tier's `NSView -setFrame:` does not call `-resizeSubviewsWithOldSize:`,
and `NSBrowser` only re-tiled in `-setFrameSize:`. The browser's inner scroll view therefore kept the width it had,
and widening the window opened a gap between the last column and the preview panel. `NSBrowser -setFrame:` now
re-tiles on a size change, which is the same rule `NSScrollView` and `NSSplitView` already follow; `tests/browser.m`
and `tests/column_view.m` both check the scroll view's width after a frame change.

**SELECTING A FOLDER OPENS THE NEXT COLUMN; SELECTING A FILE DOES NOT.** The browser's delegate returns the child
count for column N+1 from the selected row in column N; a file returns zero, so the browser leaves the columns as they
are and the preview shows the file. A programmatic selection (`-selectRow:inColumn:`) updates the preview through the
delegate's `-browser:selectRow:inColumn:` hook even though the control's action is suppressed for it.

**AND THE BROWSER FOUND A TABLE BUG.** `NSTableView` released the proposed selection set before copying it; a
delegate that returned that same set (the browser does) made the copy read freed memory and the selection become
empty. The table retains the answer across the release now; the browser's probe is the regression. That fix and the
browser's own design are recorded in `../libagora-app/PROVENANCE.md` § 18.

`tests/column_view.m` measures the three root cells, the two-child column, the grandchild column, a leaf adding no
column, the preview's name/Kind/size/date, an empty folder opening no column, the delegate's open door, a reload with
a new child and the browser's width beside the preview.

## W6 — the file operations, the Trash and the ZIP

**`WSFileOperations`, `WSTrash`, `WSProgressWindow` AND `WSConflictSheet` ARE THIS REPOSITORY'S OWN CODE.** The
manager performs the operations and registers inverses with the window's `NSUndoManager`; the views ask it and then
reload their model. The inline renames in `WSIconView` and `WSListView` go through `-renamePath:toName:error:` when a
manager is set, which is what makes them undoable.

**TWO HANDLERS ARE THE POLICY SEAMS.** A conflict is a `Skip`/`Replace`/`Keep Both`/default answer, supplied by a
probe or by `WSConflictSheet`; progress is `(completed, total, path)` supplied by the controller and drawn by
`WSProgressWindow`. A one-item operation does not open the window.

**THE TRASH IS RECORDS, NOT A PICTURE.** `WSTrash` chooses `~/.Trash` or a per-volume `.Trash-<uid>`, uniquifies a
name already there, writes an XML plist under `.putback/`, and Put Back reads it. The Dock's Trash icon and the
drop-on-it contract are §5.3's and W7's; the **operation** is complete and tested behind them. Empty is not undoable.

**COMPRESS IS A ZIP WRITER, NOT A SHELL-OUT.** zlib's raw deflate with a stored fallback, local headers, a central
directory and an EOCD, written by `AGZipBuilder` in `WSFileOperations.m`. The probe reads the local signature and the
entry name from the bytes. ZIP64 is absent, so an archive over 4 GB or 65,535 entries is refused by name.

**NAMED DEVIATIONS.** The conflict question is a MODAL PANEL, not a sheet, because `WSConflictSheet` was written
before the tier had `NSPanel`/`NSAlert` and has not moved to them; the progress window has no Cancel; a multi-item
operation that fails halfway can leave the items already moved. `README.md` names all three rather than implying a
rollback the code does not perform.

`tests/file_ops.m` measures New Folder, Duplicate, Rename, Move, Copy across `/dev/shm`, conflict Skip/Keep Both,
progress counts, Trash/Undo/Put Back, Empty and Compress with Undo; `tests/trash.m` measures recycle, unique names,
Put Back, a directory and an empty over an explicit trash root.

## Printing — a listing, and the launch's own door

**THE COMPONENT PRINTS A LISTING, NOT A DOCUMENT.** `WSPrintView` builds one row per path — name, kind (through
`WSItemKind`, the same registry the list view uses), size and modification date — and is otherwise a tall flipped
`NSView`: it does not answer `-knowsPageRange:`, so `NSPrintOperation` paginates it by the ticket's imageable height and
the only number this component owns is the row height. The width is A4's imageable width, so a default ticket centres
it with no clipping.

**`WSPrintService` IS THE BODY BEHIND BOTH DOORS.** `WSApplication -application:printFiles:withSettings:showPrintPanels:`
is the launch's and `File > Print…` is the app's; neither owns a renderer, so both reach the service, which copies the
shared ticket per file (a request must not change the application's default paper), merges the settings dictionary,
and prints. The reply is the launch's three-valued one, and a cancel anywhere wins over a success.

**AND THE MENU ROW TAKES THE LAUNCH DOOR RATHER THAN A SECOND PATH.** `-printSelection:` hands its paths to
`-[NSApplication application:printFiles:]`, which asks the delegate — so the menu and an outside request run the same
code, and `tests/printing.m` measures the handoff with a recording delegate instead of printing.

What this deliberately does not do: print a file's CONTENTS (that needs the owning application, and there is no Apple
Event transport here), and draw a running header on every page (that needs `-knowsPageRange:`/`-rectForPage:` and a page
count the listing does not have to offer). Both are named here rather than left to be found.

## Known gaps, recorded rather than left to be found

**THE ABOUT PANEL SHOWS A GENERIC FOLDER AS THE APPLICATION'S ICON.** `WSAboutPanel` asks Icon Services for the
bundle's icon with `AGIconCreateWithURL` on `[[NSBundle mainBundle] bundlePath]`, and the bundle IS a directory — so
Icon Services answers the folder it is looking at rather than an application. The drawing, the layout and the bundle
identity around it are all correct; only the picture is the wrong KIND. Deferred by request ("we can worry about
icons later"); the fix is on the Icon Services side, which needs a rule for a bundle: an `APPL` directory is an
application, and its icon is the application's.

## Licence per file

This repository was relicensed to **LGPL-3.0-or-later** (libraries) and **GPL-3.0-or-later** (the application) on
2026-10-22; the per-file `SPDX-License-Identifier` header is the authority. There is no third-party code in this
component, so there is no other split to record.

## The bundle icon (`Resources/Workspace.icns`)

**DERIVED FROM THE VENDORED FROST THEME, NOT A NEW WORK OF ART.** The Dock draws an application's icon from its
bundle (`CFBundleIconFile` → `Contents/Resources/Workspace.icns`), and Workspace's is the **Home folder** —
the project's choice rather than Frost's, because Workspace is the desktop and the file manager's door to the
user's files.

| | |
|---|---|
| Source art | `libagora-iconservices/themes/Frost/<size>/places/user-home.png` (Frost v0.3.1, MIT — see `libagora-iconservices/themes/PROVENANCE.md`) |
| Sizes packed | 16pt@2x (`ic11`), 32pt@2x (`ic12`), 128 (`ic07`), 256 (`ic08`), 512 (`ic09`) |
| Container | an `.icns` whose entries are the theme's PNG bytes, written by the recipe below; no re-encoding, so the art is byte-identical to the theme's |
| Licence | MIT, travelling with Frost's art |

The recipe is the whole of it — no tool, no encoder:

```sh
python3 - <<'PY'
import struct
base = "libagora-iconservices/themes/Frost"
entries = [("ic11", f"{base}/16x16@2x/places/user-home.png"),
           ("ic12", f"{base}/32x32@2x/places/user-home.png"),
           ("ic07", f"{base}/128x128/places/user-home.png"),
           ("ic08", f"{base}/256x256/places/user-home.png"),
           ("ic09", f"{base}/256x256@2x/places/user-home.png")]
body = b"".join(t.encode() + struct.pack(">I", (d := open(p, "rb").read()).__len__() + 8) + d for t, p in entries)
open("workspace/Resources/Workspace.icns", "wb").write(b"icns" + struct.pack(">I", len(body) + 8) + body)
PY
```

`libagora-iconservices`' `.icns` reader takes the PNG-bearing entries and reads each image's own size, so the type
codes are the container's convention and the art is the theme's.
