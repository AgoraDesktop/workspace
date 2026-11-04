# workspace

**Workspace is Agora's file manager and desktop** — the file manager's role: the windows that browse the filesystem
and the wallpaper-and-icons surface behind everything.

Agora is an installable desktop environment for Linux and the BSDs; see the project README in the parent
directory (`../README.md`). Workspace is an **application**: it consumes the AppKit as a built package
(`AgoraApp::App`) and installs no package of its own — an application is not a library. It does install its
**bundle** (`libexec/Workspace.app`), which is not a package either.

## Status

**W0, W1, W1b, W2, W3, W4, W5 AND W6 ARE DONE.** The desktop (two levels), its icons, the application menu and the FILE
WINDOW shell all work. The window is assembled from the platform's parts — a toolbar, an `NSOutlineView` sidebar in
an `NSSplitView`, an `NSPathControl`, a status bar and an `NSSegmentedControl` — and every strip reads the SAME
`WSItemModel`. The **Icon** mode is W3's `WSIconView` (keyboard, type-select, rename, drag and drop, spring-loading);
the **List** mode is W4's `WSListView` (Name, Date Modified, Size, Kind, disclosure, sorting, rename); and the
**Column** mode is W5's `WSColumnView` — an `NSBrowser` whose selection opens the next column, with a fixed preview
panel showing the selected item. Under the views is W6's `WSFileOperations`: New Folder, Duplicate, Rename,
Move/Copy, Move to Trash, Put Back, Empty Trash and Compress, with Undo, a progress window and a conflict panel.

**AND A RIGHT-CLICK RAISES THE MENU FOR WHAT THE POINTER FOUND.** `WSContextMenu` builds three of them, and ALL FOUR
surfaces answer the same three — a file window's grid (`WSIconView`), the desktop (`WSDesktopView`), the List
(`WSListView`) and the Columns (`WSColumnView`, whose menu is the browser's own right-click):

- **one icon**: Get Info, [Extract Archive], —, Cut, Copy, —, Rename, Compression ▸, Move to Trash;
- **one icon of several held**: Get Info, [Extract Archive], New Folder with Selection, Compression ▸, —, Cut, Copy, —,
  Move to Trash (no Rename: one name for many is a question, not a command);

`[Extract Archive]` is the one row in brackets, and it is **asked for rather than drawn grey**: the menu puts the question
to the target (`-cg_selectionCanBeExtracted`) and the row exists only when every selected item is an archive.

**`Compression ▸` IS A SUBMENU BECAUSE THERE IS MORE THAN ONE ARCHIVE.** Five leaves — Zip, Tar, Tar.gz, Tar.bz2, Tar.xz —
each the *same* command with the format as its tag, so a target implements one selector rather than five and a probe reads
the choice off the item. A format this build cannot write (no bzip2, no liblzma) is grey rather than a click that fails.
The File menu carries the same submenu.
- **the empty grid**: New Folder, —, Paste, Select All.

A click on an icon that is NOT part of the held group narrows the selection to it first, and a click on the background
leaves the selection alone. The commands behind the rows are the ones this tree already had — the inline
rename field, W6's trash, and the pasteboard `WSItemDrag` writes — plus Paste, which a Cut needs to mean anything;
Get Info, which opens the inspector below (`WSGetInfoWindowController`); and Compress, which writes the archive beside
what it compressed.

**AND EVERY ROW IS ANSWERED BY THE THING THE MENU IS AIMED AT**, which is not a detail: the list and the browser aim
their menus at the WINDOW (it owns the selection's meaning), while the grid and the desktop aim at THEMSELVES. MEASURED:
Get Info was grey in the grid and Compress would have been dead there too, because the view that raised the menu answered
neither — so `WSIconView` answers both now, and the desktop answers both as well.

**AND A RIGHT-CLICK ON THE EMPTY GRID RAISES THE FOLDER'S OWN.** New Folder, a separator, Paste, Select All — the rows the
reference file manager shows when the pointer is over nothing, about the directory the grid is showing. The two menus are
chosen by what the pointer found rather than by one menu made to fit both, and a click on the background leaves the
selection alone so Paste and New Folder stay useful with something held somewhere else.

The gesture is the **AppKit's**, not each view's: `-[NSView rightMouseDown:]` asks `-menuForEvent:` and opens the answer,
which is why a view only has to answer a question. `appkit-context-menu` measures that pair, `workspace-icon-view`
measures the three menus, the narrowing, and each command, and the list and column suites measure their own menus.

**AND THE COMMANDS THEMSELVES ARE THE WINDOW'S, NOT A VIEW'S.** Cut, Copy, Paste, Rename, New Folder with Selection and
Select All live on `WSFileWindowController`, because it already answers `-selectedItems` per view mode and owns the
operation manager, the progress plate and the undo stack — so the List and the Columns raise menus aimed at IT
(`WSContextMenuCommandTarget`) and there is one implementation of Paste rather than four. The icon grid and the desktop
still answer their own, being the first responder; Rename is grey in Column mode, where a cell has no editor, and Select
All is grey there too, where the browser has no such door.

**AND DRAG AND DROP WORKS IN ALL FOUR.** The List is an `NSOutlineView`, so the tier's own table drag asks its data
source to write the rows and to validate and accept a drop — four answers, no fifth drag implementation. The Columns are
an `NSBrowser`, whose columns are tables whose data source is the browser: the browser now FORWARDS those four questions
to its delegate (`-browser:writeRowsWithIndexes:inColumn:toPasteboard:` and the validate/accept pair), and
`-registerForDraggedTypes:` on the browser is applied to every column's table, including the ones made later. A drop on a
folder row goes INTO it; anywhere else goes into the folder that row lives in, or into the folder the grid is showing.

**AND A COMMAND THE GRID PERFORMS ENDS WHERE THE WINDOW'S OWN COMMANDS END.** The operation manager a grid is handed
belongs to its window — the progress plate is the window's, its undo manager is the window's — so the view reports the
ending through `-iconViewDidFinishOperation:` and the controller runs the same `-finishOperation` its own menu rows do.
Without it the plate was opened by the handler and closed by nobody: a half-transparent rounded panel left in the middle
of the window after New Folder with Selection.

**AND THE MENU BAR CARRIES THE TIME.** `WSMenuBarClock` is an `NSStatusItem` — the strip's third surface, and the only
one an application may put something in — so the clock is drawn by Workspace and PACKED BY THE SERVER against the
screen's right edge, behind a view whose width moves with the digits. It is a status item and not a window: it stays
on the strip when another application is in front.

**The desktop is TWO LEVELS: Workspace owns the ICON layer, not the wallpaper.** It
launches from its bundle, opens one borderless window at `kCGDesktopIconWindowLevel` — **TRANSPARENT** — and
draws only the items of a directory. The WALLPAPER is a separate window at `kCGDesktopWindowLevel`, and it is the
**Dock's** to draw.

```
$ .../Workspace.app/Contents/<platform>/<arch>/Workspace --seconds 3 --file-window
workspace: file window for /home/kyle/Desktop
workspace: desktop window at level -2147483627, frame 1280x720 at (0,0)
```

Five arguments, all TEST DOORS and named as ones: `--seconds N` ends the ordinary run loop after N seconds (a
desktop is a thing that stays, and the suite needs it to be able to leave); `--show-about` opens the About panel as
part of starting up; `--file-window` opens a file window on the desktop folder; and `--list-view` / `--column-view`
do the same with W4's List or W5's Column chosen. The last four are otherwise reached by menu actions, and a
synthetic click reaches a compositor's motion path and not its button path on some hosts.

`-2147483627` is `kCGDesktopIconWindowLevel` — one level above `kCGDesktopWindowLevel` (`-2147483628`, both from
`libagora-drawing`'s `CGWindowLevel.h`). The level is **below every ordinary window**, which is what makes this the
desktop rather than a window; the wallpaper is the window one level below it. The frame is
the whole screen, `[NSScreen frame]` and not `visibleFrame`, because the Dock and the menu bar are drawn
*over* the wallpaper.

**AND THAT LEVEL IS WHAT MAKES A DOCK CLICK DO THE RIGHT THING WHEN NO FILE WINDOW IS OPEN.** The AppKit asks its
delegate `-applicationShouldHandleReopen:hasVisibleWindows:` when a click on the Dock tile finds nothing above the
furniture levels — the desktop is below them, so "nothing" is the honest answer — and this application answers it
the way Finder does: `newWorkspaceWindow:`, one folder window on the desk. A click that DOES have file windows never
reaches the question; the Dock raises them, back to front, and they keep the order they were in.

### What is measured, not assumed

`ctest` runs **nineteen tests**. `workspace-desktop` is the pixel suite — `tests/run-desktop.sh` + `tests/check.py` —
against **Agora's own window server**, headless: it runs the **bundle's** executable (the bundle path is part of what
W0 proves), places a **normal** window over the desktop with the server's own test client, and reads the server's
screenshot. **9 checks, 0 fail**:

- the **wallpaper window** (at `kCGDesktopWindowLevel`) covers the screen, at its own level;
- **Workspace's icon window is TRANSPARENT** — the wallpaper shows through it wherever there is no icon;
- an **icon** is drawn where its sidecar says it goes;
- a **normal window created *after* the desktop is composited *over* it** — which can only be the level.

The other eleven are offscreen. `workspace-desktop-layout`, `workspace-metadata-store`, `workspace-main-menu`,
`workspace-go-menu`; the shell's own `workspace-history` (**15 checks**) and `workspace-file-window`
(**120 checks** — including the folders it watches for changes made outside it, the trash's Put Back row in all
three modes, and leaving the trash restoring the title and path bar); the icon view's
`workspace-icon-view` (**147 checks** — the grid, the keyboard, the modifiers, the
rename, the drag and the three context menus); the list view's
`workspace-list-view` (**53 checks** — the ordering, the modifiers, the click that must not move, the triangle that
must not drag, the tree across a reload, the rename, the undoable drop, the context
menu and the drag); the column view's `workspace-column-view` (**52 checks** — the columns, the reload that keeps
them, the multi-row selection, the preview, the menu and the drag); and W6's
`workspace-file-ops` (**28 checks**) and `workspace-trash` (**19 checks**); and the print system's
`workspace-printing` (**24 checks**). The file-window through printing suites are the proofs below.

### W1: the desktop's icons

Three objects, and the file **window's** views will be built from the same three:

- **`WSItemModel`** — one directory's items, and the one model every view reads (`WORKSPACE-PLAN.md` §6).
- **`WSIconLayout`** — pure geometry: a **top-to-bottom, RIGHT-TO-LEFT** grid (macOS's own desktop order), the
  nearest-free snap a drop lands on, an arrange
  order, and a hit test. It needs no view, which is why it is checked **offscreen**.
- **`WSMetadataStore`** — the per-folder `.agora` sidecar: icon positions and the icon size.

The icon pixels themselves come from **Icon Services**, whose default art is the theme the desktop names — the
Flat-Remix `demo/flat-remix-accent.sh` renders into the prefix, or the drawn generics on a machine without it;
`WSItemIcons` is the only AppKit-side wrapper around
that lookup, and `AGORA_ICON_THEME` can point a run at different art.

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

### The menu bar's status area: the clock

**`WSMenuBarClock` IS THE STRIP'S THIRD SURFACE, AND THE ONLY ONE THE APPLICATION PLACES — BY SAYING HOW WIDE IT IS.**
The server owns the strip and the System menu's square; the application's menus are a window of the application's own,
as wide as its titles; and the time is an `NSStatusItem`, which has a LENGTH and NO POSITION. The width is the whole of
what an application is allowed to say, because it does not know what else is in the bar and therefore cannot know where
its own item goes — so the server packs it against the screen's right edge and the application draws into it.

The view fills the bar's own face (`+[NSWindow cg_menuBarColor]`, the same door the bar window and a dropdown's panel
use, so there is no seam), centres the locale's short time in its own padding, and is re-measured whenever the string
changes: `9:05` becoming `10:05` is one digit wider, and the view, the item's window and the server are all told — the
item would otherwise be a box whose contents had grown past its edge.

**IT REFRESHES WITHOUT A TIMER, AND THAT IS A FINDING RATHER THAN A STYLE.** `NSTimer` is inert under
`-[NSApplication run]`: the loop never enters `NSRunLoop`, so the clock reads the time once per frame from
`NSApplicationDidUpdateNotification` — the AppKit's "change what is shown between passes" — and formats a string only
when the minute moved. See [`PROVENANCE.md`](PROVENANCE.md) for the measurement.

**IT STAYS ON THE STRIP WHEN WORKSPACE IS NOT ACTIVE**, because it is a status item and not a window: the desktop
suite asserts the clock's ink in the scene where another application is in front and Workspace's menus are correctly
absent. Clicking it does nothing — `-[NSStatusItem popUpStatusItemMenu:]` is a named refusal in this tree, so there is
no menu to offer.

### W2: the file window shell

**ONE FOLDER, ONE MODEL, FOUR STRIPS.** `WSFileWindowController` opens a folder, owns its `WSItemModel` and its
`WSHistory`, and gives the model to every part of the window: the title is the folder's name, the `NSPathControl` is
its URL, the status bar says the model's own count, and `WSIconView` draws the model's items. A navigation
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

**ALL THREE VIEWS ARE ENABLED.** The switcher has three segments. W2's Icon mode is W3's `WSIconView` (selection,
keyboard, type-select, inline rename, drag/drop, spring-loading); W4 adds `WSListView` in the same content area, over
the same model; W5 adds `WSColumnView`, an `NSBrowser` plus the preview panel.

**A SECOND WINDOW IS A SECOND MODEL.** File > New Workspace Window creates another controller on the desktop
folder; a folder double-clicked on the desktop posts `WSDesktopViewOpenFolderNotification`, and `WSApplication`
opens it in a file window of its own. Each controller keeps its own folder, history and path bar, and closing one
removes it from the application's list without touching the desktop or the other windows.

**AN APPLICATION BUNDLE IS A PACKAGE, AND A PACKAGE IS OPENED RATHER THAN BROWSED.** An `.app` is a directory on
disk, so `-isDirectory` alone sent a double-click into its `Contents` — the opposite of what a person who
double-clicked an application asked for. `WSItem -isPackage` asks the AppKit's own door
(`NSWorkspace -isFilePackageAtPath:`) once, and `WSItem -isBrowsable` is the ONE rule every view shares: a browsable
item is navigated into, anything else is opened (`-openFile:`, which launches an application bundle), and only a
browsable item gets a disclosure triangle or a browser column. The desktop's double-click reads the same rule, so a
bundle dropped on the Desktop launches too, and `WSItemKind` asks Launch Services for a package's Kind instead of
answering "Folder". `tests/file_window.m` builds a real bundle whose executable is a script and measures both
halves: the window did not navigate, and the script wrote its sentinel — a bundle nobody can launch would otherwise
pass a weaker check.

**THE CONTENT VIEW IS NOT FLIPPED, AND THE STRIPS ARE PLACED BY AUTO LAYOUT.** The strips want a top-down layout,
but this tier's live drawing path enters the content view without mirroring a flipped ROOT, so a flipped content
view placed its top strip at the bottom. The window keeps Cocoa's y-up direction, and the three strips are now
constraints on the content view rather than frames computed in a resize hook: the path bar is pinned to the top with
its 24-point height, the status bar to the bottom with its 22, and the split view fills the band between them and the
full width. The split view's delegate keeps the sidebar's width and gives the content pane everything else, so a
window resize moves the boundary rather than scaling both panes. `tests/file_window.m` resizes the window twice,
checks every strip and the two panes, and follows the icon view into its new clip width; the flipped-root finding is
recorded in `PROVENANCE.md`.

**THE SIDEBAR'S DIVIDER IS A GUTTER, AND IT IS THE HANDLE.** The split view uses
`NSSplitViewDividerStylePaneSplitter`, the same eighteen-point, three-ring gutter the browser's columns use, so the
sidebar can be dragged wider or narrower and the grip says where to put the pointer. Its six rows fit, so the
sidebar's own vertical bar is autohidden; `tests/file_window.m` checks the style, the thickness and the hidden bar.
**EVERY SCROLL VIEW THE SHELL CREATES SETS `-autohidesScrollers:YES`** — the sidebar, the shared content pane
(icon, list and column modes), and the tests' own scroll views — so a document that already fits never wears a
bar. The file-window suite checks the icon grid and the list in the content pane.
**A VIEW SWAP RESETS THE CONTENT SCROLL'S ORIGIN** — otherwise a scrolled icon grid would hand its offset to the
column browser and start it partway down or across; the test scrolls the grid, switches Icon → Column, and checks the
browser's first column is back at the document's origin.

`tests/file_window.m` is the proof: a temporary tree of folders, a file and a hidden file; the model's count and the
status bar's; the path bar's URL; the sidebar's two sections and four places; the switcher's three segments and their
enablement; the toolbar's items; Back disabled at the first location; a double-click that navigates and updates
every strip; an application bundle that is OPENED rather than navigated into, runs, and stays a leaf in List and
Column; Back/Forward and a new navigation's truncation; the resize's strip geometry; and a second controller
with its own model and history.

### W3: the icon view

**`WSIconView` IS THE FILE WINDOW'S ICON MODE, AND IT IS THE DESKTOP'S ENGINE IN THE WINDOW'S ORDER.** `WSItemModel`
still supplies the items and `WSIconLayout` still supplies the cell, the margins and the hit test; the new
`WSIconOrderLeftToRightRows` fills a row and then the next row down, while the desktop keeps its right-to-left
columns. `tests/icon_view.m` checks the order arithmetically: the first cell at (16,16), the second at (96,16), the
fifth at (16,104), and a two-row document 192 points tall.

**THE LABEL BELONGS TO THE CELL'S WIDTH, NOT TO THE NAME'S OWN WIDTH.** `WSIconLabelText` cuts a long name in the
MIDDLE with an ellipsis until it measures inside the cell, and both the icon view and the desktop clip the drawing to
a band as a second guard. Without it a full directory's long names were wider than their cells and overlapped their
neighbours — the screenshot that started this change showed rows of text sitting on top of one another. **The CLIP is
the cell's WIDTH CENTRED ON THE ICON, not the cell**: the cell begins at the icon and carries its padding to the
right, so a name centred on the cell sat a padded half-cell to the right of the folder it named. Both surfaces had
that off-centre; both now centre on the icon and clip to the band that follows it.

**SELECTION IS THE KEYBOARD'S AND THE POINTER'S.** A click selects; Shift extends from an anchor; Command toggles —
and so does Control, which is how every desktop that is not a Mac spells "add this one too"; the same two modifiers
work in List and Column mode, on the desktop, and as the additive press that begins a band. Command-A selects all. Left/Right move by one item, Up/Down by one row of the grid's columns, Home/End go to the
ends, and the selected icon wears a focus ring while the view is first responder. TYPE-SELECT accumulates a prefix
for one second (`d`, then `do`), starting after the selection and wrapping, and a new key after the timeout starts a
new prefix.

**THE WASH AND THE FOCUS RING ARE ONE RECTANGLE, AND IT IS NOT THE CELL.** The cell is deliberately asymmetric — it
starts at the icon and carries its padding to the right and above, so neighbouring hit rectangles share an edge —
which makes it the wrong shape to paint: filling it put the blue wash a padded half-cell to the right of the folder,
and the ring went round the bare icon two points out, a different rectangle whose top edge landed on the label's
first line. `-highlightRectAtIndex:` answers one rectangle instead: the cell's WIDTH centred on the icon, tall enough
to hold the icon, the label and two points of air on every side, with the same four-point corner for the fill and the
stroke. The label is centred on the ICON too (it used to be centred on the cell), the selected name keeps BLACK ink
(a white name on a 35% wash is the ghost the screenshot showed, and the table view reached the same verdict for the
platform's own light accent), and the rename field opens on that same rectangle so the name does not jump.

**A SELECTION THAT MOVES ONE CELL INVALIDATES ONE CELL.** The view answered every selection change with
`-setNeedsDisplay:`, which is "all of me": the window drew all nine folders and all nine names and copied the whole
frame to move a wash one cell right — MEASURED at 20-45 ms a click. `-invalidateSelectionChangeFrom:` takes a snapshot
of the selection before the change and invalidates the union of what it touched — the cell it left and the cell it
entered — and `-becomeFirstResponder`/`-resignFirstResponder` invalidate only the selected cell, because the focus ring
is the only mark that depends on being first responder. `-drawRect:` also skips an item whose highlight does not
intersect the dirty rectangle, since the name is cut to the cell by MEASURING it first. MEASURED after: 3.6-10.8 ms
for the two cells. **AND THE DAMAGE REACHES TWO POINTS PAST THE CELL** (`WSIconHighlightSlop`), because the focus
ring is STROKED on the cell's edge: half the stroke and its antialiasing sit outside the rectangle, so damage that
ended at the rectangle left a thin outline in every cell the selection had left — the lines a person sees when the
highlight moves along a row. `tests/icon_view.m` asserts the shape of that invalidation. **AND THE SNAPSHOT IS A `-mutableCopy`
AND NOT A `-copy`**: this tree's immutable family answers `-copy` with `[self retain]`, so a copy of the live mutable
set saw every removal the change made and the cell that was left behind was never repainted — MEASURED as a stray wash
on the old cell.

**INLINE RENAME IS A FIELD OVER THE LABEL.** Return (or `-beginRenamingSelectedItem`) puts an editable field where
the label is, with the current name and — for a file — the base name selected and the extension left alone. Commit
moves the item through `NSFileManager`, reloads the model and follows the renamed item; cancel, an empty name, a
slash, `.`/`..` or an existing name are all refused. A rename that succeeds tells the controller, so the status bar
and the grid re-read the same model.

**DRAG AND DROP IS THE TIER'S SESSION, BETWEEN WINDOWS.** A press past four points puts the selected paths on
`NSDragPboard` as `NSFilenamesPboardType` and begins an `NSDraggingSession` with one item per selected icon. Every
`WSIconView` registers for the filenames type: the destination is the folder icon under the pointer or the window's
own folder, and the operation is chosen from the volumes and the modifier keys — same volume Move, across volumes
Copy, Option Copy, Command across Move, Command-Option Link. A drop preflights every destination and refuses a
conflict rather than replacing a file; on success both the destination and the source view reload. The test drives a
real session from one window's icon view into another's and checks the file moved and both models updated.

**A LINK IS A SYMBOLIC LINK UNTIL `WSAlias` EXISTS.** The Mac's alias is the bookmark record of
`WORKSPACE-PLAN.md` §5.2, which is `WSAlias`'s (W6); the Link operation here is `symlink(2)` and the header says so.
A hovered folder for 0.6 s posts `WSIconViewRequestFolderWindowNotification`, and the application opens the folder's
window — the same request a desktop folder double-click makes. W3 does not yet move the in-flight drag into that
window automatically, and there is no rubber-band selection in the icon view; both are named rather than implied.

`tests/icon_view.m` is the proof: order and document height; every keyboard movement and the Shift/Command/Control
click selection;
the prefix type-select; a rename that moves the file, a cancel and three refusals; the source's pasteboard and
session; the five policy answers; Move, Copy and Link performed on two volumes; a conflict refused; a drop on a
folder icon; the spring notification; and a real cross-window session.

### W4: the list view

**ONE DIRECTORY'S MODEL BECOMES A TREE BY ASKING FOR CHILD MODELS.** `WSListView` is an `NSOutlineView`; its root
children are the window's `WSItemModel`, and a folder's children are another `WSItemModel` made on first expansion
and cached. No parent pointer or recursive walk was added to the model — the same one-model-per-directory rule W2
proved still holds, and the list is another rendering of it.

**THE COLUMNS ARE THE ITEM'S OWN FACTS.** Name and Kind (Launch Services' `LSCopyKindStringForURL`, with the
extension as the readable fallback when the answer is an internal `dyn.…` UTI), Date Modified and Size (read lazily
from the file's attributes), and the disclosure triangle on the Name column. A directory's Size is `--`, and its
Kind is `Folder`. The header's sort prototypes become `NSSortDescriptor`s; the data source maps the first one to a
`WSItemSortKey` and reloads.

**DIRECTORIES FIRST, THEN NATURAL ORDER.** `WSItemSort` keeps the two groups fixed — reversing a column never puts
files above folders — and orders within them by natural name (`file2` before `file10`), modification date, size or
Kind, with the natural name as the tie-break. `tests/list_view.m` checks the name, size, date and Kind orders
against a deliberately dated and sized tree.

**EXPANSION IS REMEMBERED BY PATH, NOT BY ITEM IDENTITY.** `NSOutlineView`'s expanded set is identity-based, and a
reload makes new `WSItem` objects; `WSListView` keeps the expanded PATHS, re-expands the matching new items after a
reload and restores the selected paths. The test expands a folder, adds a file, reloads, and finds the folder still
open with its child still a visible row.

**RENAME IS THE TABLE'S FIELD EDITOR.** The Name column is editable; Return starts the session on the selected row
and the data source's set-object door performs one `NSFileManager` move, reloads the parent model, restores the
expansion and selects the new name. The test drives the editor, sets a name and ends the session, then checks the
file and the row. The table's field editor ends through the TABLE data-source door
(`tableView:setObjectValue:forTableColumn:row:`), not the outline's item door, so `WSListView` implements both and
routes each to the same rename — a finding recorded in `PROVENANCE.md`.

**THE NAME COLUMN WEARS THE ITEM'S ICON.** `WSListNameCell` (WSListView.m) is an `NSTextFieldCell` that draws a
16-point `WSItemIcons` image before its title; `WSListView` sets it per row through the outline's
`willDisplayCell` door, so the table's reused cell never carries a previous row's picture. The advance lives in
`-drawingRectForBounds:`, which is also the door the field editor's frame comes from — so a rename's text starts
after the icon rather than under it.

**AND `--list-view` NOW ACTUALLY OPENS LIST MODE.** `WSApplication`'s two mode setters both assigned
`_fileWindowViewMode` unconditionally, so `main`'s fixed order — list YES, then column NO — reset the list choice to
0. A false flag now means "not this mode", not "icons"; the live door and the switcher agree.

Run it live with `--list-view` (or choose List in the switcher / View menu). `tests/list_view.m` is the proof: name order with four folders and five files, the three column values, size/date/
Kind sorting, a folder's expansion across a reload, a rename through the field editor, Return, Right/Left,
Command-Down, and a 16-point icon on the Name cell.

### W5: the column view

**THE BROWSER IS THE PLATFORM'S, AND THE CHILD MODELS ARE THE SAME ONES.** `WSColumnView` owns an `NSBrowser` whose
columns are folders and rows their items; a selected folder's children come from a child `WSItemModel` made on
demand, exactly as the list view's do. The browser's delegate fills each `NSBrowserCell` with the item's name,
sixteen-point icon and leaf flag, and the selection loads the column to its right. A leaf opens no column.

**THE PREVIEW IS THE RIGHTMOST COLUMN.** A fixed panel at the right shows the selected item's icon, name, Kind, size
and modification date; selecting a folder both loads its children and previews the folder, and selecting a file
leaves the browser alone and previews the file. The panel stays put while the browser's columns scroll horizontally,
which is the shape this stage calls the preview column.

**THE BROWSER IS TABLE-BACKED, AND THAT IS `libagora-app`'S DECISION.** Apple's `NSBrowser` is an `NSMatrix` of
`NSBrowserCell`s; this tree has no `NSMatrix`, so `NSBrowser` is one horizontal `NSScrollView` whose document holds
one vertical `NSScrollView` per column, each with an `NSTableView`, and the 10.6 delegate surface
(`-browser:numberOfRowsInColumn:`, `-browser:willDisplayCell:atRow:column:`, `-selectedColumn`, `-path`, column width
and scrolling). The old matrix form is named absent in its header.

**EACH COLUMN SCROLLS ON ITS OWN, AND EACH HAS ITS OWN WIDTH.** `WSColumnView` puts the browser in
`NSBrowserUserColumnResizing`; the separator between two columns is `NSSplitView`'s eighteen-point pane-splitter
gutter, with the same three two-point rings eight points apart, and the browser draws and tracks it as a drag handle,
and a tall column's vertical scroller moves that column alone. **A SHORT COLUMN'S BAR IS HIDDEN** — the browser's
column scroll views set `-autohidesScrollers:YES`, so an empty or three-row column takes the whole column with no
bar and the bar appears only when the rows overflow. **THE BROWSER BUILDS FINDER'S 256-COLUMN POOL**, so the slots
to the right of the selection are visible empty columns and a column's width survives navigating away; only the
visible/active slots size the horizontal document. `NSBrowser`'s `-widthOfColumn:`/`-setWidth:ofColumn:`
are the per-column pair, and the browser re-tiles every column after a width change from the running sum rather than a
shared step.

**A RELOAD RE-READS THE ROOT AND SELECTS AGAIN.** `-reloadData` clears the child models and column cache, reloads the
root model and asks the browser for column zero; the test then selects A Folder and finds the new child in column 1.
The preview's text and item are seams (`-cg_previewItem`, `-cg_previewText`) because they are what "the last column's
preview" means to a probe.

`tests/column_view.m` is the proof: the root's three cells (directories first), selecting A Folder loads its two
children, selecting A Child loads its one child, selecting a leaf adds no column and previews the file (name, Kind,
size, date), an empty folder opens no column but previews, the delegate's open door, a reload with a new child, and
the browser's width beside the preview. Run it live with `--column-view`.

### W6: the file operations, undo and the Trash

**THE MANAGER OWNS THE OPERATION.** `WSFileOperations` implements New Folder, Duplicate, Rename, Move/Copy To,
Move to Trash, Put Back, Empty Trash and Compress. Every reversible operation registers its inverse with the
window's `NSUndoManager`, so Edit → Undo/Redo work through the same manager a text field uses, and the inline rename
in both the icon and list views goes through `WSFileOperations` rather than moving the file itself.

**CONFLICT AND PROGRESS ARE HANDLERS.** A destination that exists is put to a conflict handler that answers Skip,
Replace, Keep Both or the default; a probe supplies the answer directly, and the File window supplies
`WSConflictSheet` — a modal Replace/Skip/Keep Both/Cancel panel. It was written before the tier had
`NSPanel`/`NSAlert` (both are in `libagora-app` now) and has not moved to them, so it is still its own panel rather
than a sheet. The progress handler is called once per top-level item and feeds `WSProgressWindow`'s
`NSProgressIndicator`; operations of one item stay quiet.

**THE TRASH IS A DIRECTORY AND A RECORD.** `WSTrash` recycles into `~/.Trash` (or a per-volume `.Trash-<uid>` when
one can be made; an explicit root is what the probe uses), uniquifies a name already there, and writes a Put Back
plist under `.putback/` with the original path. `-putBackItem:` moves it home and removes the record; `-emptyTrash:`
removes the items and the records. Empty is deliberately NOT undoable.

**COMPRESS WRITES FIVE ARCHIVES, AND THEY ARE ALL WRITTEN HERE.** Zip (store and raw deflate), Tar (ustar headers, data
padded to the block, GNU's `././@LongLink` when a name will not fit), and the same tar through gzip, bzip2 or liblzma —
the wrapper being the only difference, so the rules are one set: streamed rather than buffered, each entry's own mode and
time, symlinks stored as links, the bar counting files, Undo removing the archive. What this writes, the extractor above
reads back, and `tar`/`unzip` agree.

**AND THE ZIP IS THE SAME STORY.** The archive is appended to as it is made — local header, then the
entry's bytes through zlib's raw deflate or straight through, then the header patched in place with the CRC and both
sizes — so a file is never held in memory whole: MEASURED, a 191 MB tree cost a peak RSS of **409 MB** when the
archive and every file were buffered and costs **27 MB** now, in **193 ms** rather than 5.6 s, because a file whose
first 64 KB does not shrink (a picture, an archive, a disk image) is stored and never fed to zlib at all. Each entry
keeps its own `mtime` and its `st_mode` — `version made by` says unix, so a restored script is executable — a symlink
is stored as a link rather than followed, and a failure takes the half-written archive away. The bar counts the FILES
in the tree (a folder of five files says "5 of 5" instead of the "1 of 1" the window never showed). No external
archiver is run, which is why the test can read the central directory and ask what a reader would believe.

**AND IT IS ZIP64 WHEN IT HAS TO BE.** An entry at or over 4 GB, a local-header offset past 4 GB, or more than 65,535
entries each switch the records to their 64-bit forms: the size and offset fields go to `0xFFFFFFFF` and the real values
into a `0x0001` extra field — in the order a reader walks them, uncompressed, compressed, offset — with the `0x0001`
extra in the LOCAL header too, which is why the decision is made from the file's `st_size` before a byte is read. A
directory over the limits also gets the ZIP64 end of central directory, its locator, and the sentinel-filled end record
above it. The suite cannot write four gigabytes, so `+cg_setZip64LimitsForTesting:entries:` lowers the thresholds and the
same records are measured on a few kilobytes; the real limits were verified once against Python's `zipfile` and `unzip`
on a 4.1 GB entry.

**AND AN ARCHIVE UNPACKS BESIDE ITSELF, WHATEVER IT IS.** `-extractArchive:` reads `.zip` (store and raw deflate, ZIP64
when a record needed 64 bits) and the tar family — `.tar`, `.tar.gz`/`.tgz`, `.tar.bz2`/`.tbz`/`.tbz2`,
`.tar.xz`/`.txz` — through zlib, bzip2 and liblzma. The two codecs are FOUND AT BUILD TIME and are not required: a
Workspace built without one still extracts everything else, and says which codec it was built without when it meets that
kind rather than calling the archive corrupt. A tar is read as the stream it is, with ustar prefixes, GNU long names and
PAX records; because a stream cannot say how many entries it holds until it has gone past, it is STAGED in the folder it
would have made and the single-file rule is applied at the end. It makes `<folder>/<basename>/`: `trip.zip` beside `trip`,
and "trip 2" when the name is taken, because two extractions are two folders. Every entry keeps its mode and its
modification time, a symlink comes back as a link, empty folders survive, and a ZIP entry's CRC is checked.

**AND AN ARCHIVE OF ONE FILE — ZIP OR TAR — IS UNPACKED AS THAT FILE.** Wrapping a single document in `<basename>/` makes a person open
a folder to reach the only thing in it, so the single-file case lands beside the archive under the ENTRY's own name —
`photos.zip` holding `photos/cat.jpg` gives `cat.jpg` next to it, and `cat 2.jpg` if that name is taken. A folder entry
that only names the file's parent does not change the count; anything with two files in it is a folder again, and an
archive whose only entry is an empty folder is a folder too. **A NAME THAT
LEAVES THE FOLDER REFUSES THE WHOLE ARCHIVE**: an entry called `../escape.txt` or `/etc/passwd` is zip-slip, so the folder
made so far is removed and the answer is nil. Undo removes the folder. A double click on an archive takes the same command
— there is no unarchiver registered for `.zip` in this tree's Launch Services, so the launch door would answer "no
application" for the one file type the shell can open itself.

**AND IT LANDS BESIDE WHAT IT COMPRESSED.** Compress used to write into `-cg_commandDirectory`, which answers the COLUMN
a context menu was raised in and is the browser's ROOT when the command comes from the menu bar — so compressing
`Applications/Forge.app` from the File menu put `Forge.zip` in the home folder, one column to the left. Duplicate had the
same defect; both now use the SELECTION's own folder.

`tests/file_ops.m` is the proof: New Folder, Duplicate, Rename, Move, Copy (including `/dev/shm`), conflict Skip and
Keep Both, progress counts, Trash/Undo/Put Back, Empty and Compress with Undo after each. `tests/trash.m` is the
Trash's own: recycle, unique names, Put Back, a directory and an empty.

### W8: Get Info

**ONE WINDOW PER SUBJECT, REUSED.** `WSGetInfoWindowController` shows what `WSItemInfo` measured in six collapsible
sections — General, More Info, Name & Extension, Comments, Preview, Sharing & Permissions — in a flipped container whose
sections are stacked by arithmetic, because this tree has no nib compiler and every other window is built the same way.
**Only General starts unfolded**: a window that showed all six at once would be taller than the desktop it sits on before
it said anything. Folding a section shrink-wraps the window to the bands that are left and unfolding one grows it, top
edge kept where it was; past a ceiling the document scrolls. Asking again for the same paths brings the open window forward and re-reads it rather than stacking a
second copy; a selection is one answer, with the facts that cannot be summed left blank rather than guessed (`9,731,676,356
bytes (9.73 GB on disk) for 185 items` is a sum and a count, and a name is nothing at all).

**THREE OF THE SIX WRITE, AND THEY WRITE WHERE THE REST OF THE SHELL READS.** The name field renames the item through
`WSFileOperations -renamePath:toName:error:`, so the validation and the "that name is taken" refusal are the ones every
other rename uses, and the comment is re-filed under the new name. The **Locked** box is the owner's write bit — this
kernel has no user immutable flag, so that is what "locked" can honestly mean here — and it keeps every other mode bit.
The **comment** goes into the enclosing folder's `.agora` sidecar, keyed by name, which is where this tier already keeps
what a person decided about a name; it is saved as it is typed, because a window closed by its title bar never sends the
field an "end editing".

**THE PRIVILEGES ARE EDITABLE, AND EDITING ONE IS A CHMOD.** A click in the Sharing & Permissions table's Privilege
column raises the four choices a POSIX mode can say — Read & Write, Read only, Write only, No access — with the true one
ticked, and the pick replaces that class's three bits and leaves the rest of the mode alone (`WSItemInfo
-cg_setPrivilegeIndex:forClass:paths:`, so the write can be checked without a window). The row IS the class: 0 the owner,
1 the group, 2 everyone. There are no ACLs here, so there is no +/− and no gear — the popup is the whole of what a POSIX
mode can be told. **The column is a plain field and the menu is an ordinary one**, not an `NSPopUpButtonCell`:
MEASURED in a session, that cell draws its title one line-height low inside a flipped table and the words came out cut in
half by the row beneath them.

**A FOLDER IS AS BIG AS THE TREE UNDER IT, PACKAGES INCLUDED.** A directory's own `stat` says nothing — 4,096 bytes of
entry block, and `st_blocks` is often zero on a modern file system, so `Downloads` read "140 bytes (Zero bytes on disk)".
`WSItemInfo +cg_measurePaths:` walks: `lstat` each entry, add its bytes and its `st_blocks`, descend into every directory
(a `.app` is a directory like any other, which is what stops a bundle reporting one folder entry instead of its
`Contents`), and count what it saw. It is a SEPARATE PASS from the window's facts because it is not free — MEASURED 12.9 ms
over 3,801 entries, 41.6 ms over a 10,400-entry source tree, 7.7 s for `/usr` — so the window opens with the shallow
number saying "Calculating…", the walk runs on a thread that touches no view, and the answer comes back through
`-cg_setMeasuredBytes:…` on the main thread. A rename or a navigation that lands first makes the answer about an old
subject, and it is dropped.

**AND THE COLUMN VIEW'S PREVIEW PANE ASKS THE SAME QUESTION.** Its size line used to read "--" for a directory — the
pane's own admission that it had not measured one. It now says "Calculating…" while the walk is out (`WSItemInfo
+cg_measurePathsInBackground:target:selector:`, the same off-main-thread door the inspector uses, which keeps its target
alive until it answers) and takes the total when it lands; an answer that names a path the person has since left is
dropped. A file's line is still its own `stat`, because that is the whole of a file's size.

**AND THE PANE DRAWS WHAT IT ASKS FOR, IN ONE PLACE.** The regression this replaces is worth naming: the size was wired
into `-previewText`, the door a probe reads, and the DRAWING still called the shallow formatter for itself — so the pane
sat on "Calculating…" while the answer had arrived, been stored and been right, and the test passed because it read the
door. `-cg_lines` is now the pane's four lines and both the drawing and the door read that one list.

**THE PREVIEW IS THE PICTURE ITSELF.** A preview pane is not a grid cell: `WSItemIcons -cg_pictureForPath:box:` answers
the picture at its own shape — no square's transparent bands — decoded at the WINDOW's scale (`userSpaceScaleFactor`), so
the compositor is not stretching 128 pixels over 170, and the pane's body takes the picture's height, so the window grows
to fit a tall picture and stays short for a wide one instead of holding a white lake. A file this tier cannot decode keeps
its icon, which is square.

**NAMED ABSENCES.** `Shared folder` is drawn and disabled: sharing is W12's and a tick that nothing honoured would lie.
There is no tag field (tags are not in the metadata store), no "Hide extension" (that is a Finder flag this substrate does
not have), no `Open With` (F1) and no custom icon (F2). **A fact the file system has no answer for is a row the window does not show** — this substrate records no birth
time, so there is no Created row here at all, and the rows under it move up while the window gets 17 points shorter;
a file system that does report one gets the row back with no second code path. There are no ACLs to list, so the permissions table has no +/- and no gear. The inspector's own rename is not
undoable: its `WSFileOperations` has no undo manager, because the window outlives the one that opened it and an undo entry
pointing at a dead window's manager would be worse than none.

`tests/get_info.m` is the proof: the facts for a file and for a folder, a selection's summed bytes and its blank mixed
values, the three Locked states, the size and privilege strings, the window's six sections and their fields, the registry
reusing one window, and the three writes checked **on the disk** — the rename, the mode bit, and the comment surviving a
rename.

### Printing: the listing, and the launch's own door

**A FILE MANAGER PRINTS WHAT IT SHOWS.** Printing a document's contents needs the application that owns it, and this
tree has no Apple Event transport to hand a file to one; what Workspace can print — and what the reference file
manager prints for a window — is a **listing**: a title and one row per item with its kind, size and modification date.
`WSPrintView` builds those rows once from the file system (the kind is `WSItemKind`'s, the same registry the list view
uses) and lets the AppKit's paginator cut the tall view by the ticket's imageable height, so two hundred items need no
arithmetic here — only a row height.

**AND THE MENU ROW IS THE LAUNCH DOOR'S FIRST REAL CALLER.** `File > Print…` (⌘P) sends `-printSelection:` to the file
window: the selection when there is one, the whole folder otherwise. That hands the paths to
`-[NSApplication application:printFiles:]`, the launch's own door, which asks the delegate —
`WSApplication -application:printFiles:withSettings:showPrintPanels:` — and that reaches `WSPrintService`, which prints
one listing per file with the reply the launch turns into its open-or-print answer. One printing path, reached from
both ends.

**NOTHING A PROBE DOES TOUCHES A PRINTER.** A print request carries a settings dictionary, so the probe asks for a
`NSPrintPreviewJob` or a `NSPrintSaveJob` and asserts the pages; the window's verb is measured through NSApplication
with a recording delegate. A probe that printed paper would be a probe nobody could run twice.

`tests/printing.m` is the proof: the rows and their arithmetic, a three-row page and a hundred-row three-page listing,
the ink on page one, the service's preview/save/cancel replies, the application's delegate door, and the verb's paths
arriving at the launch door — **24 checks**.

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
  WSMainMenu.m             the menu bar's contents: the application menu and the six beside it
  WSMenuBarClock.m         the clock: an NSStatusItem, its view, and the width the server packs
  WSDesktopWindow.m        the borderless window at kCGDesktopIconWindowLevel, the size of the screen
  WSDesktopView.m          the desktop's icons — selection, rubber band, drag, double-click open
  WSFileWindowController.m the file window: toolbar, sidebar, path bar, status bar and view switcher
  WSIconView.m             the icon view: grid, keyboard, type-select, rename, drag and drop, spring-loading
  WSHistory.m              Back/Forward: the stack, the cursor and the truncation
  WSIconLayout.m           the grid, the snap, the arrange order and the hit test — pure geometry
  WSItemIcons.m            Icon Services' CGImage as an NSImage
  WSItemModel.m            one directory's items, the one model every view reads
  WSItemKind.m             the Kind column's Launch Services answer, with a readable fallback
  WSItemSort.m             directories-first, natural-name, date, size and Kind ordering
  WSListView.m             W4's list: columns, disclosure, sorting, rename
  WSColumnView.m           W5's columns: the NSBrowser and the preview panel
  WSFileOperations.m       W6's operations, conflict/progress handlers, undo and ZIP
  WSTrash.m                recycle, Put Back records, empty and the per-volume rule
  WSProgressWindow.m       the progress window the operations feed
  WSConflictSheet.m        the Replace/Skip/Keep Both/Cancel question (a modal panel)
  WSMetadataStore.m        the per-folder `.agora` sidecar: icon positions, the icon size and the comments
  WSItemInfo.m             one item's — or a selection's — facts, and the sentences an inspector reads out of them
  WSGetInfoWindowController.m  Get Info: six collapsible sections, a rename, the Locked bit and the comment
  WSPlaces.m               the sidebar's PLACES and DEVICES, and the desktop path
Info.plist.in              the bundle's Info.plist
Resources/Workspace.icns   the bundle's icon: the vendored theme's Home folder art, packed at five sizes (PROVENANCE.md)
tests/                     the pixel suite (run-desktop.sh + check.py) and twelve offscreen suites
```

## What is deliberately not here yet

**The Dock draws Workspace from `Resources/Workspace.icns`**, which is the **Home folder** of the vendored
Flat-Remix-Accent theme — chosen rather than inherited, because Workspace is the desktop and the door to the user's
files. It is derived art, packed with the recipe in [`PROVENANCE.md`](PROVENANCE.md); the bundle declares it with
`CFBundleIconFile`, so the icon is read the way the Mac reads one and the Dock needs no special case for its own file
manager.

The plan's later stages: the system-wide drag session (W7), Quick Look (W9), search
(W10), volumes (W11), network shares (W12) and the shell integration (W13). Get Info (W8) is here, with the absences
named in its own section below. Their substrate — Launch Services, Icon
Services and the change stream — is already built (`../libagora-launchservices`, `../libagora-iconservices`,
`../libagora-watch`).

**What W6 does not do yet, named:** there is no Trash WINDOW and no Dock contract, so `WSTrash` is exercised
through its API and the Dock's Trash icon remains W7/§5.3; the conflict question is a MODAL PANEL rather than a
sheet, because `WSConflictSheet` was built before the tier had `NSPanel`/`NSAlert` and has not moved to them; the
progress window has no Cancel; Compress writes a ZIP without ZIP64; and a multi-item move that fails halfway can leave
the items it already moved (the conflict sheet is per destination, not a rollback). **A package has no "Show Package
Contents"** — making an application bundle opaque is the right default, and the escape hatch into its `Contents` is
the path bar (type the folder) or a terminal, not a menu row this tier has not built. The preview is still a fixed
panel rather than a browser column (W9 for its content); the icon view's
alias is a symbolic link until `WSAlias`; a document's icon is its TYPE's generic; and the sidecar does not yet hold grid
spacing or label placement.

**EVERY SURFACE IS LIVE NOW.** `libagora-watch`'s stream drives a `WSDirectoryWatcher` for each file window and for the
desktop: the kernel's reader thread raises a flag, a 0.1 s main-thread timer takes it, and the view re-reads its folder —
keeping the selection by path, and waiting for the end of a drag, a band or a rename before it moves anything. Before
that, a folder made in a terminal never appeared, and neither did one made by the window's own New Folder: `WSItemModel`
caches its directory and `-refresh` never re-read it, so the only way to see either was to navigate away and back.

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

Workspace installs its bundle into the same prefix:

```sh
cmake --install build      # -> <prefix>/libexec/Workspace.app
```

`install` is not a directory copy: the executable is laid into the bundle's own slot
(`Contents/<platform>/<arch>/`) beside the `Info.plist` and `Resources/Workspace.icns`, and CMake **rewrites its
runpath** from the build tree's to the prefix's library directory — which is why the installed bundle does not carry
build-tree paths. The destination is `libexec` rather than `bin` because a bundle is not a `$PATH` program: it is
started by `libagora-launchservices` from the bundle it reads.

**A dependency's dependency is resolved without any environment.** A runpath is not inherited, so the libraries a
library needs are looked up through THAT library's path — and every Agora library now installs with `$ORIGIN`,
which is the directory they all land in. The installed bundle starts with `LD_LIBRARY_PATH` unset; that was not
true before, and it is the difference between an install and a staging area.

**And a packager's runpath wins.** `CMAKE_INSTALL_RPATH` is consulted rather than overridden: when a distribution
configures the install with an empty (or its own) value, that is what the executable gets, because a staged tree is
read with `ldd` before the prefix exists and an absolute configure-time `libdir` in the RUNPATH makes `ldd` resolve
the HOST's libraries instead.

## Licence

MIT — see [`LICENSE`](LICENSE).
