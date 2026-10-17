/*
 * WSMetadataStore.m — the sidecar: read, write, and the values in it.
 *
 * Copyright © 2026 Kyle J. Cardoza. MIT licensed — see LICENSE.
 * SPDX-License-Identifier: MIT
 */
#import "WSMetadataStore.h"

#import <Foundation/NSArray.h>
#import <Foundation/NSData.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSNumber.h>
#import <Foundation/NSPropertyListSerialization.h>
#import <Foundation/NSString.h>
#import <Foundation/NSValue.h>

/* THE NAME AND THE FORMAT ARE AGORA'S. Apple's `.DS_Store` is the MODEL — a per-folder sidecar — and not the
 * encoding; the plan (WORKSPACE-PLAN.md §5.1) says the format is ours, so this is a property list under a name
 * this tree owns. It is VERSIONED from the first write, because a stored icon position is a migration once a
 * person has moved an icon and a format without a version cannot be migrated. */
#define WS_METADATA_NAME	@".agora"
#define WS_METADATA_VERSION	1
#define WS_ICON_DEFAULT_SIZE	64

@implementation WSMetadataStore

+ (instancetype)storeForDirectory:(NSString *)directory
{
	WSMetadataStore *store = [[self alloc] init];

	store->_directory = [directory copy];
	store->_positions = [[NSMutableDictionary alloc] init];
	store->_iconSize = WS_ICON_DEFAULT_SIZE;
	[store load];
	return [store autorelease];
}

- (void)load
{
	NSString *path = [_directory stringByAppendingPathComponent:WS_METADATA_NAME];
	NSData *data = [NSData dataWithContentsOfFile:path];
	id plist;
	NSDictionary *dictionary;
	NSNumber *version;
	NSNumber *size;
	id icons;

	if (data == nil) return;
	plist = [NSPropertyListSerialization propertyListWithData:data
							  options:0
							   format:NULL
							    error:NULL];
	if (![plist isKindOfClass:[NSDictionary class]]) return;

	dictionary = (NSDictionary *)plist;
	version = [dictionary objectForKey:@"version"];
	/* A VERSION WE DO NOT KNOW IS REFUSED WHOLE rather than read field by field: a sidecar from a later
	 * Workspace is not a sidecar this one understands, and guessing at it is how a person's icon positions get
	 * quietly wrong. */
	if (version != nil && [version integerValue] != WS_METADATA_VERSION) return;
	size = [dictionary objectForKey:@"iconSize"];
	if (size != nil) _iconSize = [size integerValue];
	icons = [dictionary objectForKey:@"icons"];
	if ([icons isKindOfClass:[NSDictionary class]]) {
		[_positions release];
		_positions = [[NSMutableDictionary alloc] initWithDictionary:(NSDictionary *)icons];
	}
}

- (BOOL)hasIconPositionForName:(NSString *)name
{
	return name != nil && [_positions objectForKey:name] != nil;
}

- (NSPoint)iconPositionForName:(NSString *)name
{
	NSArray *pair = (name != nil) ? [_positions objectForKey:name] : nil;

	if (![pair isKindOfClass:[NSArray class]] || [pair count] < 2) return NSZeroPoint;
	return NSMakePoint((CGFloat)[[pair objectAtIndex:0] doubleValue],
			   (CGFloat)[[pair objectAtIndex:1] doubleValue]);
}

- (void)setIconPosition:(NSPoint)position forName:(NSString *)name
{
	if (name == nil) return;
	[_positions setObject:[NSArray arrayWithObjects:
					[NSNumber numberWithDouble:(double)position.x],
					[NSNumber numberWithDouble:(double)position.y],
					nil]
		       forKey:name];
}

- (void)removeIconPositionForName:(NSString *)name
{
	if (name != nil) [_positions removeObjectForKey:name];
}

- (NSInteger)iconSize
{
	return _iconSize;
}

- (void)setIconSize:(NSInteger)size
{
	if (size >= 16 && size <= 512) _iconSize = size;
}

- (BOOL)save
{
	NSDictionary *dictionary = [NSDictionary dictionaryWithObjectsAndKeys:
		[NSNumber numberWithInteger:WS_METADATA_VERSION], @"version",
		[NSNumber numberWithInteger:_iconSize], @"iconSize",
		_positions, @"icons",
		nil];
	NSData *data = [NSPropertyListSerialization dataWithPropertyList:dictionary
								  format:NSPropertyListXMLFormat_v1_0
								 options:0
								   error:NULL];
	if (data == nil) return NO;
	return [data writeToFile:[_directory stringByAppendingPathComponent:WS_METADATA_NAME]
		      atomically:YES];
}

- (void)dealloc
{
	[_directory release];
	[_positions release];
	[super dealloc];
}

@end
