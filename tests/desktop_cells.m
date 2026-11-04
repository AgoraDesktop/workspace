/*
 * desktop_cells — one icon per grid cell, and every cell inside the area the screen actually offers.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **THE TWO WAYS TWO ICONS USED TO SHARE A PLACE.** A sidecar remembers an icon's top-left corner, and nothing
 * resolved that point against the grid: two entries naming the same corner drew two folders on top of each other, and an
 * entry left under where the Dock now reserves its strip stayed there, because the desktop only consulted the work area
 * for icons it had no position for. Both are the same question — where may this icon be — and `-reload` answers it once
 * through `WSIconLayout -snapPosition:…`, the arithmetic a drop already used.
 *
 * Offscreen: a temporary tree, a sidecar written by the metadata store itself, and the view asked where it put things.
 */
#import "WSDesktopView.h"
#import "WSIconLayout.h"
#import "WSMetadataStore.h"

#import <AppKit/NSWindow.h>
#import <Foundation/Foundation.h>

#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int s_failed;

static void check(int ok, const char *name)
{
	printf("  %s   %s\n", ok ? "ok  " : "FAIL", name);
	if (!ok) {
		s_failed++;
	}
}

static BOOL position_is_inside(NSPoint position, NSRect area, NSInteger iconSize)
{
	return position.x >= NSMinX(area) - 0.01 && position.y >= NSMinY(area) - 0.01
	       && position.x + (CGFloat)iconSize <= NSMaxX(area) + 0.01
	       && position.y + (CGFloat)iconSize <= NSMaxY(area) + 0.01;
}

int main(void)
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSFileManager *manager = [NSFileManager defaultManager];
	char template[] = "/tmp/agora-desktop-cells-XXXXXX";
	NSString *root;

	printf("desktop_cells: one icon per cell, inside the work area\n");

	if (mkdtemp(template) == NULL) {
		printf("FAIL: could not make the fixture\n");
		[pool release];
		return 1;
	}
	root = [manager stringWithFileSystemRepresentation:template length:strlen(template)];
	{
		NSArray *names = [NSArray arrayWithObjects:@"alpha.txt", @"beta.txt", @"gamma.txt", nil];
		NSUInteger i;

		for (i = 0; i < [names count]; i++) {
			[manager createFileAtPath:[root stringByAppendingPathComponent:[names objectAtIndex:i]]
					 contents:[NSData data] attributes:nil];
		}
	}
	/* **THE SIDECAR, WRITTEN THE WAY A DRAG WRITES IT**: three entries, two of them on the SAME corner. */
	{
		WSMetadataStore *store = [WSMetadataStore storeForDirectory:root];

		[store setIconPosition:NSMakePoint(200.0, 200.0) forName:@"alpha.txt"];
		[store setIconPosition:NSMakePoint(200.0, 200.0) forName:@"beta.txt"];
		[store setIconPosition:NSMakePoint(600.0, 300.0) forName:@"gamma.txt"];
		[store save];	/* autoreleased by its own factory: not this probe's to release */
	}

	{
		WSDesktopView *desktop = [[WSDesktopView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 900.0, 600.0)
							     directory:root];
		NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0.0, 0.0, 900.0, 600.0)
							       styleMask:NSBorderlessWindowMask
								 backing:NSBackingStoreBuffered defer:NO];
		NSArray *positions;
		NSRect area;

		[window setContentView:desktop];
		positions = [desktop cg_positions];
		area = [desktop cg_layoutBounds];

		check([positions count] == 3, "the desktop read three items");


		check(!NSEqualPoints([[positions objectAtIndex:0] pointValue], [[positions objectAtIndex:1] pointValue]),
		      "two sidecar entries naming the same corner do NOT share a cell");
		{
			NSUInteger i, j;
			BOOL allDistinct = YES, allInside = YES;

			for (i = 0; i < [positions count]; i++) {
				for (j = i + 1; j < [positions count]; j++) {
					if (NSEqualPoints([[positions objectAtIndex:i] pointValue],
							  [[positions objectAtIndex:j] pointValue])) {
						allDistinct = NO;
					}
				}
				if (!position_is_inside([[positions objectAtIndex:i] pointValue], area,
							[desktop iconSize])) {
					allInside = NO;
				}
			}
			check(allDistinct, "and no two icons are anywhere on top of each other");
			check(allInside, "and every icon lies inside the area the screen offered");
		}
		/* **AND EVERY ONE OF THEM IS A CELL**, not a remembered point that happens to be free: the desktop's grid is
		 * what a person sees, and a position off it would drift as soon as anything snapped. */
		{
			NSUInteger i;
			BOOL onGrid = YES;

			for (i = 0; i < [positions count]; i++) {
				NSPoint position = [[positions objectAtIndex:i] pointValue];
				NSPoint snapped = [WSIconLayout snapPosition:position inBounds:area
								   iconSize:[desktop iconSize] avoiding:[NSArray array]];

				if (!NSEqualPoints(snapped, position)) {
					onGrid = NO;
				}
			}
			check(onGrid, "and each of them is a cell of the grid, not a point between two");
		}
		[desktop release];
		[window release];
	}

	/* **A FULL GRID SHOWS WHAT FITS.** More items than cells: the ones with no cell are not placed at all — the sentinel
	 * is outside every view, so they are not drawn, not hit and not dragged — and every icon that IS placed keeps a cell
	 * of its own. */
	{
		char full[] = "/tmp/agora-desktop-full-XXXXXX";
		NSString *fullRoot;
		NSUInteger n;

		if (mkdtemp(full) == NULL) {
			printf("FAIL: could not make the full-grid fixture\n");
		} else {
			fullRoot = [manager stringWithFileSystemRepresentation:full length:strlen(full)];
			for (n = 0; n < 63; n++) {
				[manager createFileAtPath:[fullRoot stringByAppendingPathComponent:
					[NSString stringWithFormat:@"item%02lu.txt", (unsigned long)n]]
						 contents:[NSData data] attributes:nil];
			}
			{
				WSDesktopView *desktop = [[WSDesktopView alloc]
					initWithFrame:NSMakeRect(0.0, 0.0, 900.0, 600.0) directory:fullRoot];
				NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0.0, 0.0, 900.0, 600.0)
									       styleMask:NSBorderlessWindowMask
									     backing:NSBackingStoreBuffered defer:NO];
				NSArray *positions;
				NSUInteger unplaced = 0, placed = 0, i, j;
				BOOL distinct = YES;

				[window setContentView:desktop];
				positions = [desktop cg_positions];
				for (i = 0; i < [positions count]; i++) {
					NSPoint position = [[positions objectAtIndex:i] pointValue];

					if (NSEqualPoints(position, WSIconNoPosition)) {
						unplaced++;
						continue;
					}
					placed++;
					for (j = i + 1; j < [positions count]; j++) {
						if (NSEqualPoints([[positions objectAtIndex:j] pointValue], position)) {
							distinct = NO;
						}
					}
				}
				check([positions count] == 63, "a directory of 63 items is read whole");
				check(unplaced > 0, "and the ones with no cell are given no position at all");
				check(placed + unplaced == 63, "every item is either placed or set aside");
				check(distinct, "and no two placed icons share a cell");
				[desktop release];
				[window release];
			}
		}
	}

	/* **THE DESKTOP ANSWERS COMPRESS TOO, so the right-click row and the menu bar work over it.** A view of its own, so
	 * the reload the command ends with cannot disturb the layout this probe has been measuring. */
	{
		WSDesktopView *compressing = [[WSDesktopView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 900.0, 600.0)
									directory:root];
		NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0.0, 0.0, 900.0, 600.0)
							       styleMask:NSBorderlessWindowMask
								 backing:NSBackingStoreBuffered defer:NO];
		NSString *alpha = [root stringByAppendingPathComponent:@"alpha.txt"];
		NSString *archive = [root stringByAppendingPathComponent:@"alpha.zip"];

		[window setContentView:compressing];
		[compressing cg_selectPaths:[NSArray arrayWithObject:alpha]];
		[compressing compress:nil];
		check([[NSFileManager defaultManager] fileExistsAtPath:archive],
		      "the desktop compresses its selection into the desktop folder");
		/* **AND IT UNPACKS ONE, WHICH IS THE SAME COMMAND THE RIGHT-CLICK ROW AND A DOUBLE CLICK TAKE.** */
		{
			NSString *unpacked = [root stringByAppendingPathComponent:@"alpha"];

			[compressing reload];
			[compressing cg_selectPaths:[NSArray arrayWithObject:archive]];
			check([compressing cg_selectionCanBeExtracted],
			      "a selected archive on the desktop says it can be extracted");
			[compressing extractArchive:nil];
			check([[NSFileManager defaultManager] fileExistsAtPath:unpacked],
			      "and the desktop unpacks it into a folder named for it");
			[[NSFileManager defaultManager] removeItemAtPath:unpacked error:NULL];
		}
		[[NSFileManager defaultManager] removeItemAtPath:archive error:NULL];
		[window setContentView:nil];
		[window release];
		[compressing release];
	}

	printf("desktop_cells: %s\n", s_failed == 0 ? "all checks passed" : "FAILURES");
	[pool release];
	return s_failed == 0 ? 0 : 1;
}
