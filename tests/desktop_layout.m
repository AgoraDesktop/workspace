/*
 * desktop_layout — W1's offscreen measurement: the grid's arithmetic.
 *
 * Copyright © 2026 Kyle J. Cardoza. MIT licensed. SPDX-License-Identifier: MIT
 *
 * PURE GEOMETRY, SO NO COMPOSITOR AND NO WINDOW: a cell size, a column-major grid, a snap that avoids what is
 * taken, an arrange order and a hit test. These are the numbers a desktop and a Finder window's icon view will
 * both be built from, so they are checked where they live rather than through a screenshot.
 */
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
		NSRect bounds = NSMakeRect(0.0, 0.0, 800.0, 600.0);
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
		check(cell.height == (CGFloat)(size + WSIconLabelHeight + WSIconPadding), "and the label's height");
		check(rows == (NSInteger)floor((600.0 - 2.0 * (CGFloat)WSIconGridMargin) / cell.height),
		      "the rows fit the height left after the margins");
		check(rows >= 1, "and there is always at least one row, so a tiny view cannot divide by zero");

		check(first.x == 800.0 - (CGFloat)WSIconGridMargin - cell.width && first.y == (CGFloat)WSIconGridMargin,
		      "the first cell is at the RIGHT edge, at the top margin");
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

		printf("desktop_layout: %d case(s) failed\n", failed);
	}
	return failed == 0 ? 0 : 1;
}
