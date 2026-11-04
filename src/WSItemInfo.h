/*
 * WSItemInfo.h — what Get Info knows about one item, or about a selection of them.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **THE WINDOW ASKS, THIS ANSWERS, AND THE ANSWER IS A VALUE.** Every fact an inspector shows is gathered here, once,
 * from `stat(2)` and the Launch Services kind string — so the window has no reading code of its own, a probe can check
 * the numbers without a window, and the strings a person reads (a size, a privilege, a date) are produced by the same
 * functions the window draws.
 *
 * **A SELECTION IS ONE ANSWER TOO, AND "MIXED" IS A VALUE.** Get Info on five items is the same window with the
 * questions that cannot be summed left blank — a name, a kind, a date that differs. The blank is deliberate and
 * carries no sentinel string: `-name`/`-kind`/`-where`/the dates answer nil when the items disagree, and the window
 * draws "—" where a value is missing. What CAN be summed is summed: bytes, and the on-disk bytes.
 *
 * **WHAT IS NOT MEASURED, SAID HERE RATHER THAN GUESSED.** The size of a folder is its own directory allocation, not
 * the total of the tree below it: a recursive walk of a 200 GB folder would block the window for as long as it took,
 * and "9.73 GB for 185 items" would be a number that was true at the moment a person clicked. The item count IS
 * measured (one listing, no descent) and says how much is behind the number. Creation date is the file system's when it
 * has one — this substrate records no birth time, so it is usually nil — and "Last opened" is the access time.
 */
#ifndef WORKSPACE_WSITEMINFO_H
#define WORKSPACE_WSITEMINFO_H

#import <Foundation/NSArray.h>
#import <Foundation/NSObject.h>

#include <sys/types.h>

@class NSDate;
@class NSString;

NS_ASSUME_NONNULL_BEGIN

/* One row of the Sharing & Permissions table: who, and what they may do. A plain object rather than a dictionary
 * because the table asks two questions of a row and a keyed lookup would make both of them strings. */
@interface WSItemPermission : NSObject
{
	NSString *_name;		/* COPIED: the person or the group, or "everyone" */
	NSString *_privilege;		/* COPIED: "Read & Write", "Read only", … */
	BOOL _isOwner;
}
- (instancetype)initWithName:(NSString *)name privilege:(NSString *)privilege isOwner:(BOOL)isOwner;
- (NSString *)name;
- (NSString *)privilege;
- (BOOL)isOwner;
@end

@interface WSItemInfo : NSObject
{
	NSArray *_paths;		/* COPIED */
	NSUInteger _count;
	NSString *_name;		/* nil for a multiple selection */
	NSString *_kind;		/* nil when the items disagree */
	NSString *_where;		/* the enclosing folder's name; nil when they disagree */
	NSDate *_createdDate;		/* nil when unknown or when the items disagree */
	NSDate *_modifiedDate;
	NSDate *_lastOpenedDate;
	unsigned long long _byteCount;
	unsigned long long _onDiskByteCount;
	NSUInteger _itemCount;		/* the children summed over the items that are folders */
	BOOL _countsItems;		/* NO when any selected item is not a folder */
	NSInteger _lockedState;		/* NSOnState/NSOffState, or NSMixedState for a mixed selection */
	NSString *_ownerName;
	NSString *_groupName;
	mode_t _mode;			/* the first item's, and `_mixedPermissions` says how much to trust it */
	BOOL _mixedPermissions;
}

/* **THE ONE DOOR.** A single item is the same call with one path in the array. An empty array answers nil: there is
 * nothing to inspect, and a window showing nothing about nothing is the caller's mistake rather than a shape to carry. */
+ (nullable instancetype)infoForPaths:(NSArray *)paths;

- (NSArray *)paths;
- (NSUInteger)count;
- (BOOL)isMultiple;

/* The facts, as values. Nil means "no single answer" — a multiple selection, or a file system with no such attribute. */
- (nullable NSString *)name;
- (nullable NSString *)kind;
- (nullable NSString *)where;
- (nullable NSDate *)creationDate;
- (nullable NSDate *)modificationDate;
- (nullable NSDate *)lastOpenedDate;

- (unsigned long long)byteCount;
- (unsigned long long)onDiskByteCount;

/* How many things the folder holds, and whether that number means anything for this selection: a file has no items, so
 * the window says nothing rather than "for 0 items". */
- (BOOL)countsItems;
- (NSUInteger)itemCount;

/* The Locked box's three states: on when nothing selected is writable by its owner, off when all are, mixed otherwise. */
- (NSInteger)lockedState;

/* **THE PERMISSIONS ARE THE FIRST ITEM'S WHEN THEY AGREE, AND SAID SO WHEN THEY DO NOT.** `-mixedPermissions` is what
 * the window draws as "—" in the privilege column; the rows still exist, because who is on them (the owner, the group,
 * everyone) does not change with the mode. */
- (nullable NSString *)ownerName;
- (nullable NSString *)groupName;
- (mode_t)mode;
- (BOOL)mixedPermissions;
- (NSArray *)permissions;		/* NSArray<WSItemPermission *>: owner, group, everyone */
- (NSString *)permissionSummary;	/* "You can read and write", "You can only read", … */

/* ---- THE SIZE A FOLDER REALLY IS ------------------------------------------------------------------------------
 *
 * **A DIRECTORY'S OWN `stat` IS NOT ITS SIZE.** `st_size` for a folder is one entry block — 4,096 bytes, or 140 on this
 * machine's `/tmp` — and `st_blocks` is often zero, so the shallow number an item carries says nothing about what is
 * inside it. The REAL total is the sum over the tree, and that is what `+cg_measurePaths:` answers: the bytes, the space
 * actually allocated, and how many entries were counted. **A PACKAGE IS A DIRECTORY AND IS WALKED LIKE ONE**, which is
 * what makes an application bundle report its `Contents` rather than one folder entry.
 *
 * **AND IT IS A SEPARATE PASS BECAUSE IT IS NOT FREE.** MEASURED here: 12.9 ms over 3,801 entries (Downloads), 41.6 ms
 * over a 10,400-entry source tree, and 7.7 s for `/usr`. So it has no business on the main thread while a window is
 * built: the inspector opens with the shallow number, runs this on a thread, and patches the window when it answers.
 * Symlinks are counted, not followed — that is what stops a tree from looping.
 */
+ (void)cg_measurePaths:(NSArray *)paths
		  bytes:(unsigned long long *)bytes
		 onDisk:(unsigned long long *)onDisk
		  items:(unsigned long long *)items
	    countsItems:(BOOL *)countsItems;

/* **THE SAME WALK, OFF THE MAIN THREAD, FOR A CALLER THAT HAS A WINDOW TO KEEP RESPONSIVE.** The target hears
 * `selector` on the MAIN thread with one argument: an array of `@[ bytes, onDisk, items, countsItems, paths ]` — the four
 * numbers `+cg_measurePaths:` answers and the selection they answer about, so a caller whose subject changed while the
 * walk was out can tell and drop it. The helper KEEPS THE TARGET ALIVE until it has delivered, which is what makes a
 * view that is removed mid-walk safe; a target that wants the answer to outlive itself must copy what it needs. */
+ (void)cg_measurePathsInBackground:(NSArray *)paths target:(id)target selector:(SEL)selector;

/* The measured total handed back to the value the window is about. */
- (void)cg_setBytes:(unsigned long long)bytes
	     onDisk:(unsigned long long)onDisk
	      items:(NSUInteger)items
	countsItems:(BOOL)countsItems;

/* ---- THE STRINGS A PERSON READS, AS CLASS FUNCTIONS ------------------------------------------------------------
 *
 * Public because the window and the probe must agree on them down to the last comma, and because each one is a
 * decision worth being able to read on its own: the size line has three parts, the date line is relative, and a
 * privilege is a phrase rather than a letter.
 */
+ (NSString *)sizeDescriptionForBytes:(unsigned long long)bytes onDisk:(unsigned long long)onDisk;
+ (NSString *)itemCountDescription:(NSUInteger)count;		/* "for 185 items" */
+ (NSString *)dateDescription:(nullable NSDate *)date;		/* "Today, 10:51 PM" */
+ (NSString *)privilegeForMode:(mode_t)mode class:(NSInteger)whichClass;	/* 0 owner, 1 group, 2 everyone */
+ (NSString *)summaryForMode:(mode_t)mode;			/* the owner's sentence */

/* ---- AND THE OTHER DIRECTION, BECAUSE THE PRIVILEGE IS EDITABLE ------------------------------------------------
 *
 * A privilege is a choice of four, and the window offers exactly those four in a popup. The index is the popup's
 * order — "Read & Write", "Read only", "Write only", "No access" — and it maps to the class's three mode bits and
 * back, so the menu, the table's cell and the chmod all speak one vocabulary.
 */
+ (NSArray *)privilegeTitles;
- (NSInteger)privilegeIndexForClass:(NSInteger)whichClass;	/* NSNotFound when the selection is mixed */
+ (mode_t)modeForPrivilegeIndex:(NSInteger)index class:(NSInteger)whichClass;

/* **THE WRITE, ON EVERY SELECTED PATH, KEEPING EVERY OTHER BIT.** One class's three bits are replaced and the rest of
 * the mode is left alone, which is what the reference file manager's popup does and what stops a privilege change from
 * silently making a file executable or stripping the setuid bit. NO when any path refused by the kernel. */
+ (BOOL)cg_setPrivilegeIndex:(NSInteger)index forClass:(NSInteger)whichClass paths:(NSArray *)paths;

@end

NS_ASSUME_NONNULL_END

#endif /* WORKSPACE_WSITEMINFO_H */
