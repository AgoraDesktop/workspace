/*
 * desktop_band.m — the rubber band on the DESKTOP itself.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 *
 * **THE DESKTOP COMPUTED THIS BAND AND NEVER DREW IT.** `WSDesktopView` has taken a press in the empty space, tracked the
 * rectangle and selected what it touched since the gesture was written — and `-drawRect:` had no idea it existed, so the
 * one gesture a desktop is used for left no trace on the screen: icons appeared selected out of nowhere when the button
 * came up. The file window's icon view had no band at all, which is the same bug with a different history.
 *
 * **WHAT IS MEASURED, AND WHY THE PAINT MATTERS MORE THAN THE RECTANGLE.** The rectangle is arithmetic a probe could
 * have believed without drawing; the complaint was that nothing appeared. So the view is painted into a bitmap over a
 * known colour and the band's two colours are sampled out of it: the accent wash inside it, a darker shade of the same
 * accent on its edge, and untouched background outside. Then the selection is asked for, because a band that paints and
 * selects nothing is the other half of the same lie.
 */
#import <AppKit/AppKit.h>

#import "WSDesktopView.h"
#import "WSSelectionBand.h"

#include <math.h>
#include <stdio.h>
#include <unistd.h>

static int s_failed;

static void check(int ok, const char *what)
{
	printf("  %s   %s\n", ok ? "ok  " : "FAIL", what);
	if (!ok) {
		s_failed++;
	}
}

/* A VIEW PAINTED INTO A BITMAP over a colour the probe chose, so "the band" and "nothing" are different pixels. */
static NSBitmapImageRep *draw_view(NSView *view, int width, int height)
{
	NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:width
		pixelsHigh:height bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
		colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:width * 4 bitsPerPixel:32];

	[NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
	[[NSColor whiteColor] setFill];
	[[NSBezierPath bezierPathWithRect:NSMakeRect(0.0, 0.0, (CGFloat)width, (CGFloat)height)] fill];
	[view drawRect:[view bounds]];
	return rep;
}

static NSEvent *mouse(NSEventType type, NSPoint windowPoint, NSUInteger flags)
{
	return [NSEvent mouseEventWithType:type location:windowPoint modifierFlags:flags
				 timestamp:0.0 windowNumber:0 context:nil
				 eventNumber:0 clickCount:1 pressure:1.0f];
}

static BOOL near(double a, double b)
{
	return a > b - 0.01 && a < b + 0.01;
}

/* The band's rectangle in the view's own TOP-LEFT space, which is the space a desktop press is measured in. */
@interface WSDesktopView (AGBandProbe)
- (NSRect)cg_bandRect;
- (NSArray *)cg_selection;
- (NSArray *)cg_positions;
@end

int main(void)
{
	NSString *root = [@"/tmp" stringByAppendingPathComponent:
		[NSString stringWithFormat:@"agora-desktop-band-%d", (int)getpid()]];
	NSFileManager *fm = [NSFileManager defaultManager];
	WSDesktopView *view;
	NSWindow *window;
	NSPoint start;		/* top-left space, which is what the view's own press uses */
	NSPoint end;
	NSRect band;
	NSBitmapImageRep *rep;

	setvbuf(stdout, NULL, _IONBF, 0);
	[NSApplication sharedApplication];
	[fm removeItemAtPath:root error:NULL];
	[fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL];
	[fm createFileAtPath:[root stringByAppendingPathComponent:@"one.txt"] contents:[NSData data] attributes:nil];
	[fm createFileAtPath:[root stringByAppendingPathComponent:@"two.txt"] contents:[NSData data] attributes:nil];
	[fm createFileAtPath:[root stringByAppendingPathComponent:@"three.txt"] contents:[NSData data] attributes:nil];

	view = [[WSDesktopView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 600.0, 400.0) directory:root];
	window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0.0, 0.0, 600.0, 400.0)
					     styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
	[window setContentView:view];

	printf("desktop_band: the selection band on the desktop\n");

	/* 1. **A PRESS BETWEEN ICONS BEGINS A BAND.** The desktop fills COLUMNS FROM THE RIGHT of its usable area, so where
	 * the first icon is depends on the size of the view — the view is asked rather than guessed, and the band is drawn
	 * from just above and left of that icon, which is empty space and touches the one icon it is aimed at. */
	{
		NSArray *positions = [view cg_positions];
		NSPoint first = (positions != nil && [positions count] > 0)
			? [[positions objectAtIndex:0] pointValue] : NSMakePoint(400.0, 40.0);

		start = NSMakePoint(first.x - 14.0, first.y - 6.0);
		end = NSMakePoint(first.x + 30.0, first.y + 30.0);
	}
	{
		/* The view is not flipped: a top-left point is converted into the window's own space before it is handed to the
		 * event, which is what the view's `-topLeftPointForEvent:` undoes. */
		NSRect bounds = [view bounds];
		NSPoint startWindow = NSMakePoint(start.x, bounds.size.height - start.y);
		NSPoint endWindow = NSMakePoint(end.x, bounds.size.height - end.y);

		[view mouseDown:mouse(NSLeftMouseDown, startWindow, 0)];
		[view mouseDragged:mouse(NSLeftMouseDragged, endWindow, 0)];
	}
	band = [view cg_bandRect];
	check(near(NSMinX(band), start.x) && near(NSMinY(band), start.y)
	      && near(NSWidth(band), 44.0) && near(NSHeight(band), 36.0),
	      "the band is the rectangle between the press and the pointer, in the desktop's top-left space");

	/* 2. **AND IT IS ON THE SCREEN WHILE THE DRAG IS HAPPENING.** This is the half that was missing: the pixels. The
	 * view is unflipped, so the band's TOP-LEFT y becomes the bitmap's `height - y`. */
	rep = draw_view(view, 600, 400);
	{
		/* **INSIDE THE BAND AND CLEAR OF THE ICON**, because the band is a wash: over a hint's dark artwork the accent
		 * tints it rather than replacing it, and the claim is about the band's own colour over the desktop. */
		NSPoint middle = NSMakePoint(NSMinX(band) + 6.0, NSMidY(band));
		/* **THE BITMAP'S y IS THE BAND'S OWN**, which is the desktop's top-left space: a rep is read from its first row,
		 * so the sample needs no mirroring even though the view is unflipped drawing into it. */
		NSColor *inside = [rep colorAtX:(NSInteger)middle.x y:(NSInteger)middle.y];
		NSColor *edge = [rep colorAtX:(NSInteger)NSMinX(band) y:(NSInteger)middle.y];
		NSColor *outside = [rep colorAtX:5 y:5];

		/* **THE FILL IS THE ACCENT AT ITS STATED ALPHA OVER WHAT IS BENEATH** — not "a blue something". The expectation
		 * is computed from `+cg_accentColor` and `WSSelectionBandFillAlpha`, so a hue change or a different alpha shows
		 * up here rather than in a screenshot. */
		{
			NSColor *accent = [[NSColor cg_accentColor] colorUsingColorSpaceName:NSCalibratedRGBColorSpace];

			if (accent == nil) {
				accent = [NSColor cg_accentColor];	/* already an RGB colour; the conversion refuses its own space */
			}
			CGFloat alpha = WSSelectionBandFillAlpha;
			CGFloat r = alpha * [accent redComponent] + (1.0 - alpha);
			CGFloat g = alpha * [accent greenComponent] + (1.0 - alpha);
			CGFloat b = alpha * [accent blueComponent] + (1.0 - alpha);

			check(inside != nil && near([inside redComponent], r) && near([inside greenComponent], g)
			      && near([inside blueComponent], b),
			      "the band's interior is the accent at its stated alpha over the desktop");
		}
		check(inside != nil && [inside redComponent] < 0.999,
		      "and it is SEMITRANSPARENT, so what is under it still shows");
		check(edge != nil && [edge blueComponent] < [inside blueComponent] - 0.2,
		      "its border is a darker shade of that same accent");
		check(outside != nil && [outside redComponent] > 0.999 && [outside blueComponent] > 0.999,
		      "and away from the band the desktop is untouched");
	}

	/* 3. **LETTING GO TAKES WHAT IT TOUCHED, AND THE BAND GOES.** On the desktop the selection is applied at the release
	 * (which is the rule the file window's icon view now follows too), so the wash is not repainted under a hand that is
	 * still moving. */
	{
		NSRect bounds = [view bounds];
		NSPoint endWindow = NSMakePoint(end.x, bounds.size.height - end.y);

		check([[view cg_selection] count] == 0, "nothing is selected while the band is still being dragged");
		[view mouseUp:mouse(NSLeftMouseUp, endWindow, 0)];
	}
	check([[view cg_selection] count] > 0, "letting go selects the items the band touched");
	check(NSEqualRects([view cg_bandRect], NSZeroRect), "and the band is gone");
	{
		/* AND THE PAINT AGREES: with no band, the pixel that was washed is the desktop again — the band's own empty part,
		 * which the selected icon does not cover. */
		NSBitmapImageRep *after = draw_view(view, 600, 400);
		NSColor *pixel = [after colorAtX:(NSInteger)NSMinX(band) + 6 y:(NSInteger)NSMidY(band)];

		check(pixel != nil && [pixel redComponent] > 0.999 && [pixel blueComponent] > 0.999,
		      "a point away from any selected icon is clear again");
	}

	printf(s_failed == 0 ? "desktop_band: all checks passed\n" : "desktop_band: FAILURES\n");
	[fm removeItemAtPath:root error:NULL];
	[view release];
	[window release];
	return s_failed == 0 ? 0 : 1;
}
