/*
 * WSPreferencesWindow.h — the window "Preferences…" opens.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Portions of this file may derive from GNUstep; see THIRD-PARTY.md.
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
@end

@interface WSPreferencesWindow : NSObject
{
	NSWindow *_window;
	id <WSPreferencesWindowTarget> _target;	/* NOT retained: the application that applies the change */
	NSSlider *_slider;
	NSTextField *_valueLabel;
	NSInteger _iconSize;
}

/* `target` is sent `-preferencesWindow:didChangeIconSize:` when the slider moves. It is NOT retained. */
- (instancetype)initWithTarget:(id <WSPreferencesWindowTarget>)target
		      iconSize:(NSInteger)iconSize
		     directory:(NSString *)directory;

- (void)orderFront;

/* The size the slider currently shows, so a caller can assert what a drag would hand over. */
- (NSInteger)iconSize;

@end

#endif /* WORKSPACE_WSPREFERENCESWINDOW_H */
