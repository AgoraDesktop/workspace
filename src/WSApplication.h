/*
 * WSApplication.h — the application object that owns the desktop.
 *
 * Copyright © 2026 Kyle J. Cardoza. MIT licensed — see LICENSE.
 * SPDX-License-Identifier: MIT
 *
 * WHY THIS IS NOT AN `NSApplication` SUBCLASS, which the plan's structure sketched. THIS TREE'S
 * `+[NSApplication sharedApplication]` allocates an `NSApplication` ITSELF — `s_shared = [[NSApplication alloc]
 * init]` — so calling it on a subclass would answer an `NSApplication` and a subclass of it would never be the
 * application. Rather than fight that, this is a CONTROLLER that owns the application's own object (the
 * desktop) and drives the `NSApplication` the entry point makes. On the Mac the Finder is likewise not an
 * `NSApplication` subclass; it is an application that owns a desktop and windows.
 */
#ifndef WORKSPACE_WSAPPLICATION_H
#define WORKSPACE_WSAPPLICATION_H

#import <Foundation/NSObject.h>

/* **THE PROTOCOL'S OWN HEADER, BECAUSE A FORWARD DECLARATION IS NOT A CONFORMANCE.** `@protocol X;` is enough to
 * NAME a protocol but not to ADOPT it — MEASURED, clang warns "cannot find protocol definition for
 * 'WSPreferencesWindowTarget'" at the `@interface` line below. The header is one small window's and pulls in
 * nothing but Foundation, so importing it here is the whole fix. */
#import "WSPreferencesWindow.h"

@class WSDesktopWindow;

@interface WSApplication : NSObject <WSPreferencesWindowTarget>
{
	WSDesktopWindow *_desktop;
	WSPreferencesWindow *_preferences;
}

/* Create the desktop window and put it on the screen. NO if it could not be made. */
- (BOOL)start;

/* Pump events for `seconds`. W0 runs for a length of time because it has nothing to be told yet: a desktop is
 * a thing that stays. Later stages replace this with the ordinary run loop and a delegate. */
- (void)runForSeconds:(double)seconds;

- (void)stop;

/* **THE TWO APPLICATION-MENU ROWS WHOSE MECHANISM IS THE APPLICATION'S.** `-orderFrontStandardAboutPanel:` is a
 * NAMED REFUSAL in this tree and there is no preferences panel at all, so those two rows are the target's to
 * answer — and the target is this object, which is what `WSMainMenu` is handed. */
- (void)orderFrontAboutPanel:(id)sender;
- (void)showPreferences:(id)sender;

/* `WSPreferencesWindow`'s answer to a moved slider: apply the size and let the desktop re-lay out. */
- (void)preferencesWindow:(id)window didChangeIconSize:(NSInteger)size;

@end

#endif /* WORKSPACE_WSAPPLICATION_H */
