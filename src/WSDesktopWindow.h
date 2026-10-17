/*
 * WSDesktopWindow.h — the one window that is the desktop.
 *
 * Copyright © 2026 Kyle J. Cardoza. MIT licensed — see LICENSE.
 * SPDX-License-Identifier: MIT
 */
#ifndef WORKSPACE_WSDESKTOPWINDOW_H
#define WORKSPACE_WSDESKTOPWINDOW_H

#import <AppKit/NSWindow.h>

@class NSScreen;
@class NSString;

/* A borderless window at the desktop level, as big as the screen, drawing the wallpaper and the icons of
 * `directory`. */
@interface WSDesktopWindow : NSWindow
- (instancetype)initWithScreen:(NSScreen *)screen directory:(NSString *)directory;
@end

#endif /* WORKSPACE_WSDESKTOPWINDOW_H */
