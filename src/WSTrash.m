/*
 * WSTrash.m — the recycle, the Put Back record and the empty.
 *
 * Copyright © 2026 Kyle J. Cardoza. MIT licensed — see LICENSE.
 * SPDX-License-Identifier: MIT
 */
#import "WSTrash.h"

#import <Foundation/NSData.h>
#import <Foundation/NSDate.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSFileManager.h>
#import <Foundation/NSError.h>
#import <Foundation/NSPropertyListSerialization.h>
#import <Foundation/NSString.h>

#include <sys/stat.h>
#include <unistd.h>

static NSString *fn_unique_name(NSString *directory, NSString *name)
{
	NSFileManager *manager = [NSFileManager defaultManager];
	NSString *candidate = name;
	NSString *base;
	NSString *extension;
	NSInteger n = 2;

	if (![manager fileExistsAtPath:[directory stringByAppendingPathComponent:candidate]]) {
		return candidate;
	}
	base = [name stringByDeletingPathExtension];
	extension = [name pathExtension];
	for (;;) {
		candidate = ([extension length] > 0)
			? [NSString stringWithFormat:@"%@ %ld.%@", base, (long)n, extension]
			: [NSString stringWithFormat:@"%@ %ld", base, (long)n];
		if (![manager fileExistsAtPath:[directory stringByAppendingPathComponent:candidate]]) {
			return candidate;
		}
		n++;
	}
}

static NSString *fn_mount_root(NSString *path, dev_t device)
{
	NSString *current = path;
	NSString *parent;

	for (;;) {
		struct stat st;

		parent = [current stringByDeletingLastPathComponent];
		if ([parent isEqual:current] || [parent length] == 0) {
			return current;
		}
		if (stat([parent UTF8String], &st) != 0 || st.st_dev != device) {
			return current;
		}
		current = parent;
	}
}

@interface WSTrashItem (APPKITRecordPath)
- (NSString *)recordPath;
@end

@implementation WSTrashItem

- (instancetype)initWithOriginalPath:(NSString *)original trashPath:(NSString *)trash recordPath:(NSString *)record
				date:(NSDate *)date
{
	self = [super init];
	if (self != nil) {
		_originalPath = [original copy];
		_trashPath = [trash copy];
		_recordPath = [record copy];
		_date = [date retain];
	}
	return self;
}

- (void)dealloc
{
	[_originalPath release];
	[_trashPath release];
	[_recordPath release];
	[_date release];
	[super dealloc];
}

- (NSString *)originalPath { return _originalPath; }
- (NSString *)trashPath { return _trashPath; }
- (NSString *)recordPath { return _recordPath; }
- (NSDate *)date { return _date; }

@end

@implementation WSTrash

- (instancetype)init
{
	self = [super init];
	if (self != nil) {
		_root = nil;
	}
	return self;
}

- (instancetype)initWithRoot:(NSString *)root
{
	self = [super init];
	if (self != nil) {
		_root = [root copy];
	}
	return self;
}

- (void)dealloc
{
	[_root release];
	[super dealloc];
}

- (NSString *)trashRoot
{
	if (_root != nil) {
		return _root;
	}
	return [NSHomeDirectory() stringByAppendingPathComponent:@".Trash"];
}

/* THE VOLUME RULE. An item on the home volume goes to the home Trash; one on another volume gets that volume's
 * `.Trash-<uid>` when it can be made, and the home Trash when it cannot. An explicit root wins over both. */
- (NSString *)trashDirectoryForPath:(NSString *)path
{
	NSFileManager *manager = [NSFileManager defaultManager];
	struct stat homeStat, itemStat;
	NSString *homeTrash;
	NSString *root;

	if (_root != nil) {
		return _root;
	}
	homeTrash = [NSHomeDirectory() stringByAppendingPathComponent:@".Trash"];
	if (stat([NSHomeDirectory() UTF8String], &homeStat) != 0 || stat([path UTF8String], &itemStat) != 0
	    || homeStat.st_dev == itemStat.st_dev) {
		return homeTrash;
	}
	root = fn_mount_root(path, itemStat.st_dev);
	{
		NSString *candidate = [root stringByAppendingPathComponent:
			[NSString stringWithFormat:@".Trash-%ld", (long)getuid()]];

		if ([manager fileExistsAtPath:candidate]
		    || [manager createDirectoryAtPath:candidate withIntermediateDirectories:NO
					    attributes:nil error:NULL]) {
			return candidate;
		}
	}
	return homeTrash;
}

- (NSString *)putbackDirectoryForRoot:(NSString *)root
{
	return [root stringByAppendingPathComponent:@".putback"];
}

- (BOOL)writeRecord:(NSDictionary *)record toDirectory:(NSString *)directory
{
	NSData *data = [NSPropertyListSerialization dataWithPropertyList:record
								  format:NSPropertyListXMLFormat_v1_0
								 options:0 error:NULL];
	NSString *name = [record objectForKey:@"trashed"];
	NSString *path;

	if (data == nil || name == nil) {
		return NO;
	}
	path = [directory stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"plist"]];
	return [data writeToFile:path atomically:YES];
}

- (NSArray *)recyclePaths:(NSArray *)paths error:(NSError **)error
{
	NSFileManager *manager = [NSFileManager defaultManager];
	NSMutableArray *items = [[NSMutableArray alloc] init];
	NSUInteger i;

	for (i = 0; i < [paths count]; i++) {
		NSString *source = [paths objectAtIndex:i];
		NSString *root = [self trashDirectoryForPath:source];
		NSString *putback = [self putbackDirectoryForRoot:root];
		NSString *name;
		NSString *destination;
		NSDictionary *record;
		WSTrashItem *item;
		NSString *recordPath;

		if (![manager fileExistsAtPath:source]) {
			[items release];
			if (error != NULL) {
				*error = [NSError errorWithDomain:@"WSTrash" code:1 userInfo:nil];
			}
			return nil;
		}
		if (![manager fileExistsAtPath:root]
		    && ![manager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL]) {
			[items release];
			if (error != NULL) *error = [NSError errorWithDomain:@"WSTrash" code:2 userInfo:nil];
			return nil;
		}
		if (![manager fileExistsAtPath:putback]
		    && ![manager createDirectoryAtPath:putback withIntermediateDirectories:YES attributes:nil error:NULL]) {
			[items release];
			if (error != NULL) *error = [NSError errorWithDomain:@"WSTrash" code:3 userInfo:nil];
			return nil;
		}
		name = fn_unique_name(root, [source lastPathComponent]);
		destination = [root stringByAppendingPathComponent:name];
		if (![manager moveItemAtPath:source toPath:destination error:error]) {
			[items release];
			return nil;
		}
		record = [NSDictionary dictionaryWithObjectsAndKeys:
			source, @"original",
			name, @"trashed",
			[NSDate date], @"date", nil];
		recordPath = [putback stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"plist"]];
		if (![self writeRecord:record toDirectory:putback]) {
			(void)[manager moveItemAtPath:destination toPath:source error:NULL];
			[items release];
			if (error != NULL) *error = [NSError errorWithDomain:@"WSTrash" code:4 userInfo:nil];
			return nil;
		}
		item = [[WSTrashItem alloc] initWithOriginalPath:source trashPath:destination
						       recordPath:recordPath date:[record objectForKey:@"date"]];
		[items addObject:item];
		[item release];
	}
	return [items autorelease];
}

- (NSArray *)items
{
	NSFileManager *manager = [NSFileManager defaultManager];
	NSMutableArray *items = [[NSMutableArray alloc] init];
	NSString *root = [self trashRoot];
	NSString *putback = [self putbackDirectoryForRoot:root];
	NSArray *names = [manager contentsOfDirectoryAtPath:putback error:NULL];
	NSUInteger i;

	for (i = 0; i < [names count]; i++) {
		NSString *name = [names objectAtIndex:i];
		NSString *recordPath = [putback stringByAppendingPathComponent:name];
		NSData *data;
		NSDictionary *record;
		NSString *trashed;
		NSString *trashPath;
		WSTrashItem *item;

		if (![[name pathExtension] isEqual:@"plist"]) {
			continue;
		}
		data = [NSData dataWithContentsOfFile:recordPath];
		record = (data != nil)
			? [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL] : nil;
		if (![record isKindOfClass:[NSDictionary class]]) {
			continue;
		}
		trashed = [record objectForKey:@"trashed"];
		if (trashed == nil) {
			continue;
		}
		trashPath = [root stringByAppendingPathComponent:trashed];
		if (![manager fileExistsAtPath:trashPath]) {
			continue;
		}
		item = [[WSTrashItem alloc] initWithOriginalPath:[record objectForKey:@"original"]
						       trashPath:trashPath
						       recordPath:recordPath
						       date:[record objectForKey:@"date"]];
		[items addObject:item];
		[item release];
	}
	[items sortUsingComparator:^NSComparisonResult(id a, id b) {
		return [[(WSTrashItem *)b date] compare:[(WSTrashItem *)a date]];
	}];
	return [items autorelease];
}

- (BOOL)putBackItem:(WSTrashItem *)item error:(NSError **)error
{
	NSFileManager *manager = [NSFileManager defaultManager];
	NSString *original = [item originalPath];
	NSString *parent = [original stringByDeletingLastPathComponent];

	if (item == nil || ![manager fileExistsAtPath:[item trashPath]]) {
		if (error != NULL) *error = [NSError errorWithDomain:@"WSTrash" code:5 userInfo:nil];
		return NO;
	}
	if (![manager fileExistsAtPath:parent]) {
		if (error != NULL) *error = [NSError errorWithDomain:@"WSTrash" code:6 userInfo:nil];
		return NO;
	}
	if ([manager fileExistsAtPath:original]) {
		if (error != NULL) *error = [NSError errorWithDomain:@"WSTrash" code:7 userInfo:nil];
		return NO;
	}
	if (![manager moveItemAtPath:[item trashPath] toPath:original error:error]) {
		return NO;
	}
	(void)[manager removeItemAtPath:[item recordPath] error:NULL];
	return YES;
}

- (BOOL)putBackItems:(NSArray *)items error:(NSError **)error
{
	NSUInteger i;

	for (i = 0; i < [items count]; i++) {
		if (![self putBackItem:[items objectAtIndex:i] error:error]) {
			return NO;
		}
	}
	return YES;
}

- (BOOL)emptyTrash:(NSError **)error
{
	NSFileManager *manager = [NSFileManager defaultManager];
	NSString *root = [self trashRoot];
	NSString *putback = [self putbackDirectoryForRoot:root];
	NSArray *names = [manager contentsOfDirectoryAtPath:root error:NULL];
	NSUInteger i;

	for (i = 0; i < [names count]; i++) {
		NSString *name = [names objectAtIndex:i];

		if ([name isEqual:@".putback"]) {
			continue;
		}
		if (![manager removeItemAtPath:[root stringByAppendingPathComponent:name] error:error]) {
			return NO;
		}
	}
	names = [manager contentsOfDirectoryAtPath:putback error:NULL];
	for (i = 0; i < [names count]; i++) {
		if (![manager removeItemAtPath:[putback stringByAppendingPathComponent:[names objectAtIndex:i]]
					 error:error]) {
			return NO;
		}
	}
	return YES;
}

@end
