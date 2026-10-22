/*
 * trash — the recycle, the Put Back record and the empty.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The trash is handed an EXPLICIT root, so a probe never recycles into the real home directory. What is measured is
 * the move into that root, the unique name when one is already there, the record that carries the original path,
 * Put Back, and an empty that removes the items and their records.
 */
#import "WSTrash.h"

#import <Foundation/Foundation.h>

#include <stdio.h>
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

int main(void)
{
	NSString *base = [@"/tmp" stringByAppendingPathComponent:
		[NSString stringWithFormat:@"agora-trash-%d", (int)getpid()]];
	NSString *sources = [base stringByAppendingPathComponent:@"Sources"];
	NSString *root = [base stringByAppendingPathComponent:@"Trash"];
	NSString *a = [sources stringByAppendingPathComponent:@"a.txt"];
	NSString *b = [sources stringByAppendingPathComponent:@"b.txt"];
	NSString *folder = [sources stringByAppendingPathComponent:@"Folder"];
	WSTrash *trash;
	NSArray *items;

	setvbuf(stdout, NULL, _IONBF, 0);
	[[NSFileManager defaultManager] removeItemAtPath:base error:NULL];
	check(makeDirectory(base) && makeDirectory(sources) && makeDirectory(root), "the probe made its tree");
	makeFile(a, 3);
	makeFile(b, 4);
	makeDirectory(folder);
	makeFile([folder stringByAppendingPathComponent:@"inside.txt"], 5);

	trash = [[WSTrash alloc] initWithRoot:root];
	check([[trash trashRoot] isEqual:root], "an explicit root is the trash root");
	items = [trash recyclePaths:[NSArray arrayWithObject:a] error:NULL];
	check(items != nil && [items count] == 1, "a file is recycled");
	check(![[NSFileManager defaultManager] fileExistsAtPath:a]
	      && [[NSFileManager defaultManager] fileExistsAtPath:[root stringByAppendingPathComponent:@"a.txt"]],
	      "the source is gone and the trash has the file");
	check([[[items objectAtIndex:0] originalPath] isEqual:a], "the item remembers where it came from");
	check([[trash items] count] == 1, "and the trash lists it");

	/* A SECOND a.txt IS UNIQUIFIED RATHER THAN REPLACING THE FIRST. */
	makeFile(a, 6);
	(void)[trash recyclePaths:[NSArray arrayWithObject:a] error:NULL];
	check([[trash items] count] == 2
	      && [[NSFileManager defaultManager] fileExistsAtPath:[root stringByAppendingPathComponent:@"a 2.txt"]],
	      "a second name is uniquified");

	/* BOTH NAMES ARE CLEARED, THEN TWO DISTINCT ORIGINALS GO IN AND BOTH COME BACK. */
	check([trash emptyTrash:NULL], "the two a.txt records are emptied");
	makeFile(a, 8);
	check([[trash recyclePaths:[NSArray arrayWithObjects:a, b, nil] error:NULL] count] == 2,
	      "two distinct items are recycled");
	items = [trash items];
	check([items count] == 2, "and both are listed");
	check([trash putBackItem:[items objectAtIndex:0] error:NULL]
	      && [trash putBackItem:[items objectAtIndex:1] error:NULL],
	      "Put Back puts both home");
	check([[NSFileManager defaultManager] fileExistsAtPath:a]
	      && [[NSFileManager defaultManager] fileExistsAtPath:b], "both original paths exist again");
	check([[trash items] count] == 0, "and both records are gone");

	/* A DIRECTORY IS RECYCLED AS A WHOLE, AND PUT BACK AS ONE. */
	items = [trash recyclePaths:[NSArray arrayWithObject:folder] error:NULL];
	check(items != nil && [[NSFileManager defaultManager]
		fileExistsAtPath:[[root stringByAppendingPathComponent:@"Folder"]
			stringByAppendingPathComponent:@"inside.txt"]],
	      "a directory and its contents move to the trash");
	check([trash putBackItems:items error:NULL], "Put Back restores the directory");
	check([[NSFileManager defaultManager] fileExistsAtPath:
		[folder stringByAppendingPathComponent:@"inside.txt"]], "with its contents");

	/* EMPTY REMOVES THE ITEMS AND THEIR RECORDS. */
	(void)[trash recyclePaths:[NSArray arrayWithObjects:a, b, nil] error:NULL];
	check([[trash items] count] == 2, "two items are in the trash for the empty");
	check([trash emptyTrash:NULL], "emptyTrash succeeds");
	check([[trash items] count] == 0
	      && ![[NSFileManager defaultManager] fileExistsAtPath:[root stringByAppendingPathComponent:@"a.txt"]],
	      "the items and records are gone");

	[trash release];
	[[NSFileManager defaultManager] removeItemAtPath:base error:NULL];
	printf("trash: %s\n", s_failed == 0 ? "all checks passed" : "FAILURES");
	return s_failed == 0 ? 0 : 1;
}
