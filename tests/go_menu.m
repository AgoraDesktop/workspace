/*
 * go_menu — the Go menu, LAID OUT AND DRAWN OFFSCREEN, because opening it is what crashed.
 *
 * Copyright © 2026 Kyle J. Cardoza. MIT licensed — see LICENSE.
 * SPDX-License-Identifier: MIT
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
