/*
 * WSDesktopWindow.m — the desktop window: borderless, at the desktop level, as big as the screen.
 *
 * Copyright © 2026 Kyle J. Cardoza. MIT licensed — see LICENSE.
 * SPDX-License-Identifier: MIT
 *
 * **THE DESKTOP IS TWO LEVELS, AND THIS IS THE UPPER ONE.** The wallpaper is a window at
 * `kCGDesktopWindowLevel` — BELOW every ordinary window, and eventually the Dock's to draw; this window is at
 * `kCGDesktopIconWindowLevel`, one above it, and draws only the ICONS. It is **TRANSPARENT**, so the wallpaper
 * shows through everywhere there is no icon, which is what the compositor's source-over blend is for. Both
 * levels come from libagora-drawing's `CGWindowLevel.h`, which is why that vocabulary had to exist first.
 *
 * IT SPANS `[NSScreen frame]` AND NOT `visibleFrame`, which is deliberate: the desktop is what the menu bar
 * and the Dock are drawn OVER, so sizing it to the work area would leave the wallpaper missing under their
 * translucent parts. Whether the SERVER's own menu-bar strip is currently above or below this window is a
 * separate question with a recorded answer — `window-server/src/output.c` draws the strip first and says "the
 * level is the next step"; until the strip has one, a full-screen window at any level covers it, and this one
 * does. That is a menubar task, not the desktop's, and the desktop suite measures it rather than assuming it
 * away.
 *
 * IT IS NOT A NORMAL WINDOW: borderless, never key and never main, so it takes no keyboard focus and does not
 * appear in the window menu. The buttons, the shadow and the cycle are a window manager's business.
 */
#import "WSDesktopWindow.h"

#import "WSDesktopView.h"

#import <AppKit/NSScreen.h>
#import <CoreGraphics/CGWindowLevel.h>

@implementation WSDesktopWindow

- (instancetype)initWithScreen:(NSScreen *)screen directory:(NSString *)directory
{
	NSRect frame = (screen != nil) ? [screen frame] : NSMakeRect(0.0, 0.0, 1280.0, 720.0);
	WSDesktopView *view;

	self = [super initWithContentRect:frame
				styleMask:NSBorderlessWindowMask
				  backing:NSBackingStoreBuffered
				    defer:NO];
	if (self == nil) {
		return nil;
	}

	/* **THE ICON LEVEL, ONE ABOVE THE WALLPAPER'S.** The wallpaper is a window at `kCGDesktopWindowLevel` (the
	 * Dock's, eventually); this is the layer of icons ON it. */
	[self setLevel:kCGDesktopIconWindowLevel];
	/* **TRANSPARENT**: the wallpaper shows through everywhere there is no icon. */
	[self setOpaque:NO];
	[self setHasShadow:NO];
	[self setTitle:@"Desktop"];

	view = [[WSDesktopView alloc] initWithFrame:NSMakeRect(0.0, 0.0, frame.size.width, frame.size.height)
					  directory:directory];
	[self setContentView:view];
	[view release];

	return self;
}

/* NEITHER KEY NOR MAIN, so a click on the desktop cannot take the keyboard from an application and the
 * desktop never joins the window menu. */
- (BOOL)canBecomeKeyWindow
{
	return NO;
}

- (BOOL)canBecomeMainWindow
{
	return NO;
}

- (NSInteger)iconSize
{
	return [(WSDesktopView *)[self contentView] iconSize];
}

- (void)setIconSize:(NSInteger)size
{
	[(WSDesktopView *)[self contentView] setIconSize:size];
}

@end
