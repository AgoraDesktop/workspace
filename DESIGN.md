# Design — W0

**This is the smallest honest Workspace and the shape the rest is added to.** W0 is the desktop window; the
file windows, the views and the file operations are later stages that hang off the same objects.

## Three objects

- **`WSApplication` is a CONTROLLER, not an `NSApplication` subclass.** This tree's
  `+[NSApplication sharedApplication]` allocates an `NSApplication` itself, so a subclass would never be the
  application object. `WSApplication` owns what is the application's — the desktop — and drives the
  `NSApplication` the entry point makes. On the Mac the Finder is likewise an application that owns a desktop,
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

Three objects, and the Finder **window's** views will be built from the same three:

- **`WSItemModel`** — one directory's items, and the one model every view reads.
- **`WSIconLayout`** — pure geometry: a **top-to-bottom, RIGHT-TO-LEFT** grid (macOS's own desktop order), the
  nearest-free snap a drop lands on, an arrange
  order, and a hit test. It needs no view, which is why it is checked offscreen.
- **`WSMetadataStore`** — the per-folder `.agora` sidecar: icon positions and the icon size.

**Two decisions.** Positions are **TOP-LEFT SCREEN COORDINATES** — the Finder's own convention, and what the
store persists — so the view converts to Cocoa only to draw and to hit-test; and the sidecar is **XML**, because
that is what this tree's `NSPropertyListSerialization` writes.

**And one gap named rather than implied:** the desktop is not LIVE yet. `libagora-watch` (F3) is built, but the
model reloads on demand instead of from a stream callback — that wiring is the step after this surface.

## What W0 found that it did not set out to find

**The server's menu-bar strip is below a full-screen window, and only a level fixes it.** `output.c` paints the
strip first — "until the strip has a LEVEL of its own such a window covers it. The level is the next step" —
so placing a full-screen window at *any* level, the desktop included, covers the bar. That is a menubar
task (`window-server`'s), and W0 records it here and measures it in `tests/check.py` rather than pretending
the top rows are something they are not.
