/*
 * WSFileOperations.h — the operations a file manager performs, and their undo.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **THE MANAGER OWNS THE OPERATION, NOT THE VIEW.** New Folder, Duplicate, Rename, Move/Copy To, Move to Trash,
 * Put Back, Empty Trash and Compress are methods here; a view asks for one and reloads its model. Every operation
 * that can be reversed registers its inverse with the `NSUndoManager` it was handed, so the Edit menu's Undo/Redo
 * work through the same machinery a text field uses.
 *
 * **A CONFLICT IS A POLICY, AND THE POLICY IS A HANDLER.** A destination that already exists is put to the
 * conflict handler: Skip, Replace, Keep Both or the default. The handler is what a name-conflict sheet implements;
 * a probe supplies an answer directly, which is why the policy is testable without a window.
 *
 * **PROGRESS IS A HANDLER TOO.** The manager calls it once per top-level item with `completed`, `total` and the
 * path; the progress window is a consumer of that callback, not a second copy of the loop.
 *
 * **COMPRESS WRITES A ZIP, STREAMING IT TO ITS FILE.** The archive is a store-or-deflate ZIP written here with zlib's
 * raw deflate — no external archiver and no second format — and it is appended to as it is made, so a file's bytes
 * never all live in memory: MEASURED, a 191 MB tree cost a peak RSS of 409 MB when the archive and every file were
 * buffered, and 27 MB now. Whether an entry is stored or deflated is decided from its first 64 KB, so a picture or an
 * archive is copied rather than deflated to a slightly larger result. Each entry keeps its own modification time and
 * its `st_mode` (with `version made by` saying unix, which is what makes a reader restore the bits), a symlink is
 * stored as a link rather than followed, and a failed compress takes its half-written file away. The central
 * directory is built in memory as the entries go out, and the file is one file in the destination directory, which is
 * what Undo removes.
 */
#ifndef WORKSPACE_WSFILEOPERATIONS_H
#define WORKSPACE_WSFILEOPERATIONS_H

#import <Foundation/NSArray.h>
#import <Foundation/NSObject.h>

@class NSMutableArray;
@class NSString;
@class NSUndoManager;
@class WSTrash;

typedef NSInteger WSFileConflictResolution;
enum {
	WSConflictUseDefault = 0,	/* the handler's default; without one, Keep Both */
	WSConflictSkip = 1,
	WSConflictReplace = 2,
	WSConflictKeepBoth = 3
};

typedef WSFileConflictResolution (^WSFileConflictHandler)(NSString *destination);
typedef void (^WSFileProgressHandler)(NSUInteger completed, NSUInteger total, NSString *path);

@interface WSFileOperations : NSObject
{
	NSUndoManager *_undoManager;		/* NOT RETAINED: the window owns it */
	WSTrash *_trash;			/* RETAINED */
	WSFileConflictHandler _conflictHandler;	/* COPIED */
	WSFileProgressHandler _progressHandler;	/* COPIED */
}

- (instancetype)initWithUndoManager:(nullable NSUndoManager *)undoManager trash:(WSTrash *)trash;

- (nullable NSUndoManager *)undoManager;
- (WSTrash *)trash;

- (void)setConflictHandler:(nullable WSFileConflictHandler)handler;
- (void)setProgressHandler:(nullable WSFileProgressHandler)handler;

/* NEW FOLDER. A nil or empty name is "untitled folder", and an existing name is made unique. */
- (nullable NSString *)createFolderInDirectory:(NSString *)directory name:(nullable NSString *)name
					 error:(NSError **)error;

/* DUPLICATE makes a copy named "<base> copy[ 2].<ext>". */
- (nullable NSArray *)duplicatePaths:(NSArray *)paths inDirectory:(NSString *)directory error:(NSError **)error;

- (nullable NSString *)renamePath:(NSString *)path toName:(NSString *)name error:(NSError **)error;

- (nullable NSArray *)movePaths:(NSArray *)paths toDirectory:(NSString *)directory error:(NSError **)error;
- (nullable NSArray *)copyPaths:(NSArray *)paths toDirectory:(NSString *)directory error:(NSError **)error;

/* **A DROP'S MOVE, WITH THE UNDO A PERSON EXPECTS.** The same move `WSItemDragPerform` makes when a drag is let go —
 * a conflict is refused rather than renamed, and the destination is refused when it is a source or inside one — with
 * the undo entry `-movePaths:` already records. A drop that moves something must be undoable from the Edit menu:
 * MEASURED the hard way, a drag released one row lower moved a 22 GB folder into its neighbour, and with no undo the
 * only way back was to know where it went. */
- (BOOL)movePathsForDrop:(NSArray *)paths toDirectory:(NSString *)directory error:(NSError **)error;

- (nullable NSArray *)movePathsToTrash:(NSArray *)paths error:(NSError **)error;
- (BOOL)putBackTrashItems:(NSArray *)items error:(NSError **)error;
- (BOOL)emptyTrash:(NSError **)error;

/* COMPRESS writes one `.zip` in `directory`; the returned path is the archive. */
- (nullable NSString *)compressPaths:(NSArray *)paths inDirectory:(NSString *)directory error:(NSError **)error;

/* **THE ZIP64 THRESHOLDS, AS A PROBE'S DOOR.** The format's limits are 4 GB and 65,535 entries, and a suite that had to
 * write either would be a suite nobody runs: a probe lowers them to a few kilobytes and a few entries, and the same
 * decision and the same records are measured on data that small. Zero restores the format's own limits, and the
 * application never calls the setter. */
+ (void)cg_setZip64LimitsForTesting:(unsigned long long)bytes entries:(unsigned long long)entries;
+ (unsigned long long)cg_zip64ByteLimit;
+ (unsigned long long)cg_zip64EntryLimit;

@end

#endif /* WORKSPACE_WSFILEOPERATIONS_H */
