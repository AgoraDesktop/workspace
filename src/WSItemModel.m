/*
 * WSItemModel.m — enumerate a directory, and hold what came back.
 *
 * Copyright © 2026 Kyle J. Cardoza. MIT licensed — see LICENSE.
 * SPDX-License-Identifier: MIT
 */
#import "WSItemModel.h"

#import <Foundation/NSArray.h>
#import <Foundation/NSDate.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSFileManager.h>
#import <Foundation/NSNumber.h>
#import <Foundation/NSString.h>

#include <ctype.h>

/* **NATURAL ORDER, BECAUSE A PERSON READS NUMBERS AS NUMBERS.** A run of digits is compared by its VALUE, not its
 * characters, so `file2` precedes `file10`; a run that is equal in value falls through with its leading zeros intact
 * (so `02` and `2` are not forced into an arbitrary order by the digits alone). Everything else is case-insensitive,
 * and a case-only difference is settled by the original strings so the order is total.
 */
static NSComparisonResult fn_natural_compare(NSString *left, NSString *right)
{
	NSUInteger li = 0, ri = 0;
	NSUInteger ll = [left length], rl = [right length];

	while (li < ll && ri < rl) {
		unichar lc = [left characterAtIndex:li];
		unichar rc = [right characterAtIndex:ri];

		if (lc >= '0' && lc <= '9' && rc >= '0' && rc <= '9') {
			NSUInteger ls = li, rs = ri;
			NSUInteger la, ra, k;

			while (li < ll && [left characterAtIndex:li] >= '0' && [left characterAtIndex:li] <= '9') li++;
			while (ri < rl && [right characterAtIndex:ri] >= '0' && [right characterAtIndex:ri] <= '9') ri++;
			la = ls;
			ra = rs;
			while (la < li && [left characterAtIndex:la] == '0') la++;
			while (ra < ri && [right characterAtIndex:ra] == '0') ra++;
			if (li - la != ri - ra) {
				return (li - la < ri - ra) ? NSOrderedAscending : NSOrderedDescending;
			}
			for (k = 0; k < li - la; k++) {
				unichar ld = [left characterAtIndex:la + k];
				unichar rd = [right characterAtIndex:ra + k];

				if (ld != rd) {
					return (ld < rd) ? NSOrderedAscending : NSOrderedDescending;
				}
			}
			continue;
		}
		{
			unichar lf = (unichar)tolower((int)lc);
			unichar rf = (unichar)tolower((int)rc);

			if (lf != rf) {
				return (lf < rf) ? NSOrderedAscending : NSOrderedDescending;
			}
		}
		li++;
		ri++;
	}
	if (ll - li == rl - ri) {
		return [left compare:right];
	}
	return (ll - li < rl - ri) ? NSOrderedAscending : NSOrderedDescending;
}

@implementation WSItem

- (instancetype)initWithName:(NSString *)name path:(NSString *)path isDirectory:(BOOL)isDirectory
{
	self = [super init];
	if (self != nil) {
		_name = [name copy];
		_path = [path copy];
		_isDirectory = isDirectory;
	}
	return self;
}

- (NSString *)name { return _name; }
- (NSString *)path { return _path; }
- (BOOL)isDirectory { return _isDirectory; }

- (void)loadAttributes
{
	NSDictionary *attributes;
	id value;

	if (_attributesLoaded) {
		return;
	}
	_attributesLoaded = YES;
	attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:_path error:NULL];
	if (attributes == nil) {
		return;
	}
	value = [attributes objectForKey:NSFileModificationDate];
	if ([value isKindOfClass:[NSDate class]]) {
		_modificationDate = [value retain];
	}
	value = [attributes objectForKey:NSFileSize];
	if ([value isKindOfClass:[NSNumber class]]) {
		_size = [value unsignedLongLongValue];
	}
}

- (NSDate *)modificationDate
{
	[self loadAttributes];
	return _modificationDate;
}

- (unsigned long long)size
{
	[self loadAttributes];
	return _size;
}

+ (NSComparisonResult)naturalCompare:(NSString *)left to:(NSString *)right
{
	if (left == nil) left = @"";
	if (right == nil) right = @"";
	return fn_natural_compare(left, right);
}

/* THE ORDER THE MODEL LISTS IN, and it is a NAME order: naturally, case-insensitively, which is what a person reads. */
- (NSComparisonResult)compareByName:(WSItem *)other
{
	return [WSItem naturalCompare:_name to:[other name]];
}

- (void)dealloc
{
	[_name release];
	[_path release];
	[_modificationDate release];
	[super dealloc];
}

@end

@implementation WSItemModel

- (instancetype)initWithDirectory:(NSString *)directory
{
	self = [super init];
	if (self != nil) {
		_directory = [directory copy];
		_items = [[NSArray alloc] init];
		[self reload];
	}
	return self;
}

- (NSString *)directory { return _directory; }
- (NSArray *)items { return _items; }

- (BOOL)reload
{
	NSFileManager *manager = [NSFileManager defaultManager];
	NSArray *names = [manager contentsOfDirectoryAtPath:_directory error:NULL];
	NSMutableArray *items = [[NSMutableArray alloc] init];
	NSUInteger i;

	if (names == nil) {
		[_items release];
		_items = items;
		return NO;
	}
	for (i = 0; i < [names count]; i++) {
		NSString *name = [names objectAtIndex:i];
		NSString *path;
		BOOL isDirectory = NO;
		WSItem *item;

		/* HIDDEN ITEMS ARE NOT SHOWN, which is also what keeps the sidecar itself off the desktop. */
		if ([name length] == 0 || [name hasPrefix:@"."]) continue;
		path = [_directory stringByAppendingPathComponent:name];
		[manager fileExistsAtPath:path isDirectory:&isDirectory];
		item = [[WSItem alloc] initWithName:name path:path isDirectory:isDirectory];
		[items addObject:item];
		[item release];
	}
	[items sortUsingSelector:@selector(compareByName:)];
	[_items release];
	_items = items;
	return YES;
}

- (void)dealloc
{
	[_directory release];
	[_items release];
	[super dealloc];
}

@end
