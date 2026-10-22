/*
 * file_ops — the manager does the operations, and Undo takes each of them back.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The temp tree is on `/tmp`; a second destination is on `/dev/shm`, so "across a volume" is a fact. The conflict
 * handler answers Skip and Keep Both directly; the progress handler counts the items. Compress is checked by the ZIP
 * signature and the entry name inside the archive, not by trusting the writer.
 */
#import "WSFileOperations.h"
#import "WSTrash.h"

#import <Foundation/Foundation.h>

#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int s_failed;

static void check(int ok, const char *name)
{
	printf("  %s   %s\n", ok ? "ok  " : "FAIL", name);
	if (!ok) s_failed++;
}

static BOOL makeDirectory(NSString *path)
{
	return [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES
								  attributes:nil error:NULL];
}

static BOOL makeFile(NSString *path, NSUInteger bytes)
{
	return [[NSFileManager defaultManager] createFileAtPath:path contents:[NSMutableData dataWithLength:bytes]
						      attributes:nil];
}

static BOOL exists(NSString *path)
{
	return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

int main(void)
{
	NSString *base = [@"/tmp" stringByAppendingPathComponent:
		[NSString stringWithFormat:@"agora-file-ops-%d", (int)getpid()]];
	NSString *otherBase = [@"/dev/shm" stringByAppendingPathComponent:
		[NSString stringWithFormat:@"agora-file-ops-%d", (int)getpid()]];
	NSString *root = [base stringByAppendingPathComponent:@"Root"];
	NSString *aDir = [base stringByAppendingPathComponent:@"A"];
	NSString *bDir = [base stringByAppendingPathComponent:@"B"];
	NSString *trashRoot = [base stringByAppendingPathComponent:@"Trash"];
	NSString *a = [root stringByAppendingPathComponent:@"a.txt"];
	NSString *b = [root stringByAppendingPathComponent:@"b.txt"];
	NSUndoManager *undo = [[NSUndoManager alloc] init];
	WSTrash *trash = [[WSTrash alloc] initWithRoot:trashRoot];
	WSFileOperations *ops = [[WSFileOperations alloc] initWithUndoManager:undo trash:trash];
	__block int progressCount = 0;
	__block NSUInteger progressTotal = 0;

	setvbuf(stdout, NULL, _IONBF, 0);
	[[NSFileManager defaultManager] removeItemAtPath:base error:NULL];
	[[NSFileManager defaultManager] removeItemAtPath:otherBase error:NULL];
	check(makeDirectory(base) && makeDirectory(root) && makeDirectory(aDir) && makeDirectory(bDir), "the probe made its tree");
	check(makeDirectory(trashRoot), "and a trash root");
	check(makeDirectory(otherBase), "and a second volume's directory");
	makeFile(a, 10);
	makeFile(b, 20);
	[ops setProgressHandler:^(NSUInteger completed, NSUInteger total, NSString *path) {
		(void)path;
		progressCount = (int)completed;
		progressTotal = total;
	}];

	/* 1. NEW FOLDER, AND UNDO. */
	{
		NSString *folder = [ops createFolderInDirectory:root name:nil error:NULL];

		check(folder != nil && exists(folder) && [[folder lastPathComponent] isEqual:@"untitled folder"],
		      "New Folder makes an untitled folder");
		check([undo canUndo], "and registers an undo");
		[undo undo];
		check(!exists(folder), "Undo removes it");
	}

	/* 2. DUPLICATE, AND UNDO. */
	{
		NSArray *copies = [ops duplicatePaths:[NSArray arrayWithObject:a] inDirectory:root error:NULL];

		check(copies != nil && [copies count] == 1
		      && exists([root stringByAppendingPathComponent:@"a copy.txt"]),
		      "Duplicate makes \"a copy.txt\"");
		[undo undo];
		check(!exists([[copies objectAtIndex:0] description]) || [copies count] == 0
		      || !exists([root stringByAppendingPathComponent:@"a copy.txt"]),
		      "Undo removes the duplicate");
	}

	/* 3. RENAME, AND UNDO. */
	{
		NSString *renamed = [ops renamePath:a toName:@"renamed.txt" error:NULL];

		check(renamed != nil && exists(renamed) && !exists(a), "Rename moves the file");
		[undo undo];
		check(exists(a) && !exists(renamed), "Undo renames it back");
	}

	/* 4. A CONFLICT IS THE HANDLER'S ANSWER. */
	makeFile([aDir stringByAppendingPathComponent:@"a.txt"], 4);
	[ops setConflictHandler:^WSFileConflictResolution(NSString *destination) {
		(void)destination;
		return WSConflictSkip;
	}];
	{
		NSArray *copied = [ops copyPaths:[NSArray arrayWithObject:a] toDirectory:aDir error:NULL];

		check(copied != nil && [copied count] == 0, "a conflict answered Skip copies nothing");
	}
	[ops setConflictHandler:^WSFileConflictResolution(NSString *destination) {
		(void)destination;
		return WSConflictKeepBoth;
	}];
	{
		NSArray *copied = [ops copyPaths:[NSArray arrayWithObject:a] toDirectory:aDir error:NULL];

		check(copied != nil && [copied count] == 1
		      && exists([aDir stringByAppendingPathComponent:@"a 2.txt"]),
		      "and Keep Both makes a unique name");
		[undo undo];
	}
	[[NSFileManager defaultManager] removeItemAtPath:[aDir stringByAppendingPathComponent:@"a.txt"] error:NULL];

	/* 5. MOVE, ITS UNDO, AND ITS REDO. */
	{
		NSArray *moved = [ops movePaths:[NSArray arrayWithObject:a] toDirectory:aDir error:NULL];

		check(moved != nil && [moved count] == 1 && exists([aDir stringByAppendingPathComponent:@"a.txt"])
		      && !exists(a), "Move moves the file");
		[undo undo];
		check(exists(a) && !exists([aDir stringByAppendingPathComponent:@"a.txt"]), "Undo moves it back");
		[undo redo];
		check(!exists(a) && exists([aDir stringByAppendingPathComponent:@"a.txt"]), "Redo moves it again");
		[undo undo];
	}

	/* 6. COPY, INCLUDING ACROSS A VOLUME, AND UNDO. */
	{
		NSArray *copied = [ops copyPaths:[NSArray arrayWithObject:a] toDirectory:bDir error:NULL];

		check(copied != nil && exists([bDir stringByAppendingPathComponent:@"a.txt"]) && exists(a),
		      "Copy leaves the source and makes the copy");
		[undo undo];
		check(!exists([bDir stringByAppendingPathComponent:@"a.txt"]), "Undo removes the copy");
	}
	{
		NSArray *copied = [ops copyPaths:[NSArray arrayWithObject:a] toDirectory:otherBase error:NULL];

		check(copied != nil && exists([otherBase stringByAppendingPathComponent:@"a.txt"]) && exists(a),
		      "a copy onto /dev/shm crosses a volume");
		[undo undo];
		check(!exists([otherBase stringByAppendingPathComponent:@"a.txt"]), "Undo removes it there too");
	}

	/* 7. PROGRESS IS A CALLBACK, ONCE PER ITEM. */
	{
		NSArray *moved = [ops movePaths:[NSArray arrayWithObjects:a, b, nil] toDirectory:aDir error:NULL];

		check(moved != nil && [moved count] == 2 && progressCount == 2 && progressTotal == 2,
		      "Move reports both items through the progress handler");
		[undo undo];
	}

	/* 8. TRASH, PUT BACK, AND THE EMPTY. */
	{
		NSArray *trashed = [ops movePathsToTrash:[NSArray arrayWithObject:a] error:NULL];

		check(trashed != nil && [trashed count] == 1 && [[trash items] count] == 1
		      && !exists(a), "Move to Trash recycles the file");
		[undo undo];
		check(exists(a) && [[trash items] count] == 0, "Undo puts it back");
	}
	{
		NSArray *trashed = [ops movePathsToTrash:[NSArray arrayWithObject:a] error:NULL];

		check([ops putBackTrashItems:trashed error:NULL] && exists(a), "Put Back restores it");
	}
	{
		NSArray *trashed = [ops movePathsToTrash:[NSArray arrayWithObjects:a, b, nil] error:NULL];

		check(trashed != nil && [[trash items] count] == 2, "two items are in the trash");
		check([ops emptyTrash:NULL] && [[trash items] count] == 0 && !exists(a) && !exists(b),
		      "Empty Trash removes the items and their records");
	}

	/* 9. COMPRESS WRITES A ZIP, AND UNDO REMOVES IT. */
	makeFile([aDir stringByAppendingPathComponent:@"file1.txt"], 12);
	makeFile([aDir stringByAppendingPathComponent:@"file2.txt"], 24);
	{
		NSString *archive = [ops compressPaths:[NSArray arrayWithObject:aDir] inDirectory:base error:NULL];
		NSData *data = (archive != nil) ? [NSData dataWithContentsOfFile:archive] : nil;
		int hasName = 0;

		if (data != nil) {
			const unsigned char *bytes = [data bytes];
			NSUInteger length = [data length];
			static const char needle[] = "file1.txt";
			NSUInteger k;

			for (k = 0; k + sizeof needle - 1 <= length; k++) {
				if (memcmp(bytes + k, needle, sizeof needle - 1) == 0) {
					hasName = 1;
					break;
				}
			}
			check([data length] > 4 && bytes[0] == 'P' && bytes[1] == 'K' && bytes[2] == 3 && bytes[3] == 4,
			      "Compress writes a ZIP local header");
			check(hasName, "and the archive carries the entry name");
			[undo undo];
			check(!exists(archive), "Undo removes the archive");
		} else {
			check(0, "Compress returned an archive");
			check(0, "and the archive carries the entry name");
		}
	}

	[ops release];
	[trash release];
	[undo release];
	[[NSFileManager defaultManager] removeItemAtPath:base error:NULL];
	[[NSFileManager defaultManager] removeItemAtPath:otherBase error:NULL];
	printf("file_ops: %s\n", s_failed == 0 ? "all checks passed" : "FAILURES");
	return s_failed == 0 ? 0 : 1;
}
