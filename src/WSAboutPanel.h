/*
 * WSAboutPanel.h — the panel "About Workspace" opens.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Portions of this file may derive from GNUstep; see THIRD-PARTY.md.
 *
 * WHY THIS IS WORKSPACE'S AND NOT THE APPKIT'S. `-[NSApplication orderFrontStandardAboutPanel:]` is a NAMED REFUSAL
 * in this tree — "a panel AND text drawing, neither of which this tier has" — and the first half of that is no
 * longer true: the AppKit now has `NSWindow`, a view that draws text and Icon Services to make the icon. So the
 * panel is an application's to build, which is where the reference file manager's About box lives too. What is NOT here is the
 * AppKit's standard panel, with its options dictionary, its credits and its `NSPanel` behaviour; this is the small
 * honest one, and the day a second application wants one is the day it moves into the AppKit.
 */
#ifndef WORKSPACE_WSABOUTPANEL_H
#define WORKSPACE_WSABOUTPANEL_H

#import <Foundation/NSObject.h>

@interface WSAboutPanel : NSObject

/* Make the panel on the first call, then centre it and bring it to the front. The panel is KEPT — a person opens
 * About twice and expects the same window back rather than two. */
+ (void)orderFront;

@end

#endif /* WORKSPACE_WSABOUTPANEL_H */
