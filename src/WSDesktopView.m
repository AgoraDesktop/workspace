/*
 * WSDesktopView.m — the wallpaper.
 *
 * Copyright © 2026 Kyle J. Cardoza. MIT licensed — see LICENSE.
 * SPDX-License-Identifier: MIT
 *
 * THE WALLPAPER IS THE DESKTOP'S NOW, NOT THE SERVER'S. `window-server/ARGENTUM.md` records that the server
 * fills `#A8DED9` by request and that "a vertical ramp is still the honest next step"; this is that ramp, and
 * it belongs here because the desktop is a CLIENT of the window server — the same relationship the Finder has
 * to the WindowServer on the Mac — so once Workspace runs, the server's fill is only seen before the desktop
 * window maps or if Workspace dies.
 *
 * THE TWO ENDPOINTS ARE ARGENTUM'S OWN SAMPLES, not chosen here: the warm amber at the top of the mockup,
 * `(108,55,29)`, and the near-black at its bottom corners, `(18,14,5)`. A ramp is drawn as BANDS rather than a
 * Core Graphics gradient because a band is a rectangle and the AppKit already fills rectangles; the band count
 * is high enough that the seams do not show and low enough to be a rung loop.
 */
#import "WSDesktopView.h"

#import <AppKit/NSBezierPath.h>
#import <AppKit/NSColor.h>

#define WALLPAPER_TOP_R		108.0
#define WALLPAPER_TOP_G		 55.0
#define WALLPAPER_TOP_B		 29.0
#define WALLPAPER_BOTTOM_R	 18.0
#define WALLPAPER_BOTTOM_G	 14.0
#define WALLPAPER_BOTTOM_B	  5.0

/* In SCREEN terms, band 0 is the TOP. A view's own coordinates have y growing UP, so the conversion happens
 * once, below, the same way `appkit_window`'s smoke view does it. */
#define WALLPAPER_BANDS		 64

@implementation WSDesktopView

- (BOOL)isOpaque
{
	return YES;
}

- (void)drawRect:(NSRect)dirtyRect
{
	NSRect bounds = [self bounds];
	CGFloat width = bounds.size.width;
	CGFloat height = bounds.size.height;
	CGFloat band = height / (CGFloat)WALLPAPER_BANDS;
	int i;

	(void)dirtyRect;
	for (i = 0; i < WALLPAPER_BANDS; i++) {
		CGFloat t = (CGFloat)i / (CGFloat)(WALLPAPER_BANDS - 1);
		CGFloat red = (WALLPAPER_TOP_R + (WALLPAPER_BOTTOM_R - WALLPAPER_TOP_R) * t) / 255.0;
		CGFloat green = (WALLPAPER_TOP_G + (WALLPAPER_BOTTOM_G - WALLPAPER_TOP_G) * t) / 255.0;
		CGFloat blue = (WALLPAPER_TOP_B + (WALLPAPER_BOTTOM_B - WALLPAPER_TOP_B) * t) / 255.0;
		NSRect rect = NSMakeRect(0.0, height - (CGFloat)(i + 1) * band, width, band + 1.0);

		[[NSColor colorWithCalibratedRed:red green:green blue:blue alpha:1.0] setFill];
		[[NSBezierPath bezierPathWithRect:rect] fill];
	}
}

@end
