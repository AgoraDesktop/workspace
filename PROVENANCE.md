# Provenance

**First-party: written for Agora, not extracted from anywhere.** No upstream revision to pin and no
third-party code to licence.

| what | where |
|---|---|
| the AppKit | consumed as the built package `AgoraApp::App` (`../libagora-app`), which brings Foundation, Core Graphics, Core Text and the Objective-C runtime on its interface |
| the window levels | `libagora-drawing`'s `CGWindowLevel.h` (`kCGDesktopWindowLevel`) |
| the wallpaper's endpoints | `window-server/ARGENTUM.md`'s own samples — `(108,55,29)` and `(18,14,5)` |
| the compositor it is a client of | `../window-server`, as `agora_shell` through the AppKit's seam |
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
later step. And the desktop is **not LIVE yet**: `libagora-watch` (F3) is built, and wiring its stream to
`WSItemModel` is the step after this surface.

**And the labels are centred GEOMETRICALLY, because the text system does not honour ALIGNMENT.** MEASURED, the
hard way: `-drawInRect:withAttributes:` never mentions alignment in `libagora-app/NSStringDrawing.m`, so a
paragraph style's `NSCenterTextAlignment` left the text exactly where it was. The view now measures the string
with `-sizeWithAttributes:` and hands `-drawInRect:` a rectangle of exactly that width, centred on the icon.

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

## W2 — the file window, and a drawing finding

**`WSFileWindowController`, `WSFileIconView`, `WSHistory`, `WSItemIcons` and `WSPlaces` are this repository's own
code.** The window is assembled from the AppKit's classes — `NSToolbar`/`NSToolbarItem`, `NSSplitView`, `NSOutlineView`,
`NSPathControl`, `NSSegmentedControl`, `NSTextField` and `NSWindowController` — and the model/history/places are
separate so each can be measured without the others.

**THE FINDING: A FLIPPED ROOT CONTENT VIEW IS PLACED AS IF IT WERE UNFLIPPED IN THE LIVE DRAWING PATH.**
`NSWindow -cg_drawContentInContext:` calls `[_contentView displayRect:]` directly, while the offscreen walk
(`fn_draw_view`) is the one that enters a root view's own coordinate system and mirrors a flipped one. MEASURED:
the first live screenshot put the path bar at the bottom and the status bar at the top; the frames were correct
for a flipped view, the DRAW was not. The window keeps an unflipped content view and lays the three strips out in
Cocoa's y-up space. This is an AppKit-side defect for the next time the view tree is touched; it is recorded here
rather than fixed by making the shell's layout depend on an accident.

**AND THE CONTENT VIEW'S STRIPS ARE THE SHELL'S, NOT A VIEW'S.** `-resizeSubviewsWithOldSize:` lays out the path bar
(24 points), the status bar (22) and the split view between them; `tests/file_window.m` checks those frames after a
700×400 resize, so the window is a shell that can be resized rather than one that only looks right at birth.

## Known gaps, recorded rather than left to be found

**THE ABOUT PANEL SHOWS A GENERIC FOLDER AS THE APPLICATION'S ICON.** `WSAboutPanel` asks Icon Services for the
bundle's icon with `AGIconCreateWithURL` on `[[NSBundle mainBundle] bundlePath]`, and the bundle IS a directory — so
Icon Services answers the folder it is looking at rather than an application. The drawing, the layout and the bundle
identity around it are all correct; only the picture is the wrong KIND. Deferred by request ("we can worry about
icons later"); the fix is on the Icon Services side, which needs a rule for a bundle: an `APPL` directory is an
application, and its icon is the application's.

## Licence per file

Every file is MIT. There is no third-party code in this component, so there is no per-file licence split to
record.
