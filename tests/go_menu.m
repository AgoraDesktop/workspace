/*
 * go_menu — the Go menu, LAID OUT AND DRAWN OFFSCREEN, because opening it is what crashed.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **THE ONE MENU THAT HAS A KEY EQUIVALENT WHICH IS NOT A CHARACTER.** "Enclosing Folder" is ⌘↑, whose key
 * equivalent is the UP ARROW function key — a single code point in the Private Use Area (U+F700). Everything a
 * dropdown does with a key equivalent goes through the font: it is MEASURED for the shortcut column and DRAWN as
 * a glyph, and a font with nothing for that code point is the first place to look when the menu crashes on open.
 *
 * So this probe does what opening the menu does, in the same order: measure the arrow, lay the menu out, draw it
 * into a bitmap, and ask every row for its box. A crash in any of those is the crash a person met.
 */
#import <AppKit/NSApplication.h>
#import <AppKit/NSBitmapImageRep.h>
#import <AppKit/NSColor.h>
#import <AppKit/NSFont.h>
#import <AppKit/NSGraphicsContext.h>
#import <AppKit/NSMenu.h>
#import <AppKit/NSMenuItem.h>
#import <AppKit/NSMenuView.h>
#import <AppKit/NSStringDrawing.h>
#import <Foundation/Foundation.h>

#import "WSMainMenu.h"

#include <stdio.h>

static int failed;

static void check(BOOL condition, const char *name)
{
	printf("  [%s] %s\n", condition ? "ok" : "FAIL", name);
	if (!condition) failed++;
}

/* The two rows the AppKit refuses, so the bar can be installed without a compositor. */
@interface WSGoProbeTarget : NSObject
- (void)orderFrontAboutPanel:(id)sender;
- (void)showPreferences:(id)sender;
@end

@implementation WSGoProbeTarget
- (void)orderFrontAboutPanel:(id)sender { (void)sender; }
- (void)showPreferences:(id)sender { (void)sender; }
@end

int main(void)
{
	@autoreleasepool {
		NSApplication *application = [NSApplication sharedApplication];
		WSGoProbeTarget *target = [[WSGoProbeTarget alloc] init];
		NSMenu *bar;
		NSMenu *menu;
		NSMenuView *view;
		NSBitmapImageRep *rep;
		NSInteger i;

		[WSMainMenu installWithTarget:target];
		bar = (NSMenu *)[application mainMenu];
		menu = (bar != nil) ? (NSMenu *)[[bar itemWithTitle:@"Go"] submenu] : nil;

		check(menu != nil, "the bar HAS a Go menu");
		if (menu == nil) {
			printf("go_menu: %d case(s) failed\n", 1);
			return 1;
		}

		/* 1. THE ARROW ON ITS OWN — measured first, because that is the first thing a shortcut column asks. */
		{
			NSDictionary *attributes = [NSDictionary dictionaryWithObjectsAndKeys:
				[NSFont systemFontOfSize:12.0], NSFontAttributeName, nil];
			NSSize size = [@"\uf700" sizeWithAttributes:attributes];

			printf("  (note: the up arrow measures %.2f x %.2f)\n", (double)size.width, (double)size.height);
			check(size.width > 0.0, "the up arrow's key equivalent MEASURES");
		}

		/* 2. THE MENU LAID OUT — cells made, titles measured, the shortcut column sized. */
		view = [[NSMenuView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 260.0, 400.0)];
		[view setMenu:menu];
		printf("  (note: %ld items, required height %.1f)\n", (long)[menu numberOfItems],
		       (double)[view requiredHeight]);
		check([view requiredHeight] > 0.0, "it asks for a height");

		/* 3. AND DRAWN, which is the rest of what opening it does. */
		rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:260 pixelsHigh:400
			bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
			colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:260 * 4 bitsPerPixel:32];
		check(rep != nil, "and there is a bitmap to draw it into");
		if (rep != nil) {
			[NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
			[view drawRect:[view bounds]];
			check(YES, "DRAWING it returned");
		}

		/* **AND ITS COST, WHICH IS THE REPORT.** "It takes a long time to render" is a measurement, so this
		 * times the first paint, a second paint with the cells' measurements already warm, and the two strings a
		 * shortcut column is made of — because the arrow has no glyph in the system font and a fallback lookup
		 * per draw would be exactly the kind of thing that is invisible until it is timed. */
		{
			NSDictionary *attributes = [NSDictionary dictionaryWithObjectsAndKeys:
				[NSFont systemFontOfSize:12.0], NSFontAttributeName, nil];
			NSRect box = NSMakeRect(0.0, 0.0, 200.0, 20.0);
			double t;
			int n;

			t = [NSDate timeIntervalSinceReferenceDate];
			[view drawRect:[view bounds]];
			printf("  (note: FIRST paint of the Go menu: %.1f ms)\n",
			       ([NSDate timeIntervalSinceReferenceDate] - t) * 1000.0);

			t = [NSDate timeIntervalSinceReferenceDate];
			[view drawRect:[view bounds]];
			printf("  (note: second paint, measurements warm: %.1f ms)\n",
			       ([NSDate timeIntervalSinceReferenceDate] - t) * 1000.0);

			t = [NSDate timeIntervalSinceReferenceDate];
			for (n = 0; n < 20; n++) [@"\uf700" drawInRect:box withAttributes:attributes];
			printf("  (note: 20 draws of the up arrow: %.1f ms)\n",
			       ([NSDate timeIntervalSinceReferenceDate] - t) * 1000.0);

			{
				/* WHERE THE BOUNDARY IS: a plain letter, two typographic characters every menu already uses,
				 * an accented letter, and the Private Use Area arrow. */
				struct { const char *name; NSString *text; } sample[] = {
					{ "a letter", @"c" },
					{ "ellipsis U+2026", @"\u2026" },
					{ "copyright U+00A9", @"\u00a9" },
					{ "e-acute U+00E9", @"\u00e9" },
					{ "up arrow U+F700", @"\uf700" },
				};
				int k;

				for (k = 0; k < (int)(sizeof sample / sizeof sample[0]); k++) {
					t = [NSDate timeIntervalSinceReferenceDate];
					[nil self];	/* keep the compiler quiet about the loop being otherwise trivial */
					for (n = 0; n < 5; n++) [sample[k].text drawInRect:box withAttributes:attributes];
					printf("  (note: 5 draws of %-20s %.1f ms)\n", sample[k].name,
					       ([NSDate timeIntervalSinceReferenceDate] - t) * 1000.0);
				}
			}
		}

		/* 4. EVERY ROW HAS A BOX — what a click and the tracking loop ask of each item. */
		{
			BOOL every = YES;

			for (i = 0; i < [menu numberOfItems]; i++) {
				NSRect box = [view rectForItemAtIndex:i];

				if (box.size.height <= 0.0) {
					every = NO;
					printf("  (note: item %ld \"%s\" has no height)\n", (long)i,
					       [[[menu itemAtIndex:i] title] UTF8String]);
				}
			}
			check(every, "and every row has a box");
		}

		printf("go_menu: %d case(s) failed\n", failed);
		[target release];
	}
	return failed == 0 ? 0 : 1;
}
