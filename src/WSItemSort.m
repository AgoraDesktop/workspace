/*
 * WSItemSort.m — directories first, then the key, then the name.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Portions of this file may derive from GNUstep; see THIRD-PARTY.md.
 */
#import "WSItemSort.h"

#import "WSItemKind.h"
#import "WSItemModel.h"

#import <Foundation/NSArray.h>
#import <Foundation/NSDate.h>
#import <Foundation/NSString.h>

static NSComparisonResult fn_invert(NSComparisonResult order)
{
	if (order == NSOrderedAscending) return NSOrderedDescending;
	if (order == NSOrderedDescending) return NSOrderedAscending;
	return NSOrderedSame;
}

static NSComparisonResult fn_key_compare(WSItem *left, WSItem *right, WSItemSortKey key, BOOL ascending)
{
	NSComparisonResult order = NSOrderedSame;

	if ([left isDirectory] != [right isDirectory]) {
		return [left isDirectory] ? NSOrderedAscending : NSOrderedDescending;
	}
	switch (key) {
	case WSItemSortDate: {
		NSDate *ld = [left modificationDate];
		NSDate *rd = [right modificationDate];

		if (ld == nil && rd == nil) order = NSOrderedSame;
		else if (ld == nil) order = NSOrderedAscending;
		else if (rd == nil) order = NSOrderedDescending;
		else order = [ld compare:rd];
		break;
	}
	case WSItemSortSize: {
		unsigned long long ls = [left size];
		unsigned long long rs = [right size];

		order = (ls < rs) ? NSOrderedAscending : ((ls > rs) ? NSOrderedDescending : NSOrderedSame);
		break;
	}
	case WSItemSortKind: {
		NSString *lk = [WSItemKind kindForItem:left];
		NSString *rk = [WSItemKind kindForItem:right];

		order = [lk caseInsensitiveCompare:rk];
		break;
	}
	case WSItemSortName:
	default:
		order = [WSItem naturalCompare:[left name] to:[right name]];
		break;
	}
	if (order != NSOrderedSame && !ascending) {
		order = fn_invert(order);
	}
	if (order == NSOrderedSame) {
		order = [WSItem naturalCompare:[left name] to:[right name]];
	}
	return order;
}

@implementation WSItemSort

+ (NSArray *)sortedItems:(NSArray *)items key:(WSItemSortKey)key ascending:(BOOL)ascending
{
	NSMutableArray *sorted = [[items mutableCopy] autorelease];
	NSUInteger i;

	for (i = 1; i < [sorted count]; i++) {
		id item = [[sorted objectAtIndex:i] retain];
		NSUInteger j = i;

		while (j > 0
		       && fn_key_compare(item, [sorted objectAtIndex:j - 1], key, ascending) == NSOrderedAscending) {
			[sorted replaceObjectAtIndex:j withObject:[sorted objectAtIndex:j - 1]];
			j--;
		}
		[sorted replaceObjectAtIndex:j withObject:item];
		[item release];
	}
	return sorted;
}

@end
