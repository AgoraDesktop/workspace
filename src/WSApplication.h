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

@class WSDesktopWindow;

@interface WSApplication : NSObject
{
	WSDesktopWindow *_desktop;
}

/* Create the desktop window and put it on the screen. NO if it could not be made. */
- (BOOL)start;

/* Pump events for `seconds`. W0 runs for a length of time because it has nothing to be told yet: a desktop is
 * a thing that stays. Later stages replace this with the ordinary run loop and a delegate. */
- (void)runForSeconds:(double)seconds;

- (void)stop;

@end

#endif /* WORKSPACE_WSAPPLICATION_H */
