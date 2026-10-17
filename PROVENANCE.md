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
desktop is a client, as the Finder is on the Mac, so the ramp is a view in an application.

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

**Icon positions are TOP-LEFT SCREEN COORDINATES**, the Finder's own convention and what the store persists;
Cocoa's bottom-left appears only in the view's drawing and hit-testing, converted in one place.

**An icon is an `IconRef` from `libagora-iconservices` (F2), cached per item.** `AGIconCreateWithURL` already
prefers an application bundle's declared icon and falls back to the type's generic; a document's own icon is a
later step. And the desktop is **not LIVE yet**: `libagora-watch` (F3) is built, and wiring its stream to
`WSItemModel` is the step after this surface.

## The desktop is two levels

**The desktop is TWO LEVELS, and this is the change that made the icon window TRANSPARENT.**
`kCGDesktopWindowLevel` is the WALLPAPER — a window of its own, the Dock's to draw — and
`kCGDesktopIconWindowLevel` is the icons, which are Workspace's. Making a window transparent needed the AppKit to
carry an ALPHA channel it did not have: `AGWindowSetTransparent` in the seam (ARGB8888 buffers, which the
compositor already BLENDED source-over) and `NSWindow`'s backing store switching to
`kCGImageAlphaPremultipliedFirst` when `-setOpaque:NO`. See `../libagora-app/PROVENANCE.md`.

## Licence per file

Every file is MIT. There is no third-party code in this component, so there is no per-file licence split to
record.
