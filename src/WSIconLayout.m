/*
 * WSIconLayout.m — the grid's arithmetic.
 *
 * Copyright © 2026 Kyle J. Cardoza. MIT licensed — see LICENSE.
 * SPDX-License-Identifier: MIT
 */
#import "WSIconLayout.h"

#import <Foundation/NSArray.h>
#import <Foundation/NSString.h>
#import <Foundation/NSValue.h>

#include <math.h>

const NSInteger WSIconDefaultSize = 64;
const NSInteger WSIconGridMargin = 16;
const NSInteger WSIconLabelHeight = 16;
const NSInteger WSIconPadding = 8;

@implementation WSIconLayout

+ (NSSize)cellSizeForIconSize:(NSInteger)iconSize
{
	return NSMakeSize((CGFloat)(iconSize + 2 * WSIconPadding),
			  (CGFloat)(iconSize + WSIconLabelHeight + WSIconPadding));
}

+ (NSInteger)rowsPerColumnInBounds:(NSRect)bounds iconSize:(NSInteger)iconSize
{
	NSSize cell = [self cellSizeForIconSize:iconSize];
	CGFloat usable = bounds.size.height - 2.0 * (CGFloat)WSIconGridMargin;
	NSInteger rows = (NSInteger)floor(usable / cell.height);

	return (rows >= 1) ? rows : 1;
}

+ (NSPoint)gridPositionForIndex:(NSInteger)index inBounds:(NSRect)bounds iconSize:(NSInteger)iconSize
{
	NSSize cell = [self cellSizeForIconSize:iconSize];
	NSInteger rows = [self rowsPerColumnInBounds:bounds iconSize:iconSize];
	NSInteger column = index / rows;
	NSInteger row = index % rows;

	return NSMakePoint((CGFloat)WSIconGridMargin + (CGFloat)column * cell.width,
			   (CGFloat)WSIconGridMargin + (CGFloat)row * cell.height);
}

+ (NSPoint)snapPosition:(NSPoint)desired
	       inBounds:(NSRect)bounds
	       iconSize:(NSInteger)iconSize
	       avoiding:(NSArray *)occupied
{
	NSSize cell = [self cellSizeForIconSize:iconSize];
	NSInteger columns = (NSInteger)floor((bounds.size.width - 2.0 * (CGFloat)WSIconGridMargin) / cell.width);
	NSInteger rows = [self rowsPerColumnInBounds:bounds iconSize:iconSize];
	NSInteger total, i;
	NSInteger best = -1;
	double bestDistance = 0.0;

	if (columns < 1) columns = 1;
	total = columns * rows;

	/* THE NEAREST FREE CELL, not the first one: a drop lands where the hand left it, and scanning the grid
	 * from the top would send a drop at the bottom of the screen back to the top-left. */
	for (i = 0; i < total; i++) {
		NSPoint candidate = [self gridPositionForIndex:i inBounds:bounds iconSize:iconSize];
		BOOL taken = NO;
		NSUInteger j;

		for (j = 0; j < [occupied count]; j++) {
			NSPoint other = [[occupied objectAtIndex:j] pointValue];
			if (fabs(other.x - candidate.x) < 0.5 && fabs(other.y - candidate.y) < 0.5) { taken = YES; break; }
		}
		if (taken) continue;

		{
			double dx = candidate.x - desired.x;
			double dy = candidate.y - desired.y;
			double distance = dx * dx + dy * dy;

			if (best < 0 || distance < bestDistance) { best = i; bestDistance = distance; }
		}
	}
	if (best < 0) return desired;
	return [self gridPositionForIndex:best inBounds:bounds iconSize:iconSize];
}

+ (NSArray *)namesByArranging:(NSArray *)names mode:(WSArrangeMode)mode
{
	if (mode == WSArrangeByName) return [names sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
	return names;
}

+ (NSRect)iconRectAtPosition:(NSPoint)position iconSize:(NSInteger)iconSize
{
	return NSMakeRect(position.x, position.y, (CGFloat)iconSize, (CGFloat)iconSize);
}

+ (NSInteger)indexOfPosition:(NSPoint)point among:(NSArray *)positions iconSize:(NSInteger)iconSize
{
	NSUInteger i;

	for (i = 0; i < [positions count]; i++) {
		NSPoint position = [[positions objectAtIndex:i] pointValue];
		NSRect rect = [self iconRectAtPosition:position iconSize:iconSize];

		if (point.x >= rect.origin.x && point.x < rect.origin.x + rect.size.width &&
		    point.y >= rect.origin.y && point.y < rect.origin.y + rect.size.height) {
			return (NSInteger)i;
		}
	}
	return -1;
}

@end
