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

- **The wallpaper is the desktop's, not the server's.** `ARGENTUM.md` records that the server fills `#A8DED9`
  "by request" and that "a vertical ramp is still the honest next step"; that ramp is now drawn here, because
  the desktop is a *client* of the window server — the Finder's relationship to the WindowServer on the Mac.
  The server's fill remains the thing seen before the desktop maps, or if it dies.
- **`[NSScreen frame]`, not `visibleFrame`.** The desktop is what the Dock and the menu bar are drawn over, so
  sizing it to the work area would leave the wallpaper missing under their translucent parts.
- **The bundle is a deliverable, not a packaging detail.** A program with an `Info.plist` beside it *is* a
  bundle, which is what the launch path and `libagora-launchservices` read, so the build lays out
  `Workspace.app/Contents/` rather than leaving a bare executable.

## W1 — the desktop's icons

Three objects, and the Finder **window's** views will be built from the same three:

- **`WSItemModel`** — one directory's items, and the one model every view reads.
- **`WSIconLayout`** — pure geometry: a column-major grid, the nearest-free snap a drop lands on, an arrange
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
