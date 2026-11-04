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

#import <Foundation/NSAutoreleasePool.h>
#import <Foundation/NSByteCountFormatter.h>
#import <Foundation/NSDate.h>
#import <Foundation/NSDateFormatter.h>
#import <Foundation/NSFileManager.h>
#import <Foundation/NSLocale.h>
#import <Foundation/NSNumber.h>
#import <Foundation/NSNumberFormatter.h>
#import <Foundation/NSPathUtilities.h>
#import <Foundation/NSString.h>
#import <Foundation/NSThread.h>

#import <AppKit/NSButtonCell.h>		/* NSOnState/NSOffState/NSMixedState */

#include <dirent.h>
#include <grp.h>
#include <limits.h>
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

/* **THE WALK ITSELF: `lstat`, ADD, DESCEND.** The directory's own block is counted with its children (which is what
 * `du` does and what makes an empty folder report its 4 KB rather than zero), no symlink is followed, and an entry whose
 * full path would not fit is skipped rather than counted at the wrong path. */
static void fn_measure_directory(const char *path, unsigned long long *bytes, unsigned long long *onDisk,
				 unsigned long long *items)
{
	DIR *directory;
	struct dirent *entry;

	directory = opendir(path);
	if (directory == NULL) {
		return;
	}
	while ((entry = readdir(directory)) != NULL) {
		char child[PATH_MAX];
		struct stat s;
		int written;

		if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
			continue;
		}
		written = snprintf(child, sizeof(child), "%s/%s", path, entry->d_name);
		if (written <= 0 || written >= (int)sizeof(child)) {
			continue;
		}
		if (lstat(child, &s) != 0) {
			continue;
		}
		*items += 1;
		*bytes += (unsigned long long)s.st_size;
		*onDisk += (unsigned long long)s.st_blocks * 512ULL;
		if (S_ISDIR(s.st_mode)) {
			fn_measure_directory(child, bytes, onDisk, items);
		}
	}
	closedir(directory);
}

/* **ONE WALK IN FLIGHT AND ONE ANSWER, AND THE REQUEST OWNS ITSELF UNTIL IT DELIVERS.** `-cg_run:` is the thread — it
 * touches no view, no window and no image, and keeps a pool of its own — and `-cg_deliver:` is the main thread's half. The
 * object starts with a retain that only `-cg_deliver:` lets go, so neither the walking thread nor the queued continuation
 * can find it freed. */
@interface WSItemMeasureRequest : NSObject
{
	NSArray *_paths;	/* COPIED */
	id _target;		/* RETAINED until the answer has been delivered */
	SEL _selector;
	NSArray *_result;	/* RETAINED once the walk has answered */
}
- (instancetype)initWithPaths:(NSArray *)paths target:(id)target selector:(SEL)selector;
@end

@implementation WSItemMeasureRequest

- (instancetype)initWithPaths:(NSArray *)paths target:(id)target selector:(SEL)selector
{
	self = [super init];
	if (self == nil) {
		return nil;
	}
	_paths = [paths copy];
	_target = [target retain];
	_selector = selector;
	return self;
}

- (void)dealloc
{
	[_paths release];
	[_target release];
	[_result release];
	[super dealloc];
}

- (void)cg_run:(id)ignored
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	unsigned long long bytes = 0;
	unsigned long long onDisk = 0;
	unsigned long long items = 0;
	BOOL countsItems = NO;

	(void)ignored;
	[WSItemInfo cg_measurePaths:_paths bytes:&bytes onDisk:&onDisk items:&items countsItems:&countsItems];
	_result = [[NSArray alloc] initWithObjects:
		[NSNumber numberWithUnsignedLongLong:bytes],
		[NSNumber numberWithUnsignedLongLong:onDisk],
		[NSNumber numberWithUnsignedLongLong:items],
		[NSNumber numberWithBool:countsItems],
		_paths,
		nil];
	[self performSelectorOnMainThread:@selector(cg_deliver:) withObject:nil waitUntilDone:NO];
	[pool release];
}

- (void)cg_deliver:(id)ignored
{
	NSArray *result = [[_result retain] autorelease];

	(void)ignored;
	[_target performSelector:_selector withObject:result];
	[self release];			/* the retain that kept the request alive from -cg_run: */
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
		{
			NSInteger locked = ((s.st.st_mode & S_IWUSR) == 0) ? NSOnState : NSOffState;

			if (i == 0) {
				info->_lockedState = locked;
			} else if (info->_lockedState != locked) {
				info->_lockedState = NSMixedState;
			}
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


+ (void)cg_measurePathsInBackground:(NSArray *)paths target:(id)target selector:(SEL)selector
{
	WSItemMeasureRequest *request;

	if ([paths count] == 0 || target == nil || selector == NULL) {
		return;
	}
	request = [[WSItemMeasureRequest alloc] initWithPaths:paths target:target selector:selector];
	/* **THE REQUEST IS NOT RELEASED HERE.** Its first retain is the thread's until `-cg_deliver:` drops it; releasing it
	 * after handing it to a detached thread would be the object freeing itself while `-cg_run:` is still walking. */
	[NSThread detachNewThreadSelector:@selector(cg_run:) toTarget:request withObject:nil];
}

+ (void)cg_measurePaths:(NSArray *)paths
		  bytes:(unsigned long long *)bytes
		 onDisk:(unsigned long long *)onDisk
		  items:(unsigned long long *)items
	    countsItems:(BOOL *)countsItems
{
	unsigned long long totalBytes = 0;
	unsigned long long totalDisk = 0;
	unsigned long long totalItems = 0;
	BOOL allDirectories = ([paths count] > 0);
	NSUInteger i;

	for (i = 0; i < [paths count]; i++) {
		struct stat s;

		if (lstat([[paths objectAtIndex:i] fileSystemRepresentation], &s) != 0) {
			allDirectories = NO;
			continue;
		}
		totalBytes += (unsigned long long)s.st_size;
		totalDisk += (unsigned long long)s.st_blocks * 512ULL;
		if (S_ISDIR(s.st_mode)) {
			fn_measure_directory([[paths objectAtIndex:i] fileSystemRepresentation],
					     &totalBytes, &totalDisk, &totalItems);
		} else {
			allDirectories = NO;
		}
	}
	if (bytes != NULL) {
		*bytes = totalBytes;
	}
	if (onDisk != NULL) {
		*onDisk = totalDisk;
	}
	if (items != NULL) {
		*items = totalItems;
	}
	if (countsItems != NULL) {
		*countsItems = allDirectories;
	}
}

- (void)cg_setBytes:(unsigned long long)bytes
	     onDisk:(unsigned long long)onDisk
	      items:(NSUInteger)items
	countsItems:(BOOL)countsItems
{
	_byteCount = bytes;
	_onDiskByteCount = onDisk;
	_itemCount = items;
	_countsItems = countsItems;
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

/* **THE FOUR CHOICES, IN THE POPUP'S ORDER.** Index 0 is the pair of bits (rw), 1 and 2 are one bit each, and 3 is
 * none of them — the order the reference file manager's own menu uses. */
+ (NSArray *)privilegeTitles
{
	return [NSArray arrayWithObjects:@"Read & Write", @"Read only", @"Write only", @"No access", nil];
}

- (NSInteger)privilegeIndexForClass:(NSInteger)whichClass
{
	mode_t bits;

	if (_mixedPermissions) {
		return NSNotFound;
	}
	if (whichClass == 0) {
		bits = (mode_t)((_mode >> 6) & 7);
	} else if (whichClass == 1) {
		bits = (mode_t)((_mode >> 3) & 7);
	} else {
		bits = (mode_t)(_mode & 7);
	}
	if ((bits & 6) == 6) {
		return 0;
	}
	if ((bits & 4) != 0) {
		return 1;
	}
	if ((bits & 2) != 0) {
		return 2;
	}
	return 3;
}

+ (mode_t)modeForPrivilegeIndex:(NSInteger)index class:(NSInteger)whichClass
{
	mode_t bits;
	NSInteger shift;

	switch (index) {
	case 0: bits = 6; break;
	case 1: bits = 4; break;
	case 2: bits = 2; break;
	case 3: bits = 0; break;
	default: return (mode_t)0;
	}
	shift = (whichClass == 0) ? 6 : ((whichClass == 1) ? 3 : 0);
	return (mode_t)(bits << shift);
}

+ (BOOL)cg_setPrivilegeIndex:(NSInteger)index forClass:(NSInteger)whichClass paths:(NSArray *)paths
{
	mode_t replacement = [self modeForPrivilegeIndex:index class:whichClass];
	NSInteger shift = (whichClass == 0) ? 6 : ((whichClass == 1) ? 3 : 0);
	/* **THE CLASS'S THREE BITS, NOT THE TWO THE MENU NAMES.** "Read only" means read and NOT execute — a file that was
	 * rwx and is set to read-only is r--, not r-x — so the execute bit is cleared with the write one. */
	mode_t mask = (mode_t)(7 << shift);
	BOOL ok = YES;
	NSUInteger i;

	if (index < 0 || index > 3 || [paths count] == 0) {
		return NO;
	}
	for (i = 0; i < [paths count]; i++) {
		NSString *path = [paths objectAtIndex:i];
		struct stat s;

		if (stat([path fileSystemRepresentation], &s) != 0) {
			ok = NO;
			continue;
		}
		if (chmod([path fileSystemRepresentation], (s.st_mode & ~mask) | replacement) != 0) {
			ok = NO;
		}
	}
	return ok;
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
