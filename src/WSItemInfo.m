/*
 * WSItemInfo.m — one stat(2) per item, and the sentences an inspector reads out of it.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#import "WSItemInfo.h"

#import "WSItemKind.h"
#import "WSItemModel.h"

#import <Foundation/NSByteCountFormatter.h>
#import <Foundation/NSDate.h>
#import <Foundation/NSDateFormatter.h>
#import <Foundation/NSFileManager.h>
#import <Foundation/NSLocale.h>
#import <Foundation/NSNumber.h>
#import <Foundation/NSNumberFormatter.h>
#import <Foundation/NSPathUtilities.h>
#import <Foundation/NSString.h>

#import <AppKit/NSButtonCell.h>		/* NSOnState/NSOffState/NSMixedState */

#include <grp.h>
#include <pwd.h>
#include <string.h>
#include <sys/stat.h>

/* **THE FIELDS ARE THE FILE'S, AND `stat` IS THE ONE CALL THAT HAS THEM ALL.** Size, the owner and group bits, the
 * three times and the space actually allocated (`st_blocks`, in 512-byte units — the number the reference file manager
 * prints as "on disk") come from one syscall. Only the owner and group NAMES are not in it, and those are the account
 * database's: a uid with no passwd entry falls back to the number rather than to an empty cell.
 */
typedef struct {
	struct stat st;
	BOOL valid;
} WSStat;

static WSStat WSStatForPath(NSString *path)
{
	WSStat s;

	memset(&s, 0, sizeof(s));
	if (path == nil) {
		return s;
	}
	s.valid = (stat([path fileSystemRepresentation], &s.st) == 0);
	return s;
}

static NSString *WSAccountNameForID(uid_t uid)
{
	struct passwd *pw = getpwuid(uid);

	return (pw != NULL && pw->pw_name != NULL)
		? [NSString stringWithUTF8String:pw->pw_name]
		: [NSString stringWithFormat:@"%lu", (unsigned long)uid];
}

static NSString *WSGroupNameForID(gid_t gid)
{
	struct group *gr = getgrgid(gid);

	return (gr != NULL && gr->gr_name != NULL)
		? [NSString stringWithUTF8String:gr->gr_name]
		: [NSString stringWithFormat:@"%lu", (unsigned long)gid];
}

/* **"WHERE" IS THE FOLDER'S NAME, WHICH IS WHAT A PERSON RECOGNISES.** A full path in the Where line is a path in the
 * one place a person wanted an answer; the parent's own name is what the reference file manager prints, and the
 * inspector's Name & Extension section is where the full name lives. */
static NSString *WSWhereNameForPath(NSString *path)
{
	NSString *parent = [path stringByDeletingLastPathComponent];

	if ([parent length] == 0) {
		return nil;
	}
	if ([parent isEqual:@"/"]) {
		return @"/";
	}
	return [parent lastPathComponent];
}

@implementation WSItemPermission

- (instancetype)initWithName:(NSString *)name privilege:(NSString *)privilege isOwner:(BOOL)isOwner
{
	self = [super init];
	if (self == nil) {
		return nil;
	}
	_name = [name copy];
	_privilege = [privilege copy];
	_isOwner = isOwner;
	return self;
}

- (void)dealloc
{
	[_name release];
	[_privilege release];
	[super dealloc];
}

- (NSString *)name
{
	return _name;
}

- (NSString *)privilege
{
	return _privilege;
}

- (BOOL)isOwner
{
	return _isOwner;
}

@end

@implementation WSItemInfo

+ (instancetype)infoForPaths:(NSArray *)paths
{
	WSItemInfo *info;
	NSString *firstOwner = nil;
	NSString *firstGroup = nil;
	NSString *firstKind = nil;
	NSString *firstWhere = nil;
	NSDate *firstCreated = nil;
	NSDate *firstModified = nil;
	NSDate *firstOpened = nil;
	mode_t firstMode = 0;
	NSUInteger i;

	if ([paths count] == 0) {
		return nil;
	}
	info = [[[self alloc] init] autorelease];
	info->_paths = [paths copy];
	info->_count = [paths count];
	info->_countsItems = YES;
	info->_lockedState = NSOnState;

	for (i = 0; i < [paths count]; i++) {
		NSString *path = [paths objectAtIndex:i];
		WSStat s = WSStatForPath(path);
		NSString *owner;
		NSString *group;
		NSString *kind = nil;
		NSString *where = nil;
		NSDate *created = nil;
		NSDate *modified = nil;
		NSDate *opened = nil;
		NSUInteger items = 0;
		BOOL isDirectory = s.valid && S_ISDIR(s.st.st_mode);

		if (!s.valid) {
			/* AN ITEM THAT VANISHED. Its facts are simply absent — the sizes add nothing, the dates disagree with
			 * everything — rather than the whole window refusing: Get Info is often open on something a command
			 * elsewhere just moved. */
			info->_countsItems = NO;
			continue;
		}

		owner = WSAccountNameForID(s.st.st_uid);
		group = WSGroupNameForID(s.st.st_gid);
		where = WSWhereNameForPath(path);
		/* THE KIND IS LAUNCH SERVICES', through the same door the Kind column uses — a folder is "Folder" because a
		 * person reads "Folder", and an application bundle is asked about like a file. */
		kind = [WSItemKind kindForItem:[[[WSItem alloc] initWithName:[path lastPathComponent]
							      path:path
						       isDirectory:isDirectory] autorelease]];

		{
			NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
			id value = [attributes objectForKey:NSFileCreationDate];

			if ([value isKindOfClass:[NSDate class]]) {
				created = (NSDate *)value;
			}
		}
		modified = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)s.st.st_mtime];
		opened = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)s.st.st_atime];

		if (isDirectory) {
			NSArray *children = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:NULL];

			items = [children count];
		} else {
			info->_countsItems = NO;
		}

		info->_byteCount += (unsigned long long)s.st.st_size;
		info->_onDiskByteCount += (unsigned long long)s.st.st_blocks * 512ULL;
		info->_itemCount += items;

		/* THE LOCKED BOX IS THE OWNER'S WRITE BIT, which is the thing a person means by "this file is locked": the
		 * account that owns it may no longer change it. Mixed across a selection it is a mixed state, not a lie. */
		if ((s.st.st_mode & S_IWUSR) != 0) {
			if (info->_lockedState == NSOnState) {
				info->_lockedState = NSOffState;
			}
		} else if (info->_lockedState == NSOffState) {
			info->_lockedState = NSMixedState;
		}

		if (i == 0) {
			firstOwner = owner;
			firstGroup = group;
			firstKind = kind;
			firstWhere = where;
			firstCreated = created;
			firstModified = modified;
			firstOpened = opened;
			firstMode = s.st.st_mode;
			info->_name = [[path lastPathComponent] copy];
		} else {
			if (![firstKind isEqual:kind]) firstKind = nil;
			if (![firstWhere isEqual:where]) firstWhere = nil;
			if (firstMode != s.st.st_mode) info->_mixedPermissions = YES;
			if (![firstCreated isEqual:created]) firstCreated = nil;
			if (![firstModified isEqual:modified]) firstModified = nil;
			if (![firstOpened isEqual:opened]) firstOpened = nil;
			info->_name = nil;	/* one name for many is a question, not a value */
		}
	}

	info->_kind = [firstKind copy];
	info->_where = [firstWhere copy];
	info->_createdDate = [firstCreated retain];
	info->_modifiedDate = [firstModified retain];
	info->_lastOpenedDate = [firstOpened retain];
	info->_ownerName = [firstOwner copy];
	info->_groupName = [firstGroup copy];
	info->_mode = firstMode;
	return info;
}

- (void)dealloc
{
	[_paths release];
	[_name release];
	[_kind release];
	[_where release];
	[_createdDate release];
	[_modifiedDate release];
	[_lastOpenedDate release];
	[_ownerName release];
	[_groupName release];
	[super dealloc];
}

- (NSArray *)paths { return _paths; }
- (NSUInteger)count { return _count; }
- (BOOL)isMultiple { return _count > 1; }
- (NSString *)name { return _name; }
- (NSString *)kind { return _kind; }
- (NSString *)where { return _where; }
- (NSDate *)creationDate { return _createdDate; }
- (NSDate *)modificationDate { return _modifiedDate; }
- (NSDate *)lastOpenedDate { return _lastOpenedDate; }
- (unsigned long long)byteCount { return _byteCount; }
- (unsigned long long)onDiskByteCount { return _onDiskByteCount; }
- (BOOL)countsItems { return _countsItems; }
- (NSUInteger)itemCount { return _itemCount; }
- (NSInteger)lockedState { return _lockedState; }
- (NSString *)ownerName { return _ownerName; }
- (NSString *)groupName { return _groupName; }
- (mode_t)mode { return _mode; }
- (BOOL)mixedPermissions { return _mixedPermissions; }

- (NSArray *)permissions
{
	NSMutableArray *rows = [[NSMutableArray alloc] init];
	NSString *owner = [self ownerName];
	NSString *group = [self groupName];
	NSString *ownerName;

	/* **"(Me)" IS WHOSE ROW IT IS, NOT WHO THE FILE BELONGS TO.** The reference file manager marks the row that is the
	 * person reading it, which is why the account's own name carries the parenthetical — the file's owner may be
	 * somebody else entirely, and then the row says that name with no "(Me)". */
	ownerName = [owner isEqual:NSUserName()]
		? [NSString stringWithFormat:@"%@ (Me)", owner]
		: owner;
	[rows addObject:[[[WSItemPermission alloc] initWithName:(ownerName != nil ? ownerName : @"")
						     privilege:[WSItemInfo privilegeForMode:_mode class:0]
						       isOwner:YES] autorelease]];
	[rows addObject:[[[WSItemPermission alloc] initWithName:(group != nil ? group : @"")
						     privilege:[WSItemInfo privilegeForMode:_mode class:1]
						       isOwner:NO] autorelease]];
	[rows addObject:[[[WSItemPermission alloc] initWithName:@"everyone"
						     privilege:[WSItemInfo privilegeForMode:_mode class:2]
						       isOwner:NO] autorelease]];
	return [rows autorelease];
}

- (NSString *)permissionSummary
{
	return [WSItemInfo summaryForMode:_mode];
}

/* ---- THE STRINGS ---------------------------------------------------------------------------------------------- */

+ (NSString *)sizeDescriptionForBytes:(unsigned long long)bytes onDisk:(unsigned long long)onDisk
{
	NSNumberFormatter *grouping = [[[NSNumberFormatter alloc] init] autorelease];
	NSString *exact;
	NSString *scaled;

	[grouping setNumberStyle:NSNumberFormatterDecimalStyle];
	exact = [grouping stringFromNumber:[NSNumber numberWithUnsignedLongLong:bytes]];
	if (exact == nil) {
		exact = [NSString stringWithFormat:@"%llu", bytes];
	}
	scaled = [NSByteCountFormatter stringFromByteCount:(long long)onDisk
						countStyle:NSByteCountFormatterCountStyleFile];
	return [NSString stringWithFormat:@"%@ bytes (%@ on disk)", exact, scaled];
}

+ (NSString *)itemCountDescription:(NSUInteger)count
{
	return [NSString stringWithFormat:@"for %lu item%@",
		(unsigned long)count, (count == 1) ? @"" : @"s"];
}

+ (NSString *)dateDescription:(NSDate *)date
{
	NSDateFormatter *formatter;

	if (date == nil) {
		return @"—";
	}
	/* **"TODAY" IS THE FORMATTER'S, NOT OURS.** `doesRelativeDateFormatting` is ICU's own rule for the words around
	 * the day, so the string is "Today, 10:51 PM" in English and whatever the locale says elsewhere — a hand-rolled
	 * "Today" would be the one string in the window that ignores the locale. */
	formatter = [[[NSDateFormatter alloc] init] autorelease];
	[formatter setDateStyle:NSDateFormatterMediumStyle];
	[formatter setTimeStyle:NSDateFormatterShortStyle];
	[formatter setDoesRelativeDateFormatting:YES];
	return [formatter stringFromDate:date];
}

+ (NSString *)privilegeForMode:(mode_t)mode class:(NSInteger)whichClass
{
	mode_t bits;

	if (whichClass == 0) {
		bits = (mode_t)((mode >> 6) & 7);
	} else if (whichClass == 1) {
		bits = (mode_t)((mode >> 3) & 7);
	} else {
		bits = (mode_t)(mode & 7);
	}
	if ((bits & 6) == 6) {
		return @"Read & Write";
	}
	if ((bits & 4) != 0) {
		return @"Read only";
	}
	if ((bits & 2) != 0) {
		return @"Write only";
	}
	return @"No access";
}

+ (NSString *)summaryForMode:(mode_t)mode
{
	if ((mode & S_IRUSR) != 0 && (mode & S_IWUSR) != 0) {
		return @"You can read and write";
	}
	if ((mode & S_IRUSR) != 0) {
		return @"You can only read";
	}
	if ((mode & S_IWUSR) != 0) {
		return @"You can only write";
	}
	return @"You have no access";
}

@end
