/*
 * WSDesktopWindow.h — the one window that is the desktop.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
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

/* The icons' size, forwarded to the view. A preference arrives at the APPLICATION, which holds this window and not
 * the view inside it, so the door belongs here rather than making every caller reach past it. */
- (NSInteger)iconSize;
- (void)setIconSize:(NSInteger)size;
@end

#endif /* WORKSPACE_WSDESKTOPWINDOW_H */
