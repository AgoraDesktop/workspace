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
 * desktop) and drives the `NSApplication` the entry point makes. On the Mac the system file manager is likewise not an
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
@class WSFileWindowController;
@class NSMutableArray;

@interface WSApplication : NSObject <WSPreferencesWindowTarget>
{
	WSDesktopWindow *_desktop;
	WSPreferencesWindow *_preferences;
	NSMutableArray *_fileWindows;		/* RETAINED: WSFileWindowController */
	BOOL _showsAboutOnStart;
	BOOL _showsFileWindowOnStart;
}

/* Create the desktop window and put it on the screen. NO if it could not be made. */
- (BOOL)start;

/* Run the ordinary application loop for `seconds`. **THE LOOP IS THE APPKIT'S NOW, NOT A PUMP OF W0'S OWN**, and
 * that is load-bearing rather than tidy: a menu opened from the bar is driven by `NSMenuView`'s own loop, which
 * fetches events only while `-[NSApplication isRunning]` — so an application that pumps by hand gets a menu that is
 * begun and never handled. The deadline rides the loop's per-pass `-applicationDidUpdate:`. Later stages replace
 * only the DEADLINE: a desktop is a thing that stays, and the suite is what needs it to be able to leave. */
/* **OPEN THE ABOUT PANEL AS PART OF STARTING UP**, which is what `--show-about` is for: the panel is otherwise
 * reached by a menu action, and that needs a click. Set before `-start`. */
- (void)setShowsAboutOnStart:(BOOL)flag;

/* **A FILE WINDOW AS PART OF STARTING UP**, which is `--file-window`'s door and the way a probe sees the shell
 * without clicking a menu. The window is otherwise reached by File > New Workspace Window. */
- (void)setShowsFileWindowOnStart:(BOOL)flag;

/* THE FILE MENU'S NEW-WINDOW ROW. It is the application's, because a second window is the application's to own,
 * and every window keeps its own model, history and path bar. */
- (void)newWorkspaceWindow:(id)sender;

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
