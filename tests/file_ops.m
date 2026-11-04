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

#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <time.h>
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

/* ---- THE CENTRAL DIRECTORY, WHICH IS WHAT A READER BELIEVES ------------------------------------------------
 *
 * A ZIP is believed through its central directory, not through its local headers: the name, the mode and the time a
 * restored file gets all come from here. So the test reads this rather than scanning the bytes for a name. */
static unsigned long zip_le16(const unsigned char *bytes)
{
	return (unsigned long)bytes[0] | ((unsigned long)bytes[1] << 8);
}

static unsigned long zip_le32(const unsigned char *bytes)
{
	return (unsigned long)bytes[0] | ((unsigned long)bytes[1] << 8) |
	       ((unsigned long)bytes[2] << 16) | ((unsigned long)bytes[3] << 24);
}

static unsigned long long zip_le64(const unsigned char *bytes)
{
	return (unsigned long long)zip_le32(bytes) | ((unsigned long long)zip_le32(bytes + 4) << 32);
}

/* **THE ZIP64 EXTRA FIELD, IF THE RECORD HAS ONE.** A reader finds the real size here when the 32-bit field says
 * 0xFFFFFFFF, and the values are in the order uncompressed, compressed, offset. */
static unsigned long long zip_extra_value(const unsigned char *extra, unsigned long length,
					  unsigned long long *compressed, unsigned long long *offset)
{
	unsigned long at = 0;

	*compressed = 0;
	*offset = 0;
	while (at + 4 <= length) {
		unsigned long tag = zip_le16(extra + at);
		unsigned long size = zip_le16(extra + at + 2);
		unsigned long long value = 0;
		unsigned long long second = 0;
		unsigned long long third = 0;
		unsigned long cursor = at + 4;

		if (tag == 0x0001) {
			if (cursor + 8 <= at + 4 + size) {
				value = zip_le64(extra + cursor);
				cursor += 8;
			}
			if (cursor + 8 <= at + 4 + size) {
				second = zip_le64(extra + cursor);
				cursor += 8;
			}
			if (cursor + 8 <= at + 4 + size) {
				third = zip_le64(extra + cursor);
			}
			*compressed = second;
			*offset = third;
			return value;
		}
		at += 4 + size;
	}
	return 0;
}

static NSArray *zip_central_directory(NSData *data)
{
	const unsigned char *bytes = [data bytes];
	NSUInteger length = [data length];
	NSMutableArray *records = [[[NSMutableArray alloc] init] autorelease];
	NSUInteger eocd = NSNotFound;
	NSUInteger offset;
	unsigned long count;
	unsigned long i;

	if (length < 22) {
		return records;
	}
	for (i = length - 22; ; i--) {
		if (bytes[i] == 0x50 && bytes[i + 1] == 0x4b && bytes[i + 2] == 0x05 && bytes[i + 3] == 0x06) {
			eocd = i;
			break;
		}
		if (i == 0) {
			break;
		}
	}
	if (eocd == NSNotFound) {
		return records;
	}
	/* **A READER WITH A ZIP64 ARCHIVE FOLLOWS THE LOCATOR FIRST.** The plain EOCD's count and offset are the 0xFFFF and
	 * 0xFFFFFFFF sentinels in that case, and a reader that takes them at face value sees an archive with no entries —
	 * which is what this probe did before it learned the same rule a real one uses. */
	count = zip_le16(bytes + eocd + 10);
	offset = zip_le32(bytes + eocd + 16);
	if (eocd >= 20 && bytes[eocd - 20] == 0x50 && bytes[eocd - 19] == 0x4b &&
	    bytes[eocd - 18] == 0x06 && bytes[eocd - 17] == 0x07) {
		unsigned long long at = zip_le64(bytes + eocd - 20 + 8);

		if (at + 56 <= length && bytes[at] == 0x50 && bytes[at + 1] == 0x4b &&
		    bytes[at + 2] == 0x06 && bytes[at + 3] == 0x06) {
			count = (unsigned long)zip_le64(bytes + at + 32);
			offset = (NSUInteger)zip_le64(bytes + at + 48);
		}
	}
	for (i = 0; i < count && offset + 46 <= length; i++) {
		unsigned long nameLength = zip_le16(bytes + offset + 28);
		unsigned long extraLength = zip_le16(bytes + offset + 30);
		unsigned long commentLength = zip_le16(bytes + offset + 32);
		NSString *name;

		if (offset + 46 + nameLength > length) {
			break;
		}
		name = [[[NSString alloc] initWithBytes:bytes + offset + 46 length:nameLength
					       encoding:NSUTF8StringEncoding] autorelease];
		if (name != nil) {
			unsigned long extraLength = zip_le16(bytes + offset + 30);
			unsigned long long compressed = 0;
			unsigned long long localOffset = 0;
			unsigned long long zip64Size = 0;

			if (offset + 46 + nameLength + extraLength <= length) {
				zip64Size = zip_extra_value(bytes + offset + 46 + nameLength, extraLength,
							    &compressed, &localOffset);
			}
			[records addObject:[NSDictionary dictionaryWithObjectsAndKeys:
				name, @"name",
				[NSNumber numberWithUnsignedInt:(unsigned int)(zip_le32(bytes + offset + 38) >> 16)], @"mode",
				[NSNumber numberWithUnsignedLong:zip_le16(bytes + offset + 12)], @"time",
				[NSNumber numberWithUnsignedLong:zip_le16(bytes + offset + 14)], @"date",
				[NSNumber numberWithUnsignedLong:zip_le16(bytes + offset + 10)], @"method",
				[NSNumber numberWithUnsignedLong:zip_le16(bytes + offset + 4)], @"madeBy",
				[NSNumber numberWithUnsignedLong:zip_le32(bytes + offset + 24)], @"usize32",
				[NSNumber numberWithUnsignedLongLong:zip64Size], @"zip64usize", nil]];
		}
		offset += 46 + nameLength + extraLength + commentLength;
	}
	return records;
}

/* ---- A ZIP BUILT BY HAND, FOR THE ONE CASE THE WRITER REFUSES TO MAKE ------------------------------------
 *
 * A stored entry whose name is `../escape.txt` is the classic zip-slip, and this tree's own writer cannot produce one
 * because its names come from path components. So the probe assembles the bytes: local header, name, payload, central
 * record, end record, with the offsets computed rather than typed. The CRC is left zero on purpose — the name is refused
 * before any byte is written, which is the property under test. */
static void slip_put16(unsigned char *at, uint16_t value)
{
	at[0] = (unsigned char)(value & 0xff);
	at[1] = (unsigned char)((value >> 8) & 0xff);
}

static void slip_put32(unsigned char *at, uint32_t value)
{
	at[0] = (unsigned char)(value & 0xff);
	at[1] = (unsigned char)((value >> 8) & 0xff);
	at[2] = (unsigned char)((value >> 16) & 0xff);
	at[3] = (unsigned char)((value >> 24) & 0xff);
}

static NSData *slip_archive(const char *name, const char *payload)
{
	uint16_t nameLength = (uint16_t)strlen(name);
	uint32_t payloadLength = (uint32_t)strlen(payload);
	uint32_t centralOffset = 30 + (uint32_t)nameLength + payloadLength;
	uint32_t centralSize = 46 + (uint32_t)nameLength;
	uint32_t total = centralOffset + centralSize + 22;
	unsigned char *bytes = calloc(1, total);
	unsigned char *at = bytes;
	NSData *answer;

	if (bytes == NULL) {
		return nil;
	}
	slip_put32(at, 0x04034b50u);
	slip_put16(at + 4, 20);
	slip_put16(at + 8, 0);			/* stored */
	slip_put16(at + 26, nameLength);
	memcpy(at + 30, name, nameLength);
	memcpy(at + 30 + nameLength, payload, payloadLength);
	at = bytes + centralOffset;
	slip_put32(at, 0x02014b50u);
	slip_put16(at + 4, (uint16_t)((3u << 8) | 20u));
	slip_put16(at + 6, 20);
	slip_put32(at + 20, payloadLength);	/* compressed */
	slip_put32(at + 24, payloadLength);	/* uncompressed */
	slip_put16(at + 28, nameLength);
	slip_put32(at + 38, (uint32_t)0100644u << 16);
	slip_put32(at + 42, 0);			/* the local header is at zero */
	memcpy(at + 46, name, nameLength);
	at = bytes + centralOffset + centralSize;
	slip_put32(at, 0x06054b50u);
	slip_put16(at + 8, 1);
	slip_put16(at + 10, 1);
	slip_put32(at + 12, centralSize);
	slip_put32(at + 16, centralOffset);
	answer = [NSData dataWithBytes:bytes length:total];
	free(bytes);
	return answer;
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

	/* 9. COMPRESS WRITES A ZIP, AND EVERY ENTRY KEEPS ITS OWN TIME AND ITS OWN MODE. The archive used to stamp every
	 * entry with "now" and mode 0, so a restored shell script was `-rw----` and would not run; a symlink was followed
	 * rather than stored as a link. The central directory is what a reader believes, so it is what is checked. */
	{
		NSString *script = [aDir stringByAppendingPathComponent:@"run.sh"];
		NSString *nested = [aDir stringByAppendingPathComponent:@"nested"];
		NSString *inside = [nested stringByAppendingPathComponent:@"inside.txt"];
		NSString *empty = [aDir stringByAppendingPathComponent:@"empty"];
		NSString *link = [aDir stringByAppendingPathComponent:@"link.txt"];
		NSString *file1 = [aDir stringByAppendingPathComponent:@"file1.txt"];
		NSString *file2 = [aDir stringByAppendingPathComponent:@"file2.txt"];
		struct timespec stamps[2];
		NSString *archive;
		NSData *data;
		NSArray *records;
		NSDictionary *record;
		NSInteger i;

		makeFile(file1, 12);
		makeFile(file2, 24);
		makeDirectory(nested);
		makeFile(inside, 8);
		makeDirectory(empty);
		makeFile(script, 20);
		(void)chmod([script fileSystemRepresentation], 0755);
		(void)symlink("file1.txt", [link fileSystemRepresentation]);
		/* A KNOWN MTIME, so the entry's DOS stamp can be compared with the file's own rather than with "now". */
		stamps[0].tv_sec = 1500000000;	/* 2017-07-14, in whatever zone this runs */
		stamps[0].tv_nsec = 0;
		stamps[1] = stamps[0];
		(void)utimensat(AT_FDCWD, [file1 fileSystemRepresentation], stamps, AT_SYMLINK_NOFOLLOW);

		archive = [ops compressPaths:[NSArray arrayWithObject:aDir] inDirectory:base error:NULL];
		data = (archive != nil) ? [NSData dataWithContentsOfFile:archive] : nil;
		check(data != nil && [data length] > 22 && ((const unsigned char *)[data bytes])[0] == 'P'
		      && ((const unsigned char *)[data bytes])[1] == 'K',
		      "Compress writes a ZIP");
		records = (data != nil) ? zip_central_directory(data) : nil;
		{
			NSUInteger files = 0;

			for (i = 0; i < (NSInteger)[records count]; i++) {
				if (![[[records objectAtIndex:i] objectForKey:@"name"] hasSuffix:@"/"]) {
					files++;
				}
			}
			check([records count] >= 8,
			      "the archive holds the folder, its files, a nested folder and its file, the empty folder, the script and the link");
			printf("  (note: the archive has %lu entries, %lu of them files; the bar said %d of %u\n",
			       (unsigned long)[records count], (unsigned long)files, progressCount, progressTotal);
			check((NSUInteger)progressCount == files && (NSUInteger)progressTotal == files,
			      "and the bar counts the FILES in the tree, not the one folder it was given");
		}
		for (i = 0; i < (NSInteger)[records count]; i++) {
			record = [records objectAtIndex:i];
			if ([[record objectForKey:@"name"] isEqual:@"run.sh"] ||
			    [[record objectForKey:@"name"] hasSuffix:@"/run.sh"]) {
				check(([[record objectForKey:@"mode"] unsignedIntValue] & 07777) == 0755,
				      "the script keeps its executable bit in the central directory");
				check(([[record objectForKey:@"mode"] unsignedIntValue] & S_IFMT) == S_IFREG,
				      "and its type, which is what makes a reader restore a file rather than a link");
			}
			if ([[record objectForKey:@"name"] hasSuffix:@"/link.txt"]) {
				check(([[record objectForKey:@"mode"] unsignedIntValue] & S_IFMT) == S_IFLNK,
				      "a symlink is stored as a link, not followed");
			}
			if ([[record objectForKey:@"name"] hasSuffix:@"/empty/"] ||
			    [[record objectForKey:@"name"] hasSuffix:@"/nested/"]) {
				check(([[record objectForKey:@"mode"] unsignedIntValue] & S_IFMT) == S_IFDIR,
				      "a folder is a folder in the archive too");
			}
			if ([[record objectForKey:@"name"] hasSuffix:@"/file1.txt"]) {
				struct tm broken;
				time_t when = (time_t)1500000000;
				unsigned int expectedTime = 0;
				unsigned int expectedDate = 0;

				if (localtime_r(&when, &broken) != NULL) {
					expectedTime = (unsigned int)((broken.tm_hour << 11) | (broken.tm_min << 5) | (broken.tm_sec / 2));
					expectedDate = (unsigned int)(((broken.tm_year - 80) << 9) | ((broken.tm_mon + 1) << 5) |
								      broken.tm_mday);
				}
				check([[record objectForKey:@"time"] unsignedIntValue] == expectedTime
				      && [[record objectForKey:@"date"] unsignedIntValue] == expectedDate,
				      "and every entry carries the file's own modification time");
			}
		}
		[undo undo];
		check(!exists(archive), "Undo removes the archive");
	}

	/* 10. THE ARCHIVE IS STREAMED, SO A BIG FILE DOES NOT COST ITS OWN SIZE IN MEMORY — TWICE. The first version read
	 * every file into an NSData and kept the archive in another: MEASURED, a 191 MB tree took a peak RSS of 409 MB.
	 * Here a 24 MB incompressible file is compressed and the process's high-water mark is not allowed to grow by more
	 * than half of it (the old writer needed twice its size; the streamed one needs a 64 KB block). */
	{
		NSString *bulkDir = [base stringByAppendingPathComponent:@"bulk"];
		NSString *bulk = [bulkDir stringByAppendingPathComponent:@"random.bin"];
		struct rusage before;
		struct rusage after;
		NSString *archive;

		makeDirectory(bulkDir);
		{
			/* INCOMPRESSIBLE ON PURPOSE: a zeros file would deflate to nothing and prove less. */
			NSMutableData *noise = [[NSMutableData alloc] initWithLength:24u * 1024u * 1024u];
			unsigned char *bytes = [noise mutableBytes];
			FILE *urandom = fopen("/dev/urandom", "rb");
			NSUInteger i;

			if (urandom != NULL) {
				(void)fread(bytes, 1, [noise length], urandom);
				fclose(urandom);
			} else {
				for (i = 0; i < [noise length]; i++) {
					bytes[i] = (unsigned char)(i * 31u);
				}
			}
			(void)[noise writeToFile:bulk atomically:NO];
			[noise release];
		}
		(void)getrusage(RUSAGE_SELF, &before);
		archive = [ops compressPaths:[NSArray arrayWithObject:bulkDir] inDirectory:base error:NULL];
		(void)getrusage(RUSAGE_SELF, &after);
		printf("  (note: compressing 24 MB raised the peak RSS by %ld KB\n",
		       after.ru_maxrss - before.ru_maxrss);
		check(archive != nil, "a folder with a 24 MB file compresses");
		check(after.ru_maxrss - before.ru_maxrss < 12 * 1024,
		      "and the archive is streamed: the peak RSS does not grow by the file's size");
		(void)[[NSFileManager defaultManager] removeItemAtPath:archive error:NULL];
		(void)[[NSFileManager defaultManager] removeItemAtPath:bulkDir error:NULL];
	}

	/* 10b. EXTRACTION IS THE OTHER HALF: an archive this tree wrote comes back as the tree it wrote. The folder is named
	 * for the archive and sits beside it, the files keep their bytes and their executable bit, the symlink is a symlink
	 * again, the empty folder is still there, and the times are the files' own. */
	{
		NSString *source = [base stringByAppendingPathComponent:@"trip"];
		NSString *nested = [source stringByAppendingPathComponent:@"nested"];
		NSString *script = [source stringByAppendingPathComponent:@"run.sh"];
		NSString *link = [source stringByAppendingPathComponent:@"link.txt"];
		NSString *empty = [source stringByAppendingPathComponent:@"empty"];
		NSString *archive;
		NSString *folder;
		struct timespec stamps[2];
		NSString *extracted;
		NSData *expectedBytes = nil;

		makeDirectory(source);
		makeDirectory(nested);
		makeDirectory(empty);
		makeFile([source stringByAppendingPathComponent:@"a.txt"], 40);
		makeFile([nested stringByAppendingPathComponent:@"b.txt"], 5000);
		makeFile(script, 24);
		(void)chmod([script fileSystemRepresentation], 0755);
		(void)symlink("a.txt", [link fileSystemRepresentation]);
		stamps[0].tv_sec = 1600000000;
		stamps[0].tv_nsec = 0;
		stamps[1] = stamps[0];
		(void)utimensat(AT_FDCWD, [script fileSystemRepresentation], stamps, AT_SYMLINK_NOFOLLOW);

		archive = [ops compressPaths:[NSArray arrayWithObject:source] inDirectory:base error:NULL];
		check(archive != nil, "a tree compresses");
		{
			/* **THE SOURCE GOES AWAY, BECAUSE THAT IS THE CASE THIS IS ABOUT**: an archive beside the tree it came from
			 * extracts into "trip", and only a SECOND extraction has to invent "trip 2". */
			expectedBytes = [[NSData dataWithContentsOfFile:[nested stringByAppendingPathComponent:@"b.txt"]] retain];
			[[NSFileManager defaultManager] removeItemAtPath:source error:NULL];
		}
		folder = [ops extractArchive:archive error:NULL];
		printf("  (note: %s extracted into %s\n", [[archive lastPathComponent] UTF8String],
		       (folder != nil) ? [[folder lastPathComponent] UTF8String] : "(nil)");
		check(folder != nil, "and extracts");
		check(folder != nil && [[folder lastPathComponent] isEqual:@"trip"],
		      "into a folder named for the archive, beside it");
		extracted = [folder stringByAppendingPathComponent:@"trip"];
		check(exists([extracted stringByAppendingPathComponent:@"a.txt"]),
		      "with the archive's own top folder inside it");
		check(exists([extracted stringByAppendingPathComponent:@"nested/b.txt"]),
		      "and the nesting keeps its shape");
		check(exists([extracted stringByAppendingPathComponent:@"empty"]),
		      "and an empty folder is not dropped");
		check(exists([extracted stringByAppendingPathComponent:@"run.sh"]),
		      "and the script is there");
		{
			struct stat st;

			check(stat([[extracted stringByAppendingPathComponent:@"run.sh"] fileSystemRepresentation], &st) == 0
			      && (st.st_mode & 07777) == 0755,
			      "executable again, from the mode the archive carried");
			check((st.st_mode & 07777) == 0755 && st.st_mtime == (time_t)1600000000,
			      "and dated when it was, not when it was unpacked");
		}
		{
			char target[PATH_MAX];
			ssize_t length = readlink([[extracted stringByAppendingPathComponent:@"link.txt"]
						   fileSystemRepresentation], target, sizeof target);

			check(length > 0 && strncmp(target, "a.txt", (size_t)length) == 0,
			      "and the symlink is a symlink again, pointing at what it pointed at");
		}
		{
			/* THE BYTES ROUND-TRIP: a 5 KB file that deflated on the way in has to inflate to the same 5 KB. */
			NSData *round = [NSData dataWithContentsOfFile:
				[extracted stringByAppendingPathComponent:@"nested/b.txt"]];

			check(expectedBytes != nil && round != nil && [expectedBytes isEqual:round],
			      "and every file's bytes are the ones that went in");
			[expectedBytes release];
		}
		check(!exists([base stringByAppendingPathComponent:@"trip 2"]),
		      "one extraction leaves no second folder behind");
		{
			NSString *again = [ops extractArchive:archive error:NULL];

			check(again != nil && [[again lastPathComponent] isEqual:@"trip 2"],
			      "and extracting it twice is two folders, not a merge");
			[[NSFileManager defaultManager] removeItemAtPath:again error:NULL];
		}

		/* **A NAME THAT LEAVES THE FOLDER REFUSES THE WHOLE ARCHIVE.** Hand-built, because the writer will not make one:
		 * a stored entry called "../escape.txt" is the classic zip-slip, and what must happen is nothing at all. */
		{
			NSString *bad = [base stringByAppendingPathComponent:@"slip.zip"];
			NSError *slipError = nil;
			NSString *made;
			NSData *slip = slip_archive("../escape.txt", "pwned\nxyz");

			check(slip != nil, "a zip carrying ../escape.txt is built by hand");
			[slip writeToFile:bad atomically:NO];
			made = [ops extractArchive:bad error:&slipError];
			check(made == nil && slipError != nil, "an entry called ../escape.txt is refused");
			check(!exists([base stringByAppendingPathComponent:@"escape.txt"]),
			      "and nothing is written outside the folder it was unpacking into");
			check(!exists([base stringByAppendingPathComponent:@"slip"]),
			      "and the half-made folder is taken away again");
			[[NSFileManager defaultManager] removeItemAtPath:bad error:NULL];
		}
	}

	/* 11. ZIP64, MEASURED WITHOUT FOUR GIGABYTES. The format's limits are 4 GB and 65,535 entries, which no suite should
	 * write; the writer reads its thresholds from `+cg_zip64ByteLimit`, and a probe lowers them so the SAME decision and
	 * the SAME records are exercised on a few kilobytes. What has to be true is what a reader believes: the central
	 * record's 32-bit size says "look in the extra field", the extra carries the real number, and there is a ZIP64 end
	 * of central directory for the reader that follows it. */
	{
		NSString *zip64Dir = [base stringByAppendingPathComponent:@"zip64"];
		NSString *big = [zip64Dir stringByAppendingPathComponent:@"large.bin"];
		NSString *archive;
		NSData *data;
		NSArray *records;
		const unsigned char *bytes;
		NSUInteger length;
		NSUInteger eocd64 = NSNotFound;
		NSUInteger i;
		BOOL sawLarge = NO;

		makeDirectory(zip64Dir);
		makeFile([zip64Dir stringByAppendingPathComponent:@"one.txt"], 2048);
		makeFile([zip64Dir stringByAppendingPathComponent:@"two.txt"], 2048);
		makeFile(big, 8192);
		[WSFileOperations cg_setZip64LimitsForTesting:1024 entries:3];
		archive = [ops compressPaths:[NSArray arrayWithObject:zip64Dir] inDirectory:base error:NULL];
		[WSFileOperations cg_setZip64LimitsForTesting:0 entries:0];
		data = (archive != nil) ? [NSData dataWithContentsOfFile:archive] : nil;
		bytes = [data bytes];
		length = [data length];
		check(data != nil, "a tree compresses with the ZIP64 thresholds lowered");

		/* THE ZIP64 END OF CENTRAL DIRECTORY RECORD AND ITS LOCATOR. */
		if (length > 20) {
			for (i = length - 20; ; i--) {
				if (bytes[i] == 0x50 && bytes[i + 1] == 0x4b && bytes[i + 2] == 0x06 && bytes[i + 3] == 0x07) {
					unsigned long long at = zip_le64(bytes + i + 8);

					if (at + 56 <= length && bytes[at] == 0x50 && bytes[at + 1] == 0x4b &&
					    bytes[at + 2] == 0x06 && bytes[at + 3] == 0x06) {
						eocd64 = (NSUInteger)at;
					}
					break;
				}
				if (i == 0) {
					break;
				}
			}
		}
		check(eocd64 != NSNotFound, "and it writes a ZIP64 end of central directory with a locator pointing at it");
		records = (data != nil) ? zip_central_directory(data) : nil;
		printf("  (note: the archive has %lu entries; the ZIP64 EOCD says %llu\n",
		       (unsigned long)[records count], (unsigned long long)zip_le64(bytes + eocd64 + 32));
		check([records count] > 0 && eocd64 != NSNotFound &&
		      zip_le64(bytes + eocd64 + 32) == (unsigned long long)[records count],
		      "whose entry count is the whole count, in 64 bits");
		for (i = 0; i < [records count]; i++) {
			NSDictionary *record = [records objectAtIndex:i];

			if ([[record objectForKey:@"name"] hasSuffix:@"/large.bin"]) {
				sawLarge = YES;
				check([[record objectForKey:@"usize32"] unsignedLongValue] == 0xffffffffUL,
				      "a big entry's 32-bit size is the ZIP64 sentinel");
				check([[record objectForKey:@"zip64usize"] unsignedLongLongValue] == 8192,
				      "and the real size is in the extra field, where a reader looks for it");
				check(([[record objectForKey:@"madeBy"] unsignedLongValue] & 0xff) == 45
				      && ([[record objectForKey:@"madeBy"] unsignedLongValue] >> 8) == 3,
				      "with the version that says 64 bits are in use, and unix for the mode");
			}
		}
		check(sawLarge, "the big entry is in the directory at all");
	}

	/* 12. A FAILED COMPRESS LEAVES NO ARCHIVE BEHIND. The writer streams into its destination now, so a half-written
	 * file would be left beside the folder unless the failure takes it away. A file with no read permission is what
	 * makes the write fail halfway through the tree. */
	if (geteuid() != 0) {
		NSString *locked = [aDir stringByAppendingPathComponent:@"locked.bin"];
		NSString *archive;
		NSError *error = nil;

		makeFile(locked, 16);
		(void)chmod([locked fileSystemRepresentation], 0);
		archive = [ops compressPaths:[NSArray arrayWithObject:aDir] inDirectory:base error:&error];
		check(archive == nil && error != nil, "compressing a tree with an unreadable file fails");
		check(!exists([base stringByAppendingPathComponent:@"A Folder.zip"]),
		      "and the half-written archive is not left behind");
		(void)chmod([locked fileSystemRepresentation], 0644);
		(void)[[NSFileManager defaultManager] removeItemAtPath:locked error:NULL];
	}

	[ops release];
	[trash release];
	[undo release];
	[[NSFileManager defaultManager] removeItemAtPath:base error:NULL];
	[[NSFileManager defaultManager] removeItemAtPath:otherBase error:NULL];
	printf("file_ops: %s\n", s_failed == 0 ? "all checks passed" : "FAILURES");
	return s_failed == 0 ? 0 : 1;
}
