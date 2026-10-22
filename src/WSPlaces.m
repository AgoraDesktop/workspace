/*
 * WSPlaces.m — the sidebar's data, and the desktop path.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Portions of this file may derive from GNUstep; see THIRD-PARTY.md.
 */
#import "WSPlaces.h"

#import <Foundation/NSFileManager.h>
#import <Foundation/NSString.h>

#include <stdlib.h>

@implementation WSPlace

- (instancetype)initWithTitle:(NSString *)title path:(NSString *)path
{
	self = [super init];
	if (self != nil) {
		_title = [title copy];
		_path = [path copy];
	}
	return self;
}

- (void)dealloc
{
	[_title release];
	[_path release];
	[super dealloc];
}

- (NSString *)title { return _title; }
- (NSString *)path { return _path; }

@end

@implementation WSPlaceSection

- (instancetype)initWithTitle:(NSString *)title places:(NSArray *)places
{
	self = [super init];
	if (self != nil) {
		_title = [title copy];
		_places = [places retain];
	}
	return self;
}

- (void)dealloc
{
	[_title release];
	[_places release];
	[super dealloc];
}

- (NSString *)title { return _title; }
- (NSArray *)places { return _places; }

@end

@implementation WSPlaces

+ (NSString *)desktopDirectory
{
	const char *named = getenv("AGORA_DESKTOP");

	if (named != NULL && *named != '\0') {
		return [NSString stringWithUTF8String:named];
	}
	return [NSHomeDirectory() stringByAppendingPathComponent:@"Desktop"];
}

/* THE APPLICATIONS FOLDER IS A FACT ABOUT THE MACHINE, so it is looked for rather than assumed: `/Applications`
 * when it exists, the user's own otherwise, and the root as the last honest answer. A place that names a folder
 * that is not there would be a sidebar row that navigates to nothing. */
+ (NSString *)applicationsDirectory
{
	NSFileManager *manager = [NSFileManager defaultManager];
	NSString *system = @"/Applications";
	NSString *user = [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"];
	BOOL isDirectory = NO;

	if ([manager fileExistsAtPath:system isDirectory:&isDirectory] && isDirectory) {
		return system;
	}
	if ([manager fileExistsAtPath:user isDirectory:&isDirectory] && isDirectory) {
		return user;
	}
	return @"/";
}

+ (NSArray *)sections
{
	NSArray *places = [NSArray arrayWithObjects:
		[[[WSPlace alloc] initWithTitle:@"Desktop" path:[self desktopDirectory]] autorelease],
		[[[WSPlace alloc] initWithTitle:@"Home" path:NSHomeDirectory()] autorelease],
		[[[WSPlace alloc] initWithTitle:@"Applications" path:[self applicationsDirectory]] autorelease],
		nil];
	NSArray *devices = [NSArray arrayWithObjects:
		[[[WSPlace alloc] initWithTitle:@"Computer" path:@"/"] autorelease],
		nil];

	return [NSArray arrayWithObjects:
		[[[WSPlaceSection alloc] initWithTitle:@"PLACES" places:places] autorelease],
		[[[WSPlaceSection alloc] initWithTitle:@"DEVICES" places:devices] autorelease],
		nil];
}

@end
