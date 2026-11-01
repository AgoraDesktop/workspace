/*
 * desktop_layout — W1's offscreen measurement: the grid's arithmetic.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * PURE GEOMETRY, SO NO COMPOSITOR AND NO WINDOW: a cell size, a column-major grid, a snap that avoids what is
 * taken, an arrange order and a hit test. These are the numbers a desktop and a file window's icon view will
 * both be built from, so they are checked where they live rather than through a screenshot.
 */
#import "WSIconCell.h"
#import "WSIconLayout.h"

#import <Foundation/Foundation.h>

#include <math.h>
#include <stdio.h>

static int failed;

static void check(BOOL condition, const char *name)
{
	printf("  [%s] %s\n", condition ? "ok" : "FAIL", name);
	if (!condition) failed++;
}

int main(void)
{
	@autoreleasepool {
		/* THE USABLE AREA, in top-left coordinates: an 800x600 view less the desktop's top padding of 34 (the menu
		 * bar's 24 plus ten). Its ORIGIN is the first row's top, which is the whole point. */
		NSRect bounds = NSMakeRect(0.0, 34.0, 800.0, 566.0);
		NSInteger size = WSIconDefaultSize;
		NSSize cell = [WSIconLayout cellSizeForIconSize:size];
		NSInteger rows = [WSIconLayout rowsPerColumnInBounds:bounds iconSize:size];
		NSPoint first = [WSIconLayout gridPositionForIndex:0 inBounds:bounds iconSize:size];
		NSPoint second = [WSIconLayout gridPositionForIndex:1 inBounds:bounds iconSize:size];
		NSPoint nextColumn = [WSIconLayout gridPositionForIndex:rows inBounds:bounds iconSize:size];
		NSArray *occupied, *names, *sorted, *same, *positions;
		NSPoint snapped;
		NSRect iconRect;

		check(cell.width == (CGFloat)(size + 2 * WSIconPadding), "the cell is the icon plus its padding");
		check(cell.height == (CGFloat)(size + WSIconLabelGap + WSIconLabelHeight + WSIconPadding),
		      "and the label's height, with the air the drawing puts between the icon and the name");
		check(rows == (NSInteger)floor((566.0 - (CGFloat)WSIconGridMargin) / cell.height),
		      "the rows fit the area, less the bottom margin (the top is the origin)");
		check(rows >= 1, "and there is always at least one row, so a tiny view cannot divide by zero");

		check(first.x == 800.0 - (CGFloat)WSIconGridMargin - cell.width && first.y == 34.0,
		      "the first cell is at the area's RIGHT edge and at its TOP — the origin, not an inset");
		check(second.x == first.x && second.y > first.y, "the second is BELOW the first");
		check(nextColumn.x == first.x - cell.width && nextColumn.y == first.y,
		      "and the next column starts to the LEFT — right to left");

		occupied = [NSArray arrayWithObject:[NSValue valueWithPoint:first]];
		snapped = [WSIconLayout snapPosition:first inBounds:bounds iconSize:size avoiding:occupied];
		check(!(snapped.x == first.x && snapped.y == first.y), "a snap onto a taken cell moves off it");
		/* THE CELL IS WIDER THAN IT IS TALL, so the cell to the LEFT is nearer the first than the one below it —
		 * the snap answers the NEAREST free cell, not the next one in reading order. */
		check(snapped.x == nextColumn.x && snapped.y == nextColumn.y,
		      "and lands on the NEAREST free cell, which is the one to the LEFT");

		names = [NSArray arrayWithObjects:@"banana", @"Apple", @"cherry", nil];
		sorted = [WSIconLayout namesByArranging:names mode:WSArrangeByName];
		check([[sorted objectAtIndex:0] isEqualToString:@"Apple"], "arrange by name sorts case-insensitively");
		same = [WSIconLayout namesByArranging:names mode:WSArrangeNone];
		check([[same objectAtIndex:0] isEqualToString:@"banana"], "arrange none keeps the caller's order");

		iconRect = [WSIconLayout iconRectAtPosition:NSMakePoint(100.0, 200.0) iconSize:size];
		check(iconRect.origin.x == 100.0 && iconRect.origin.y == 200.0 && iconRect.size.width == (CGFloat)size,
		      "the icon's rect is at its position and its size");

		positions = [NSArray arrayWithObject:[NSValue valueWithPoint:NSMakePoint(100.0, 200.0)]];
		check([WSIconLayout indexOfPosition:NSMakePoint(110.0, 210.0) among:positions iconSize:size] == 0,
		      "a point inside an icon hits it");
		check([WSIconLayout indexOfPosition:NSMakePoint(10.0, 10.0) among:positions iconSize:size] == -1,
		      "and a point outside misses");

		/* **A SNAP CANNOT LEAVE THE AREA IT WAS GIVEN, WHICH IS HOW A RESERVED STRIP IS HONOURED.** The desktop passes the
	 * work area — the screen less what the Dock reserved — so the only thing that keeps a cell out of the Dock's strip is
	 * this arithmetic. The area here is the same grid, 64 points narrower: nothing may land in the last 64 points. */
	{
		NSRect reserved = NSMakeRect(0.0, 34.0, 800.0 - 64.0, 566.0);
		BOOL inside = YES;
		NSInteger n;

		for (n = 0; n < 40; n++) {
			NSPoint point = [WSIconLayout snapPosition:NSMakePoint((CGFloat)((n * 37) % 800), (CGFloat)((n * 53) % 566))
						  inBounds:reserved
						  iconSize:size
						  avoiding:[NSArray array]];

			if (point.x < NSMinX(reserved) || point.x + cell.width > NSMaxX(reserved) + 0.01
			    || point.y < NSMinY(reserved) || point.y + cell.height > NSMaxY(reserved) + 0.01) {
				inside = NO;
			}
		}
		check(inside, "every cell a snap can choose lies inside the area it was given, clear of a reserved strip");
	}
	/* **AND TWO ICONS CANNOT BE SENT TO ONE CELL.** The same desired point, asked twice with the first answer already
	 * occupied, is the arithmetic a reload and a drop both lean on for one icon per cell. */
	{
		NSPoint desired = NSMakePoint(120.0, 90.0);
		NSRect area = NSMakeRect(0.0, 34.0, 800.0, 566.0);
		NSPoint first = [WSIconLayout snapPosition:desired inBounds:area iconSize:size
						  avoiding:[NSArray array]];
		NSArray *taken = [NSArray arrayWithObject:[NSValue valueWithPoint:first]];
		NSPoint second = [WSIconLayout snapPosition:desired inBounds:area iconSize:size avoiding:taken];

		check(!NSEqualPoints(first, second),
		      "a second icon asking for a taken cell is given another cell, never the same one");
	}

	printf("desktop_layout: %d case(s) failed\n", failed);
	}
	return failed == 0 ? 0 : 1;
}
