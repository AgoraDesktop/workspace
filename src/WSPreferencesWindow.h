/*
 * WSPreferencesWindow.h — the window "Preferences…" opens.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **IT SHOWS THE PREFERENCES THAT EXIST AND INVENTS NONE.** Workspace has exactly two settings today: WHICH
 * directory is the desktop (set by `AGORA_DESKTOP`, or `~/Desktop`) and HOW BIG its icons are (kept in the folder's
 * `.agora` sidecar, which is the same value a drag writes and the same one the desktop reads back). So the window
 * has a row that CHANGES one of them and a row that STATES the other, rather than a page of controls wired to
 * nothing. A preferences system — domains, defaults, a plist in `~/Library` — is W13's; until it exists, the icon
 * size is a real preference and this is where a person changes it.
 */
#ifndef WORKSPACE_WSPREFERENCESWINDOW_H
#define WORKSPACE_WSPREFERENCESWINDOW_H

#import <Foundation/NSObject.h>
#import <Foundation/NSGeometry.h>

@class NSSegmentedControl;
@class NSSlider;
@class NSTextField;
@class NSWindow;
@class WSPreferencesWindow;

/* **THE INFORMAL PROTOCOL THE TARGET IMPLEMENTS** — Apple's shape for a delegate with one message, and here it does
 * a second job: a bare `id` gives the compiler nothing to look a selector up in, and MEASURED, the call below
 * warned `instance method '-preferencesWindow:didChangeIconSize:' not found (return type defaults to 'id')`. Naming
 * the message is the whole fix. */
@protocol WSPreferencesWindowTarget <NSObject>
- (void)preferencesWindow:(WSPreferencesWindow *)window didChangeIconSize:(NSInteger)size;
/* **AND THE VIEW A NEW FILE WINDOW OPENS IN**: 0 Icon, 1 List, 2 Column. A preference about the NEXT window rather
 * than about the one on screen, which is why it is here and not in a window's View menu. */
- (void)preferencesWindow:(WSPreferencesWindow *)window didChangeViewMode:(NSInteger)mode;
@end

@interface WSPreferencesWindow : NSObject
{
	NSWindow *_window;
	id <WSPreferencesWindowTarget> _target;	/* NOT retained: the application that applies the change */
	NSSlider *_slider;
	NSTextField *_valueLabel;
	NSSegmentedControl *_viewModeControl;	/* RETAINED: Icon / List / Column */
	NSInteger _iconSize;
	NSInteger _viewMode;
}

/* `target` is sent `-preferencesWindow:didChangeIconSize:` when the slider moves and
 * `-preferencesWindow:didChangeViewMode:` when a view is chosen. It is NOT retained. */
- (instancetype)initWithTarget:(id <WSPreferencesWindowTarget>)target
		      iconSize:(NSInteger)iconSize
		     directory:(NSString *)directory
		      viewMode:(NSInteger)viewMode;

- (void)orderFront;

/* The size the slider currently shows, so a caller can assert what a drag would hand over. */
- (NSInteger)iconSize;

/* **THE VIEW SWITCH AS THE WINDOW SHOWS IT**, and the switch itself: a probe can set a segment and send the action the
 * way a click does, which is the only way to measure that choosing one reaches the target. */
- (NSInteger)viewMode;
- (nullable NSSegmentedControl *)cg_viewModeControl;

@end

#endif /* WORKSPACE_WSPREFERENCESWINDOW_H */
