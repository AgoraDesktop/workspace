/*
 * menu_bar_clock — the menu bar's clock, CHECKED WITHOUT A COMPOSITOR.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **WHAT THIS CAN AND CANNOT SEE.** A status item is placed by the SERVER — that is the whole point of it having a
 * length and no position — so with no window server there is no item and no strip, and the desktop suite is where the
 * packing and the pixels are measured. What CAN be measured here is everything the application owns:
 *
 *   1. THE WIDTH ARITHMETIC. `NSVariableStatusItemLength` is resolved by asking the view how wide it is, so the width
 *      is a function of the string and the font — and this checks it is the MEASURED line plus the air either side,
 *      rounded up, rather than a number someone liked.
 *   2. THE INK. `-drawRect:` puts the time on the bar's own colour, inside its own padding: no ink at the item's
 *      edges, so the item reads as a piece of the bar and not as a box glued to it.
 *   3. THE CLOCK SAYS WHAT THE LOCALE SAYS. `NSDateFormatter` with the short time style is the answer, and a probe
 *      comparing against its own formatter is the only way to say that without writing `HH:mm` into the test.
 *   4. AN EMPTY BAR HAS NO ITEM, BUT STILL HAS A CLOCK. `-start` answers NO with no compositor, and the time it would
 *      have shown is still there — which is what makes this file able to test the clock at all.
 *
 * **AND WHAT IT DELIBERATELY DOES NOT DO IS SKIP.** A workstation can have `WAYLAND_DISPLAY` pointing at a live Agora
 * session, and an item made against it would really be placed in a real bar; this suite is about the process with NO
 * window server, so it says so by unsetting the variable before anything asks. A test that quietly became a different
 * test on a different machine is worse than one that fails.
 */
#import <AppKit/NSApplication.h>
#import <AppKit/NSAttributedString.h>
#import <AppKit/NSBezierPath.h>
#import <AppKit/NSBitmapImageRep.h>
#import <AppKit/NSColor.h>
#import <AppKit/NSFont.h>
#import <AppKit/NSGraphicsContext.h>
#import <AppKit/NSStringDrawing.h>
#import <AppKit/NSStatusItem.h>
#import <AppKit/NSView.h>
#import <AppKit/NSWindow.h>
#import <Foundation/Foundation.h>

#import "WSMenuBarClock.h"

#include <stdio.h>
#include <stdlib.h>

static int s_failed;

static void check(int ok, const char *name)
{
	printf("  %s   %s\n", ok ? "ok  " : "FAIL", name);
	if (!ok) {
		s_failed++;
	}
}

/* THE BAR'S FALLBACK FACE, which is what `+[NSWindow cg_menuBarColor]` answers with no server to ask — the sampled
 * 235,235,235 the strip is drawn in. */
#define BAR_RED 0.9215686

static NSBitmapImageRep *new_rep(int width, int height)
{
	return [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:width pixelsHigh:height
		bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
		colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:width * 4 bitsPerPixel:32];
}

/* DRAW A VIEW into a fresh rep over WHITE, so "the item painted its own background" and "the item painted nothing"
 * are different pixels rather than the same ones. */
static NSBitmapImageRep *draw_view(NSView *view, int width, int height)
{
	NSBitmapImageRep *rep = new_rep(width, height);

	[NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
	[[NSColor whiteColor] setFill];
	[[NSBezierPath bezierPathWithRect:NSMakeRect(0.0, 0.0, (CGFloat)width, (CGFloat)height)] fill];
	[view drawRect:[view bounds]];
	return rep;
}

/* DARK INK, counted against a threshold that is BELOW the bar's face and above nothing else in this view. The face is
 * 0.92, so 0.5 counts the glyphs and never the background. */
static int ink_in(NSBitmapImageRep *rep, int x0, int y0, int x1, int y1)
{
	int x, y, n = 0;

	for (y = y0; y < y1; y++) {
		for (x = x0; x < x1; x++) {
			NSColor *colour = [rep colorAtX:x y:y];

			if (colour != nil && [colour redComponent] < 0.5) {
				n++;
			}
		}
	}
	return n;
}

static int is_bar_face(NSBitmapImageRep *rep, int x, int y)
{
	NSColor *colour = [rep colorAtX:x y:y];

	return colour != nil && [colour redComponent] > BAR_RED - 0.05 && [colour greenComponent] > BAR_RED - 0.05
		&& [colour blueComponent] > BAR_RED - 0.05 && [colour whiteComponent] < BAR_RED + 0.05;
}

/* A DATE AT A NAMED HOUR AND MINUTE TODAY, so "the clock shows a time" is a claim about a moment this file chose
 * rather than about the moment the build happened to run. */
static NSDate *date_at(int hour, int minute)
{
	NSDateComponents *parts = [[[NSDateComponents alloc] init] autorelease];
	NSCalendar *calendar = [NSCalendar currentCalendar];
	NSDate *today = [NSDate date];
	NSInteger year, month, day;
	NSDate *answer;

	/* THE DAY IS TODAY'S, READ THROUGH THE CALENDAR the same way the date is built back through it — a date built
	 * from a guessed month is a date in the wrong month half the time. */
	{
		NSDateComponents *now = [calendar components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay)
						   fromDate:today];

		year = [now year];
		month = [now month];
		day = [now day];
	}
	[parts setYear:year];
	[parts setMonth:month];
	[parts setDay:day];
	[parts setHour:hour];
	[parts setMinute:minute];
	[parts setSecond:0];
	answer = [calendar dateFromComponents:parts];
	return (answer != nil) ? answer : today;
}

int main(void)
{
	/* THE PROCESS THIS SUITE IS ABOUT HAS NO WINDOW SERVER — see the header. */
	unsetenv("WAYLAND_DISPLAY");
	unsetenv("AGORA_SOCKET");

	@autoreleasepool {
		/* ---- 1. THE WIDTH IS A MEASUREMENT, NOT A NUMBER ------------------------------------------- */
		{
			NSString *empty = @"";
			NSString *narrow = @"1";
			NSString *wide = @"10:05";
			NSDictionary *attributes = [NSDictionary dictionaryWithObject:[NSFont systemFontOfSize:[NSFont systemFontSize]]
									      forKey:NSFontAttributeName];
			CGFloat emptyWidth = [WSClockView widthForTimeString:empty];
			CGFloat measured = [wide sizeWithAttributes:attributes].width;

			printf("menu_bar_clock: width(\"\") = %g, width(\"%s\") = %g (measured %g)\n",
			       (double)emptyWidth, [wide UTF8String], (double)[WSClockView widthForTimeString:wide],
			       (double)measured);
			/* AN EMPTY ITEM IS ITS AIR AND NOTHING ELSE: ten points of padding, rounded up by nobody. */
			check(emptyWidth == 10.0, "an item with no text is exactly its padding — ten points of nothing");
			check([WSClockView widthForTimeString:wide] == ceil(measured + 10.0),
			      "a time's item is the MEASURED line plus the air either side, rounded up to whole points");
			check([WSClockView widthForTimeString:wide] > [WSClockView widthForTimeString:narrow],
			      "and a longer time is a wider item, which is the whole reason the width is measured");
			check([WSClockView widthForTimeString:nil] == emptyWidth,
			      "a nil time is an empty one rather than a crash");
		}

		/* ---- 2. THE INK ----------------------------------------------------------------------------- */
		{
			NSString *time = @"10:05";
			CGFloat width = [WSClockView widthForTimeString:time];
			WSClockView *view = [[WSClockView alloc] initWithFrame:NSMakeRect(0.0, 0.0, width, 24.0)];
			NSBitmapImageRep *rep;

			[view setTimeString:time];
			rep = draw_view(view, (int)width, 24);
			printf("menu_bar_clock: a %s item is %g wide\n", [time UTF8String], (double)width);
			check(ink_in(rep, 0, 0, (int)width, 24) > 20, "the time is ON the glass — more than twenty dark pixels");
			check(is_bar_face(rep, 1, 12), "and it is drawn on the BAR'S OWN COLOUR, so the item is a piece of the bar");
			/* THE PADDING IS REAL: the air either side of the digits is what keeps two items from reading as one
			 * word, and it is the first thing a width arithmetic mistake eats. */
			check(ink_in(rep, 0, 0, 4, 24) == 0, "no ink in the item's LEFT padding");
			check(ink_in(rep, (int)width - 4, 0, (int)width, 24) == 0, "no ink in the item's RIGHT padding");
			check(ink_in(rep, 0, 0, (int)width, 2) == 0, "no ink on the item's top rows either");
			[rep release];

			/* **AN ITEM WITH NO TEXT IS STILL A PIECE OF THE BAR**: it paints the face and leaves no ink, which is
			 * what a status item that has not been given anything to say must look like. */
			[view setTimeString:@""];
			rep = draw_view(view, (int)width, 24);
			check(ink_in(rep, 0, 0, (int)width, 24) == 0, "an empty item draws NO ink");
			check(is_bar_face(rep, (int)width / 2, 12), "but it still paints the bar's face, so it is not a hole");
			[rep release];
			[view release];
		}

		/* ---- 3. THE CLOCK ITSELF, WITHOUT A BAR ------------------------------------------------------ */
		{
			WSMenuBarClock *clock = [[WSMenuBarClock alloc] init];
			NSDateFormatter *formatter = [[[NSDateFormatter alloc] init] autorelease];
			NSDate *moment = date_at(10, 5);
			BOOL started;

			[formatter setDateStyle:NSDateFormatterNoStyle];
			[formatter setTimeStyle:NSDateFormatterShortStyle];

			started = [clock start];
			printf("menu_bar_clock: start with no window server answered %s\n", started ? "YES" : "NO");
			check(!started, "WITH NO BAR THERE IS NO ITEM: -start answers NO rather than making a window of no height");
			check([clock statusItem] == nil, "and no item was left behind");
			/* **BUT THE CLOCK IS STILL A CLOCK**, which is the property the offscreen suite exists on: the time is
			 * read and measured whether or not there is anywhere to put it. */
			check([[clock timeString] length] > 0, "the clock nevertheless knows what time it is");

			[clock showTimeForDate:moment];
			printf("menu_bar_clock: a moment at 10:05 by this machine's calendar reads \"%s\"\n",
			       [[clock timeString] UTF8String]);
			check([[clock timeString] isEqualToString:[formatter stringFromDate:moment]],
			      "and it says what the LOCALE's short time says, not a format string of its own");
			check([[clock view] frame].size.width == [WSClockView widthForTimeString:[clock timeString]],
			      "the item's view is exactly as wide as the time it is showing");

			/* THE CONTRACT, AT A SECOND MOMENT: whatever the string, the width follows it. */
			[clock showTimeForDate:date_at(23, 59)];
			check([[clock view] frame].size.width == [WSClockView widthForTimeString:[clock timeString]],
			      "and it still is after the time changed — the width follows the digits");

			/* STOPPING IS SAFE TWICE, which matters because the application stops the clock on the way out and a
			 * failure inside `-start` stops it too. */
			[clock stop];
			[clock stop];
			check([[clock timeString] length] > 0, "stopping takes the item out and leaves the clock readable");
			[clock release];
		}
	}

	printf("menu_bar_clock: %d failure(s)\n", s_failed);
	return (s_failed == 0) ? 0 : 1;
}
