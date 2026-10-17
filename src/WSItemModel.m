/*
 * WSItemModel.m — enumerate a directory, and hold what came back.
 *
 * Copyright © 2026 Kyle J. Cardoza. MIT licensed — see LICENSE.
 * SPDX-License-Identifier: MIT
 */
#import "WSItemModel.h"

#import <Foundation/NSArray.h>
#import <Foundation/NSFileManager.h>
#import <Foundation/NSString.h>

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

/* THE ORDER THE MODEL LISTS IN, and it is a NAME order: case-insensitively, which is what a person reads. */
- (NSComparisonResult)compareByName:(WSItem *)other
{
	return [_name caseInsensitiveCompare:[other name]];
}

- (void)dealloc
{
	[_name release];
	[_path release];
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
