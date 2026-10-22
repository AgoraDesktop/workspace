/*
 * WSTrash.h — the Trash: a recycled item, where it came from, and how to put it back.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **THE TRASH IS THE FILE MANAGER'S OPERATION, NOT THE DOCK'S ICON.** The Dock owns the picture; Workspace owns the
 * directories, the Put Back records and the empty. The default directory is `~/.Trash` for items on the home volume
 * and a per-volume `.Trash-<uid>` (falling back to the home trash when that volume is not writable); a test may hand
 * the trash an explicit root, which is also how a probe keeps its recycling out of the real home directory.
 *
 * A RECORD IS A PLIST BESIDE THE TRASHED ITEM under `.putback/`: the original path, the trashed name and the date.
 * That is what Put Back reads, so a relaunch can still put an item back. The format is this tier's own, in the
 * property-list format the rest of the tree writes.
 */
#ifndef WORKSPACE_WSTRASH_H
#define WORKSPACE_WSTRASH_H

#import <Foundation/NSArray.h>
#import <Foundation/NSObject.h>

@class NSDate;
@class NSString;

@interface WSTrashItem : NSObject
{
	NSString *_originalPath;	/* COPIED */
	NSString *_trashPath;		/* COPIED */
	NSString *_recordPath;		/* COPIED */
	NSDate *_date;			/* RETAINED */
}
- (NSString *)originalPath;
- (NSString *)trashPath;
- (NSDate *)date;
@end

@interface WSTrash : NSObject
{
	NSString *_root;		/* COPIED; nil means the volume rule */
}
- (instancetype)init;
- (instancetype)initWithRoot:(NSString *)root;

- (NSString *)trashRoot;
- (NSString *)trashDirectoryForPath:(NSString *)path;

/* Move each path into its trash, uniquifying a name that is already there, and write its Put Back record. */
- (nullable NSArray *)recyclePaths:(NSArray *)paths error:(NSError **)error;

/* The records whose trashed item is still there, newest first. */
- (NSArray *)items;

- (BOOL)putBackItem:(WSTrashItem *)item error:(NSError **)error;
- (BOOL)putBackItems:(NSArray *)items error:(NSError **)error;

/* Remove everything the Trash holds. Emptying is not undoable, which is why the manager does not register it. */
- (BOOL)emptyTrash:(NSError **)error;

@end

#endif /* WORKSPACE_WSTRASH_H */
