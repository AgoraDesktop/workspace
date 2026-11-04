/*
 * WSFileOperations.m — the operations, their conflicts, their progress and their undo.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#import "WSFileOperations.h"

#import "WSTrash.h"

#import <Foundation/NSCharacterSet.h>
#import <Foundation/NSData.h>
#import <Foundation/NSDate.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSError.h>
#import <Foundation/NSFileManager.h>
#import <Foundation/NSNumber.h>
#import <Foundation/NSString.h>
#import <Foundation/NSUndoManager.h>

#include <Block.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#include <string.h>
#include <time.h>
#include <zlib.h>

/* ---- small file-system helpers ---------------------------------------------------------------- */

static NSError *fn_error(NSInteger code, NSString *message)
{
	NSDictionary *info = (message != nil)
		? [NSDictionary dictionaryWithObject:message forKey:NSLocalizedDescriptionKey] : nil;

	return [NSError errorWithDomain:@"WSFileOperations" code:code userInfo:info];
}

static BOOL fn_is_directory(NSString *path)
{
	BOOL isDirectory = NO;

	(void)[[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory];
	return isDirectory;
}

static BOOL fn_same_volume(NSString *path, NSString *directory)
{
	struct stat a, b;

	if (stat([path UTF8String], &a) != 0 || stat([directory UTF8String], &b) != 0) {
		return YES;
	}
	return a.st_dev == b.st_dev;
}

static NSString *fn_unique_name(NSString *directory, NSString *name)
{
	NSFileManager *manager = [NSFileManager defaultManager];
	NSString *candidate = name;
	NSString *base;
	NSString *extension;
	NSInteger n = 2;

	if (![manager fileExistsAtPath:[directory stringByAppendingPathComponent:candidate]]) {
		return candidate;
	}
	base = [name stringByDeletingPathExtension];
	extension = [name pathExtension];
	for (;;) {
		candidate = ([extension length] > 0)
			? [NSString stringWithFormat:@"%@ %ld.%@", base, (long)n, extension]
			: [NSString stringWithFormat:@"%@ %ld", base, (long)n];
		if (![manager fileExistsAtPath:[directory stringByAppendingPathComponent:candidate]]) {
			return candidate;
		}
		n++;
	}
}

/* ---- a ZIP writer: store or raw-deflate, written straight to the file, central directory, EOCD ----------------

 * **THE ARCHIVE IS WRITTEN AS IT IS MADE, NOT BUILT IN MEMORY.** The first version read every file whole into an
 * `NSData` and kept the archive in another one. MEASURED, a 191 MB tree cost a peak RSS of 409 MB, and a folder of a
 * couple of gigabytes would have needed several times its own size. The destination is opened once, each entry's local
 * header and data are appended, and only the CENTRAL DIRECTORY stays in memory — one record per entry, some dozens of
 * bytes each.
 *
 * **AND THE LOCAL HEADER IS REWRITTEN, WHICH IS WHY THE FILE IS OPENED FOR WRITING RATHER THAN APPENDED TO.** A ZIP's
 * local header comes BEFORE the bytes it describes and carries their CRC and both sizes, which are not known until the
 * bytes have gone out. So the header is written with zeros there, the entry streams through zlib (or straight through),
 * and the header is patched in place with `fseek`. A data descriptor after the data would avoid the seek and is legal,
 * but older readers disagree about it; this writes the plainer form.
 *
 * **STORE OR DEFLATE IS DECIDED FROM THE FIRST BLOCK.** A JPEG, a PNG, an archive: deflating them costs the whole
 * file's time and saves nothing, and the entry comes out a few bytes LARGER. The first 64 KB are deflated into a
 * scratch buffer, and a file whose first block does not shrink is stored and never fed to zlib at all. A file that
 * misleads the sample is still correct — it is simply stored deflated — and the alternative (seek back over every
 * incompressible file and rewrite it) is not worth a second pass over the data.
 *
 * **AND AN ENTRY KEEPS ITS OWN TIME AND ITS OWN MODE.** Every entry used to be stamped with the archive's own "now" and
 * given mode 0, so a restored file was `-rw----`; MEASURED, a shell script with its executable bit came out
 * un-runnable. The DOS time is the file's `mtime`, the external attributes are its `st_mode` with `version made by`
 * saying unix (which is what makes a reader honour them), and a SYMLINK IS STORED AS A LINK — its target as the payload,
 * with the link bit in its mode — rather than followed. */

#define AGZIP_CHUNK		65536		/* the block a file is read in, and the sample the store/deflate choice uses */
#define AGZIP_DOS_DIRECTORY	0x10u		/* the DOS attribute byte's directory bit */
#define AGZIP_MADE_BY_UNIX	3u		/* the "version made by" high byte: 3 is unix */
#define AGZIP_VERSION		20u		/* 2.0, which is what a plain entry needs */
#define AGZIP_VERSION_ZIP64	45u		/* 4.5, which is what an entry with a 64-bit field needs */
#define AGZIP_ZIP64_SENTINEL	0xffffffffull	/* a 32-bit field saying "the value is in the extra field" */
#define AGZIP_MAX_ENTRIES	0xffffull	/* a 16-bit count that is full */

/* **THE LIMITS ARE THE STANDARD ONES, AND A PROBE CAN LOWER THEM.** A real ZIP64 test needs four gigabytes of data or
 * sixty-six thousand entries, which no suite should write, so `+cg_setZip64LimitsForTesting:entries:` lets a probe say
 * "treat anything past a kilobyte as needing 64 bits" and the DECISION and the RECORDS are measured on a few bytes.
 * Zero restores the format's own limits, and the product never sets them. */
static unsigned long long s_zip64_byte_limit = 0;
static unsigned long long s_zip64_entry_limit = 0;

/* A LITTLE-ENDIAN SCRATCH BUFFER, because a header is built field by field before it goes out. */
typedef struct {
	unsigned char bytes[128];
	size_t length;
} AGBytes;

static void fn_bytes16(AGBytes *buffer, uint16_t value)
{
	if (buffer->length + 2 > sizeof buffer->bytes) {
		return;
	}
	buffer->bytes[buffer->length++] = (unsigned char)(value & 0xff);
	buffer->bytes[buffer->length++] = (unsigned char)((value >> 8) & 0xff);
}

static void fn_bytes64(AGBytes *buffer, uint64_t value)
{
	int i;

	if (buffer->length + 8 > sizeof buffer->bytes) {
		return;
	}
	for (i = 0; i < 8; i++) {
		buffer->bytes[buffer->length++] = (unsigned char)((value >> (8 * i)) & 0xff);
	}
}

static void fn_bytes32(AGBytes *buffer, uint32_t value)
{
	if (buffer->length + 4 > sizeof buffer->bytes) {
		return;
	}
	buffer->bytes[buffer->length++] = (unsigned char)(value & 0xff);
	buffer->bytes[buffer->length++] = (unsigned char)((value >> 8) & 0xff);
	buffer->bytes[buffer->length++] = (unsigned char)((value >> 16) & 0xff);
	buffer->bytes[buffer->length++] = (unsigned char)((value >> 24) & 0xff);
}

/* **WHETHER DEFLATE IS WORTH THE WHOLE FILE, ASKED OF ITS FIRST BLOCK.** The compressed sample has to be smaller by
 * more than a margin: 64 KB of a photograph can come out a hundred bytes smaller and still be a file that pays the
 * deflate cost for nothing. */
static BOOL fn_block_compresses(const unsigned char *bytes, size_t length)
{
	z_stream stream;
	unsigned char *out;
	uLong bound;
	BOOL worthIt = NO;

	memset(&stream, 0, sizeof stream);
	if (deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY) != Z_OK) {
		return NO;
	}
	bound = deflateBound(&stream, (uLong)length);
	out = malloc((size_t)bound);
	if (out != NULL) {
		stream.next_in = (Bytef *)bytes;
		stream.avail_in = (uInt)length;
		stream.next_out = out;
		stream.avail_out = (uInt)bound;
		if (deflate(&stream, Z_FINISH) == Z_STREAM_END) {
			worthIt = (stream.total_out + 64u < (uLong)length);
		}
		free(out);
	}
	deflateEnd(&stream);
	return worthIt;
}

typedef void (^AGZipProgress)(NSString *path);

@interface AGZipBuilder : NSObject
{
	FILE *_file;			/* the archive, opened for writing */
	NSString *_path;		/* COPIED: where it is, so a failure can take it away */
	NSMutableArray *_entries;	/* RETAINED: NSDictionary per central record */
	AGZipProgress _progress;	/* COPIED, or NULL */
	unsigned long long _offset;	/* bytes written so far */
}
- (instancetype)initWithPath:(NSString *)path progress:(nullable AGZipProgress)progress;
- (BOOL)addPath:(NSString *)path entryName:(NSString *)entryName error:(NSError **)error;
- (BOOL)finishWithError:(NSError **)error;
- (void)discard;
@end

@implementation AGZipBuilder

- (instancetype)initWithPath:(NSString *)path progress:(AGZipProgress)progress
{
	self = [super init];
	if (self == nil) {
		return nil;
	}
	_path = [path copy];
	_entries = [[NSMutableArray alloc] init];
	if (progress != nil) {
		_progress = Block_copy(progress);
	}
	_file = fopen([path fileSystemRepresentation], "wb");
	if (_file == NULL) {
		[self release];
		return nil;
	}
	return self;
}

- (void)dealloc
{
	if (_file != NULL) {
		fclose(_file);
	}
	if (_progress != NULL) {
		Block_release(_progress);
	}
	[_path release];
	[_entries release];
	[super dealloc];
}

- (BOOL)writeBytes:(const void *)bytes length:(size_t)length
{
	if (length == 0) {
		return YES;
	}
	if (fwrite(bytes, 1, length, _file) != length) {
		return NO;
	}
	_offset += length;
	return YES;
}

/* **THE HEADER, WITH THE THREE NUMBERS IT DOES NOT KNOW YET LEFT AT ZERO — AND WITH A ZIP64 EXTRA FIELD WHEN THE ENTRY
 * IS TOO BIG FOR A 32-BIT SIZE.** The decision is made from the file's own `st_size` before a byte of it is read, which
 * is the only way to put the extra field IN the local header: a ZIP64 extra cannot be added afterwards without moving
 * everything that follows it. A file that grows past the limit between the `stat` and the last block is refused rather
 * than written with a size that does not fit. */
- (BOOL)beginEntry:(NSString *)entryName method:(uint16_t)method time:(uint16_t)dosTime date:(uint16_t)dosDate
	     zip64:(BOOL)zip64 headerAt:(unsigned long long *)headerOffset sizesAt:(unsigned long long *)sizesAt
{
	const char *name = [entryName fileSystemRepresentation];
	size_t nameLength = strlen(name);
	uint16_t extraLength = zip64 ? 20 : 0;
	AGBytes header;

	if (nameLength == 0 || nameLength > 0xffffu) {
		return NO;
	}
	header.length = 0;
	fn_bytes32(&header, 0x04034b50u);
	fn_bytes16(&header, zip64 ? (uint16_t)AGZIP_VERSION_ZIP64 : (uint16_t)AGZIP_VERSION);
	fn_bytes16(&header, 0x0800u);	/* names are UTF-8 */
	fn_bytes16(&header, method);
	fn_bytes16(&header, dosTime);
	fn_bytes16(&header, dosDate);
	fn_bytes32(&header, 0);		/* crc, patched */
	fn_bytes32(&header, zip64 ? (uint32_t)AGZIP_ZIP64_SENTINEL : 0);	/* compressed size, patched */
	fn_bytes32(&header, zip64 ? (uint32_t)AGZIP_ZIP64_SENTINEL : 0);	/* uncompressed size, patched */
	fn_bytes16(&header, (uint16_t)nameLength);
	fn_bytes16(&header, extraLength);
	if (headerOffset != NULL) {
		*headerOffset = _offset;
	}
	if (![self writeBytes:header.bytes length:header.length] || ![self writeBytes:name length:nameLength]) {
		return NO;
	}
	if (zip64) {
		AGBytes extra;

		extra.length = 0;
		fn_bytes16(&extra, 0x0001u);	/* the ZIP64 extra field */
		fn_bytes16(&extra, 16);		/* two 8-byte values: uncompressed, then compressed */
		fn_bytes64(&extra, 0);		/* patched */
		fn_bytes64(&extra, 0);		/* patched */
		if (sizesAt != NULL) {
			*sizesAt = _offset + 4;
		}
		if (![self writeBytes:extra.bytes length:extra.length]) {
			return NO;
		}
	} else if (sizesAt != NULL) {
		*sizesAt = 0;
	}
	return YES;
}

- (BOOL)patchHeaderAt:(unsigned long long)headerOffset sizesAt:(unsigned long long)sizesAt zip64:(BOOL)zip64
		  crc:(uint32_t)crc compressed:(uint64_t)compressed uncompressed:(uint64_t)uncompressed
{
	unsigned long long end = _offset;
	AGBytes patch;

	patch.length = 0;
	fn_bytes32(&patch, crc);
	fn_bytes32(&patch, zip64 ? (uint32_t)AGZIP_ZIP64_SENTINEL : (uint32_t)compressed);
	fn_bytes32(&patch, zip64 ? (uint32_t)AGZIP_ZIP64_SENTINEL : (uint32_t)uncompressed);
	if (fseek(_file, (long)(headerOffset + 14), SEEK_SET) != 0) {
		return NO;
	}
	if (fwrite(patch.bytes, 1, patch.length, _file) != patch.length) {
		return NO;
	}
	if (zip64) {
		AGBytes sizes;

		sizes.length = 0;
		fn_bytes64(&sizes, uncompressed);
		fn_bytes64(&sizes, compressed);
		if (fseek(_file, (long)sizesAt, SEEK_SET) != 0) {
			return NO;
		}
		if (fwrite(sizes.bytes, 1, sizes.length, _file) != sizes.length) {
			return NO;
		}
	}
	return fseek(_file, (long)end, SEEK_SET) == 0;
}

- (void)recordEntry:(NSString *)entryName crc:(uint32_t)crc compressed:(uint64_t)compressed
	 uncompressed:(uint64_t)uncompressed method:(uint16_t)method offset:(unsigned long long)offset
	       time:(uint16_t)dosTime date:(uint16_t)dosDate mode:(mode_t)mode zip64:(BOOL)zip64
{
	[_entries addObject:[NSDictionary dictionaryWithObjectsAndKeys:
		entryName, @"name",
		[NSNumber numberWithUnsignedInt:crc], @"crc",
		[NSNumber numberWithUnsignedLongLong:compressed], @"csize",
		[NSNumber numberWithUnsignedLongLong:uncompressed], @"usize",
		[NSNumber numberWithUnsignedShort:method], @"method",
		[NSNumber numberWithUnsignedLongLong:offset], @"offset",
		[NSNumber numberWithUnsignedShort:dosTime], @"time",
		[NSNumber numberWithUnsignedShort:dosDate], @"date",
		[NSNumber numberWithUnsignedInt:(unsigned int)mode], @"mode",
		[NSNumber numberWithBool:zip64], @"zip64", nil]];
}

/* **THE PAYLOAD, STRAIGHT THROUGH OR THROUGH ZLIB, A BLOCK AT A TIME.** The CRC and both sizes come out of the same
 * pass, which is the whole point: nothing here holds more than `AGZIP_CHUNK` bytes of the file. */
- (BOOL)addFile:(NSString *)path entryName:(NSString *)entryName stat:(const struct stat *)st error:(NSError **)error
{
	FILE *in;
	unsigned char *buffer = NULL;
	size_t sample;
	uint16_t method = 0;
	BOOL zip64 = ((unsigned long long)st->st_size >= [WSFileOperations cg_zip64ByteLimit]);
	unsigned long long headerOffset = 0;
	unsigned long long sizesAt = 0;
	uint32_t crc = 0;
	uint64_t total = 0;
	uint64_t written = 0;
	uint16_t dosTime = 0;
	uint16_t dosDate = 0;
	struct tm broken;
	BOOL ok = NO;

	if (localtime_r(&st->st_mtime, &broken) != NULL) {
		dosTime = (uint16_t)((broken.tm_hour << 11) | (broken.tm_min << 5) | (broken.tm_sec / 2));
		dosDate = (uint16_t)(((broken.tm_year - 80) << 9) | ((broken.tm_mon + 1) << 5) | broken.tm_mday);
	}
	in = fopen([path fileSystemRepresentation], "rb");
	if (in == NULL) {
		if (error != NULL) *error = fn_error(12, [NSString stringWithFormat:@"%@ could not be read", path]);
		return NO;
	}
	buffer = malloc(AGZIP_CHUNK);
	if (buffer == NULL) {
		fclose(in);
		return NO;
	}
	sample = fread(buffer, 1, AGZIP_CHUNK, in);
	if (sample > 0 && fn_block_compresses(buffer, sample)) {
		method = 8;
	}
	rewind(in);
	if (![self beginEntry:entryName method:method time:dosTime date:dosDate zip64:zip64 headerAt:&headerOffset
		     sizesAt:&sizesAt]) {
		if (error != NULL) *error = fn_error(12, @"the archive could not be written");
		goto done;
	}
	{
		z_stream stream;
		unsigned char *out = NULL;
		uLong bound = 0;
		BOOL deflateOpen = NO;

		memset(&stream, 0, sizeof stream);
		if (method == 8) {
			if (deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8,
					 Z_DEFAULT_STRATEGY) != Z_OK) {
				if (error != NULL) *error = fn_error(11, @"zlib could not start");
				goto done;
			}
			deflateOpen = YES;
			bound = deflateBound(&stream, AGZIP_CHUNK) + 64u;
			out = malloc((size_t)bound);
			if (out == NULL) {
				if (error != NULL) *error = fn_error(11, @"zlib could not start");
				goto done;
			}
		}
		for (;;) {
			size_t got = fread(buffer, 1, AGZIP_CHUNK, in);

			if (got == 0) {
				break;
			}
			crc = (uint32_t)crc32(crc, buffer, (uInt)got);
			total += got;
			/* **A FILE THAT GREW PAST THE LIMIT AFTER ITS HEADER WAS WRITTEN IS REFUSED, NOT MISCARRIED.** The ZIP64
			 * extra field has to be in the LOCAL header, which is already on the disk by now; writing the size into a
			 * 32-bit field instead would be an archive that lies about itself. */
			if (!zip64 && total > [WSFileOperations cg_zip64ByteLimit]) {
				if (error != NULL) *error = fn_error(10, @"the file grew while it was being compressed");
				goto done;
			}
			if (!deflateOpen) {
				if (![self writeBytes:buffer length:got]) {
					if (error != NULL) *error = fn_error(12, @"the archive could not be written");
					goto done;
				}
				written += got;
			} else {
				stream.next_in = buffer;
				stream.avail_in = (uInt)got;
				do {
					size_t produced;

					stream.next_out = out;
					stream.avail_out = (uInt)bound;
					if (deflate(&stream, Z_NO_FLUSH) == Z_STREAM_ERROR) {
						if (error != NULL) *error = fn_error(11, @"zlib failed");
						goto done;
					}
					produced = (size_t)bound - stream.avail_out;
					if (![self writeBytes:out length:produced]) {
						if (error != NULL) *error = fn_error(12, @"the archive could not be written");
						goto done;
					}
					written += produced;
				} while (stream.avail_out == 0);
			}
		}
		if (deflateOpen) {
			int zr;

			do {
				size_t produced;

				stream.next_out = out;
				stream.avail_out = (uInt)bound;
				zr = deflate(&stream, Z_FINISH);
				if (zr == Z_STREAM_ERROR) {
					if (error != NULL) *error = fn_error(11, @"zlib failed");
					goto done;
				}
				produced = (size_t)bound - stream.avail_out;
				if (![self writeBytes:out length:produced]) {
					if (error != NULL) *error = fn_error(12, @"the archive could not be written");
					goto done;
				}
				written += produced;
			} while (zr != Z_STREAM_END);
		}
		if (out != NULL) {
			free(out);
			out = NULL;
		}
		if (deflateOpen) {
			deflateEnd(&stream);
			deflateOpen = NO;
		}
		if (zip64 && (total > AGZIP_ZIP64_SENTINEL) == 0 && written <= AGZIP_ZIP64_SENTINEL) {
			/* nothing to do: the extra field carries the same numbers the 32-bit fields could have */
		}
	}
	if (![self patchHeaderAt:headerOffset sizesAt:sizesAt zip64:zip64 crc:crc compressed:written
		      uncompressed:total]) {
		if (error != NULL) *error = fn_error(12, @"the archive could not be written");
		goto done;
	}
	[self recordEntry:entryName crc:crc compressed:written uncompressed:total method:method offset:headerOffset
		     time:dosTime date:dosDate mode:st->st_mode zip64:zip64];
	ok = YES;
done:
	free(buffer);
	fclose(in);
	return ok;
}

/* A DIRECTORY IS AN ENTRY WITH A TRAILING SLASH AND NO PAYLOAD; A SYMLINK IS AN ENTRY WHOSE PAYLOAD IS ITS TARGET. */
- (BOOL)addEmptyEntry:(NSString *)entryName stat:(const struct stat *)st isDirectory:(BOOL)isDirectory
		payload:(NSData *)payload error:(NSError **)error
{
	unsigned long long headerOffset = 0;
	uint16_t dosTime = 0;
	uint16_t dosDate = 0;
	uint32_t crc = 0;
	struct tm broken;
	NSString *name = isDirectory ? [entryName stringByAppendingString:@"/"] : entryName;
	NSUInteger length = [payload length];

	if (localtime_r(&st->st_mtime, &broken) != NULL) {
		dosTime = (uint16_t)((broken.tm_hour << 11) | (broken.tm_min << 5) | (broken.tm_sec / 2));
		dosDate = (uint16_t)(((broken.tm_year - 80) << 9) | ((broken.tm_mon + 1) << 5) | broken.tm_mday);
	}
	if (![self beginEntry:name method:0 time:dosTime date:dosDate zip64:NO headerAt:&headerOffset sizesAt:NULL]) {
		if (error != NULL) *error = fn_error(12, @"the archive could not be written");
		return NO;
	}
	if (length > 0) {
		crc = (uint32_t)crc32(crc32(0L, Z_NULL, 0), [payload bytes], (uInt)length);
		if (![self writeBytes:[payload bytes] length:length]) {
			if (error != NULL) *error = fn_error(12, @"the archive could not be written");
			return NO;
		}
	}
	if (![self patchHeaderAt:headerOffset sizesAt:0 zip64:NO crc:crc compressed:length uncompressed:length]) {
		if (error != NULL) *error = fn_error(12, @"the archive could not be written");
		return NO;
	}
	[self recordEntry:name crc:crc compressed:length uncompressed:length method:0 offset:headerOffset
		     time:dosTime date:dosDate mode:st->st_mode zip64:NO];
	return YES;
}

- (void)reportProgress:(NSString *)path
{
	if (_progress != NULL) {
		_progress(path);
	}
}

- (BOOL)addPath:(NSString *)path entryName:(NSString *)entryName error:(NSError **)error
{
	struct stat st;

	if (lstat([path fileSystemRepresentation], &st) != 0) {
		if (error != NULL) *error = fn_error(12, [NSString stringWithFormat:@"%@ is not there", path]);
		return NO;
	}
	if (S_ISDIR(st.st_mode)) {
		DIR *directory;
		struct dirent *entry;
		NSMutableArray *names;

		if (![self addEmptyEntry:entryName stat:&st isDirectory:YES payload:[NSData data] error:error]) {
			return NO;
		}
		names = [[NSMutableArray alloc] init];
		directory = opendir([path fileSystemRepresentation]);
		if (directory == NULL) {
			if (error != NULL) *error = fn_error(12, [NSString stringWithFormat:@"%@ could not be read", path]);
			[names release];
			return NO;
		}
		while ((entry = readdir(directory)) != NULL) {
			if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
				continue;
			}
			[names addObject:[NSString stringWithUTF8String:entry->d_name]];
		}
		closedir(directory);
		/* THE CHILDREN ARE TAKEN IN THE ORDER THE DIRECTORY GIVES THEM, which `readdir` does not promise to be
		 * sorted: the archive is not required to be, and sorting here would be a second rule the views would have
		 * to agree with. */
		{
			NSUInteger i;

			for (i = 0; i < [names count]; i++) {
				NSString *child = [names objectAtIndex:i];
				NSString *childPath = [path stringByAppendingPathComponent:child];
				NSString *childName = [entryName stringByAppendingFormat:@"/%@", child];

				if (![self addPath:childPath entryName:childName error:error]) {
					[names release];
					return NO;
				}
			}
		}
		[names release];
		return YES;
	}
	if (S_ISLNK(st.st_mode)) {
		char target[PATH_MAX];
		ssize_t length = readlink([path fileSystemRepresentation], target, sizeof target);
		BOOL ok;

		if (length < 0) {
			if (error != NULL) *error = fn_error(12, [NSString stringWithFormat:@"%@ could not be read", path]);
			return NO;
		}
		ok = [self addEmptyEntry:entryName stat:&st isDirectory:NO
				 payload:[NSData dataWithBytes:target length:(NSUInteger)length] error:error];
		if (ok) {
			[self reportProgress:path];
		}
		return ok;
	}
	{
		/* **THE BAR COUNTS ENTRIES, WHICH IS WHAT THE PRE-COUNT COUNTS**: a regular file and a symlink are one each, a
		 * folder is not one at all. Reporting from one place is what keeps the two halves agreeing — MEASURED, a
		 * symlink that reported nothing made the bar end at "4 of 5". */
		BOOL ok = [self addFile:path entryName:entryName stat:&st error:error];

		if (ok) {
			[self reportProgress:path];
		}
		return ok;
	}
}

- (BOOL)finishWithError:(NSError **)error
{
	unsigned long long centralOffset = _offset;
	unsigned long long byteLimit = [WSFileOperations cg_zip64ByteLimit];
	unsigned long long entryLimit = [WSFileOperations cg_zip64EntryLimit];
	NSUInteger i;

	for (i = 0; i < [_entries count]; i++) {
		NSDictionary *record = [_entries objectAtIndex:i];
		NSString *name = [record objectForKey:@"name"];
		const char *bytes = [name fileSystemRepresentation];
		size_t length = strlen(bytes);
		uint64_t compressed = [[record objectForKey:@"csize"] unsignedLongLongValue];
		uint64_t uncompressed = [[record objectForKey:@"usize"] unsignedLongLongValue];
		uint64_t offset = [[record objectForKey:@"offset"] unsignedLongLongValue];
		mode_t mode = (mode_t)[[record objectForKey:@"mode"] unsignedIntValue];
		uint32_t attributes = (uint32_t)(mode << 16);
		BOOL entryZip64 = (compressed >= byteLimit || uncompressed >= byteLimit);
		BOOL offsetZip64 = (offset >= byteLimit);
		AGBytes header;

		if (S_ISDIR(mode)) {
			attributes |= AGZIP_DOS_DIRECTORY;
		}
		header.length = 0;
		fn_bytes32(&header, 0x02014b50u);
		fn_bytes16(&header, (uint16_t)((AGZIP_MADE_BY_UNIX << 8) |
					     ((entryZip64 || offsetZip64) ? AGZIP_VERSION_ZIP64 : AGZIP_VERSION)));
		fn_bytes16(&header, (uint16_t)((entryZip64 || offsetZip64) ? AGZIP_VERSION_ZIP64 : AGZIP_VERSION));
		fn_bytes16(&header, 0x0800u);
		fn_bytes16(&header, (uint16_t)[[record objectForKey:@"method"] unsignedShortValue]);
		fn_bytes16(&header, (uint16_t)[[record objectForKey:@"time"] unsignedShortValue]);
		fn_bytes16(&header, (uint16_t)[[record objectForKey:@"date"] unsignedShortValue]);
		fn_bytes32(&header, [[record objectForKey:@"crc"] unsignedIntValue]);
		fn_bytes32(&header, entryZip64 ? (uint32_t)AGZIP_ZIP64_SENTINEL : (uint32_t)compressed);
		fn_bytes32(&header, entryZip64 ? (uint32_t)AGZIP_ZIP64_SENTINEL : (uint32_t)uncompressed);
		fn_bytes16(&header, (uint16_t)length);
		/* **THE FIELDS A ZIP64 EXTRA CARRIES ARE THE ONES MARKED AS SENTINELS, IN THIS ORDER AND NO OTHER:**
		 * uncompressed size, compressed size, then the local header's offset. A reader walks the extra in that order
		 * and assigns each value to the next saturated field, so including a value that was not marked (or sharing one
		 * that was) makes the archive a different one than it says it is. */
		fn_bytes16(&header, (uint16_t)((entryZip64 ? 16 : 0) + (offsetZip64 ? 8 : 0) + (entryZip64 || offsetZip64 ? 4 : 0)));
		fn_bytes16(&header, 0);		/* comment */
		fn_bytes16(&header, 0);		/* disk */
		fn_bytes16(&header, 0);		/* internal attributes */
		fn_bytes32(&header, attributes);
		fn_bytes32(&header, offsetZip64 ? (uint32_t)AGZIP_ZIP64_SENTINEL : (uint32_t)offset);
		if (![self writeBytes:header.bytes length:header.length] || ![self writeBytes:bytes length:length]) {
			if (error != NULL) *error = fn_error(12, @"the archive could not be written");
			return NO;
		}
		if (entryZip64 || offsetZip64) {
			AGBytes extra;

			extra.length = 0;
			fn_bytes16(&extra, 0x0001u);
			fn_bytes16(&extra, (uint16_t)((entryZip64 ? 16 : 0) + (offsetZip64 ? 8 : 0)));
			if (entryZip64) {
				fn_bytes64(&extra, uncompressed);
				fn_bytes64(&extra, compressed);
			}
			if (offsetZip64) {
				fn_bytes64(&extra, offset);
			}
			if (![self writeBytes:extra.bytes length:extra.length]) {
				if (error != NULL) *error = fn_error(12, @"the archive could not be written");
				return NO;
			}
		}
	}
	{
		uint64_t centralSize = _offset - centralOffset;
		uint64_t count = (uint64_t)[_entries count];
		BOOL big = (count >= entryLimit || centralSize >= byteLimit || centralOffset >= byteLimit);

		if (big) {
			/* THE ZIP64 END OF CENTRAL DIRECTORY, ITS LOCATOR, AND AN EOCD THAT SAYS "LOOK ABOVE ME". */
			unsigned long long recordAt = _offset;
			AGBytes record;
			AGBytes locator;
			AGBytes end;

			record.length = 0;
			fn_bytes32(&record, 0x06064b50u);
			fn_bytes64(&record, 44);	/* the size of the rest of this record */
			fn_bytes16(&record, (uint16_t)((AGZIP_MADE_BY_UNIX << 8) | AGZIP_VERSION_ZIP64));
			fn_bytes16(&record, (uint16_t)AGZIP_VERSION_ZIP64);
			fn_bytes32(&record, 0);		/* this disk */
			fn_bytes32(&record, 0);		/* the disk the directory starts on */
			fn_bytes64(&record, count);	/* entries on this disk */
			fn_bytes64(&record, count);	/* entries in total */
			fn_bytes64(&record, centralSize);
			fn_bytes64(&record, centralOffset);
			if (![self writeBytes:record.bytes length:record.length]) {
				if (error != NULL) *error = fn_error(12, @"the archive could not be written");
				return NO;
			}
			locator.length = 0;
			fn_bytes32(&locator, 0x07064b50u);
			fn_bytes32(&locator, 0);	/* the disk the ZIP64 EOCD is on */
			fn_bytes64(&locator, recordAt);
			fn_bytes32(&locator, 1);	/* how many disks there are */
			if (![self writeBytes:locator.bytes length:locator.length]) {
				if (error != NULL) *error = fn_error(12, @"the archive could not be written");
				return NO;
			}
		}
		{
			AGBytes end;

			end.length = 0;
			fn_bytes32(&end, 0x06054b50u);
			fn_bytes16(&end, 0);
			fn_bytes16(&end, 0);
			fn_bytes16(&end, (uint16_t)(big ? AGZIP_MAX_ENTRIES : count));
			fn_bytes16(&end, (uint16_t)(big ? AGZIP_MAX_ENTRIES : count));
			fn_bytes32(&end, big ? (uint32_t)AGZIP_ZIP64_SENTINEL : (uint32_t)centralSize);
			fn_bytes32(&end, big ? (uint32_t)AGZIP_ZIP64_SENTINEL : (uint32_t)centralOffset);
			fn_bytes16(&end, 0);
			if (![self writeBytes:end.bytes length:end.length]) {
				if (error != NULL) *error = fn_error(12, @"the archive could not be written");
				return NO;
			}
		}
	}
	if (fflush(_file) != 0 || fclose(_file) != 0) {
		_file = NULL;
		if (error != NULL) *error = fn_error(12, @"the archive could not be written");
		return NO;
	}
	_file = NULL;
	return YES;
}

/* **A FAILED COMPRESS LEAVES NOTHING BEHIND.** The archive is a file now, not a buffer that only became a file at the
 * end, so the half-written one has to be taken away — a 191 MB stub beside the folder would be worse than the error. */
- (void)discard
{
	NSString *path = [[_path retain] autorelease];

	if (_file != NULL) {
		fclose(_file);
		_file = NULL;
	}
	(void)[[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

@end

/* ---- a ZIP reader: the central directory, a streaming inflate, and a folder named for the archive --------

 * **EXTRACTING IS THE OTHER HALF OF COMPRESSING, AND IT IS WRITTEN HERE FOR THE SAME REASON.** The archive this tree
 * writes is the archive it reads: store and raw deflate, the central directory's names and modes, ZIP64 when a record
 * needed 64 bits. No external unarchiver is run, so a `.zip` needs nothing installed to open.
 *
 * **AND EVERY ENTRY'S PATH IS CHECKED BEFORE ANYTHING IS CREATED.** A name that starts with `/`, or that has a `..`
 * component, is an archive trying to write outside the folder it was asked to unpack into — the classic zip-slip — and
 * it is REFUSED WHOLE: the folder made so far is removed and the answer is nil. A partial extraction of a hostile
 * archive is the one outcome worth less than no extraction at all.
 *
 * **A FILE IS STREAMED THROUGH zlib, A BLOCK AT A TIME**, the same rule the writer follows: the archive's own bytes are
 * never all in memory, and neither is the file being unpacked. */

#define AGUNZIP_CHUNK 65536

static uint16_t fn_le16(const unsigned char *bytes)
{
	return (uint16_t)((uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8));
}

static uint32_t fn_le32(const unsigned char *bytes)
{
	return (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) | ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
}

static uint64_t fn_le64(const unsigned char *bytes)
{
	return (uint64_t)fn_le32(bytes) | ((uint64_t)fn_le32(bytes + 4) << 32);
}

/* An entry that carries a ZIP64 extra field has its real numbers there, in the order uncompressed, compressed, offset. */
static void fn_zip64_values(const unsigned char *extra, size_t length, uint64_t *uncompressed, uint64_t *compressed,
			    uint64_t *offset)
{
	size_t at = 0;

	while (at + 4 <= length) {
		uint16_t tag = fn_le16(extra + at);
		uint16_t size = fn_le16(extra + at + 2);
		size_t cursor = at + 4;

		if (tag == 0x0001) {
			if (cursor + 8 <= at + 4 + size) {
				*uncompressed = fn_le64(extra + cursor);
				cursor += 8;
			}
			if (cursor + 8 <= at + 4 + size) {
				*compressed = fn_le64(extra + cursor);
				cursor += 8;
			}
			if (cursor + 8 <= at + 4 + size) {
				*offset = fn_le64(extra + cursor);
			}
			return;
		}
		at += 4 + size;
	}
}

/* **A NAME THAT LEAVES THE FOLDER IS NOT A NAME.** Split on `/`, and refuse an absolute path, a `..` component, and an
 * empty name; a `.` component is harmless and is skipped by the caller. */
static BOOL fn_entry_name_is_safe(const char *name)
{
	const char *at = name;

	if (name == NULL || name[0] == '\0' || name[0] == '/') {
		return NO;
	}
	while (*at != '\0') {
		const char *end = strchr(at, '/');
		size_t length = (end != NULL) ? (size_t)(end - at) : strlen(at);

		if (length == 2 && at[0] == '.' && at[1] == '.') {
			return NO;
		}
		if (end == NULL) {
			break;
		}
		at = end + 1;
	}
	return YES;
}

/* THE DOS STAMP A ZIP CARRIES, BACK INTO A `time_t` — local time, the zone the writer used. */
static void fn_dos_to_time(uint16_t dosDate, uint16_t dosTime, struct timespec *out)
{
	struct tm broken;
	time_t seconds;

	memset(&broken, 0, sizeof broken);
	broken.tm_year = ((dosDate >> 9) & 0x7f) + 80;
	broken.tm_mon = ((dosDate >> 5) & 0x0f) - 1;
	broken.tm_mday = dosDate & 0x1f;
	broken.tm_hour = (dosTime >> 11) & 0x1f;
	broken.tm_min = (dosTime >> 5) & 0x3f;
	broken.tm_sec = (int)(dosTime & 0x1f) * 2;
	broken.tm_isdst = -1;
	if (broken.tm_mon < 0 || broken.tm_mday < 1) {
		return;
	}
	seconds = mktime(&broken);
	out->tv_sec = seconds;
	out->tv_nsec = 0;
}

/* ---- THE OPERATIONS -------------------------------------------------------------------------- */

@implementation WSFileOperations

/* **THE ZIP64 THRESHOLDS, AND THE PROBE'S DOOR INTO THEM.** The format's own limits are 4 GB and 65,535 entries; a test
 * that had to write either would be a test nobody runs, so a probe can lower them and read back what the writer did with
 * the smaller numbers. The product never calls the setter. */
+ (unsigned long long)cg_zip64ByteLimit
{
	return (s_zip64_byte_limit > 0) ? s_zip64_byte_limit : AGZIP_ZIP64_SENTINEL;
}

+ (unsigned long long)cg_zip64EntryLimit
{
	return (s_zip64_entry_limit > 0) ? s_zip64_entry_limit : AGZIP_MAX_ENTRIES;
}

+ (void)cg_setZip64LimitsForTesting:(unsigned long long)bytes entries:(unsigned long long)entries
{
	s_zip64_byte_limit = bytes;
	s_zip64_entry_limit = entries;
}

- (instancetype)initWithUndoManager:(NSUndoManager *)undoManager trash:(WSTrash *)trash
{
	self = [super init];
	if (self != nil) {
		_undoManager = undoManager;	/* NOT RETAINED */
		_trash = [trash retain];
	}
	return self;
}

- (void)dealloc
{
	[_trash release];
	if (_conflictHandler != NULL) Block_release(_conflictHandler);
	if (_progressHandler != NULL) Block_release(_progressHandler);
	[super dealloc];
}

- (NSUndoManager *)undoManager { return _undoManager; }
- (WSTrash *)trash { return _trash; }

- (void)setConflictHandler:(WSFileConflictHandler)handler
{
	WSFileConflictHandler copied = (handler != nil) ? Block_copy(handler) : NULL;

	if (_conflictHandler != NULL) Block_release(_conflictHandler);
	_conflictHandler = copied;
}

- (void)setProgressHandler:(WSFileProgressHandler)handler
{
	WSFileProgressHandler copied = (handler != nil) ? Block_copy(handler) : NULL;

	if (_progressHandler != NULL) Block_release(_progressHandler);
	_progressHandler = copied;
}

- (void)report:(NSUInteger)completed total:(NSUInteger)total path:(NSString *)path
{
	if (_progressHandler != nil) {
		_progressHandler(completed, total, path);
	}
}

- (void)registerUndo:(NSString *)name handler:(void (^)(id target))handler
{
	if (_undoManager != nil) {
		[_undoManager registerUndoWithTarget:self handler:handler];
		[_undoManager setActionName:name];
	}
}

- (WSFileConflictResolution)resolutionForDestination:(NSString *)destination
{
	WSFileConflictResolution resolution;

	if (_conflictHandler == nil) {
		return WSConflictKeepBoth;
	}
	resolution = _conflictHandler(destination);
	return (resolution == WSConflictUseDefault) ? WSConflictKeepBoth : resolution;
}

/* The destination after the conflict policy, or nil when the item is skipped. */
- (NSString *)destinationForSource:(NSString *)source directory:(NSString *)directory
				 error:(NSError **)error
{
	NSFileManager *manager = [NSFileManager defaultManager];
	NSString *destination = [directory stringByAppendingPathComponent:[source lastPathComponent]];

	if (![manager fileExistsAtPath:destination]) {
		return destination;
	}
	switch ([self resolutionForDestination:destination]) {
	case WSConflictSkip:
		return nil;
	case WSConflictReplace:
		if (![manager removeItemAtPath:destination error:error]) {
			return nil;
		}
		return destination;
	case WSConflictKeepBoth:
	case WSConflictUseDefault:
	default:
		return [directory stringByAppendingPathComponent:
			fn_unique_name(directory, [source lastPathComponent])];
	}
}

- (NSString *)createFolderInDirectory:(NSString *)directory name:(NSString *)name error:(NSError **)error
{
	NSFileManager *manager = [NSFileManager defaultManager];
	NSString *folderName = ([name length] > 0) ? name : @"untitled folder";
	NSString *path;

	folderName = fn_unique_name(directory, folderName);
	path = [directory stringByAppendingPathComponent:folderName];
	if (![manager createDirectoryAtPath:path withIntermediateDirectories:NO attributes:nil error:error]) {
		return nil;
	}
	[self registerUndo:@"New Folder" handler:^(id target) {
		(void)[[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
		(void)target;
	}];
	[self report:1 total:1 path:path];
	return path;
}

- (NSArray *)duplicatePaths:(NSArray *)paths inDirectory:(NSString *)directory error:(NSError **)error
{
	NSFileManager *manager = [NSFileManager defaultManager];
	NSMutableArray *copies = [[NSMutableArray alloc] init];
	NSUInteger i;

	for (i = 0; i < [paths count]; i++) {
		NSString *source = [paths objectAtIndex:i];
		NSString *base = [[source lastPathComponent] stringByDeletingPathExtension];
		NSString *extension = [[source lastPathComponent] pathExtension];
		NSString *name = ([extension length] > 0)
			? [NSString stringWithFormat:@"%@ copy.%@", base, extension]
			: [NSString stringWithFormat:@"%@ copy", base];
		NSString *destination = [directory stringByAppendingPathComponent:fn_unique_name(directory, name)];

		if (![manager copyItemAtPath:source toPath:destination error:error]) {
			[copies release];
			return nil;
		}
		[copies addObject:destination];
		[self report:i + 1 total:[paths count] path:destination];
	}
	[self registerUndo:@"Duplicate" handler:^(id target) {
		NSUInteger j;

		for (j = 0; j < [copies count]; j++) {
			(void)[[NSFileManager defaultManager] removeItemAtPath:[copies objectAtIndex:j] error:NULL];
		}
		(void)target;
	}];
	return [copies autorelease];
}

- (NSString *)renamePath:(NSString *)path toName:(NSString *)name error:(NSError **)error
{
	NSFileManager *manager = [NSFileManager defaultManager];
	NSString *parent = [path stringByDeletingLastPathComponent];
	NSString *destination;

	name = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if ([name length] == 0 || [name isEqual:@"."] || [name isEqual:@".."]
	    || [name rangeOfString:@"/"].location != NSNotFound) {
		if (error != NULL) *error = fn_error(20, @"the name is not usable");
		return nil;
	}
	destination = [parent stringByAppendingPathComponent:name];
	if ([manager fileExistsAtPath:destination] && ![destination isEqual:path]) {
		if (error != NULL) *error = fn_error(21, @"the destination exists");
		return nil;
	}
	if (![manager moveItemAtPath:path toPath:destination error:error]) {
		return nil;
	}
	[self registerUndo:@"Rename" handler:^(id target) {
		(void)[[NSFileManager defaultManager] moveItemAtPath:destination toPath:path error:NULL];
	}];
	return destination;
}

- (NSArray *)movePaths:(NSArray *)paths toDirectory:(NSString *)directory error:(NSError **)error
{
	NSFileManager *manager = [NSFileManager defaultManager];
	NSMutableArray *destinations = [[NSMutableArray alloc] init];
	NSMutableArray *sources = [[NSMutableArray alloc] init];
	NSUInteger i;

	for (i = 0; i < [paths count]; i++) {
		NSString *source = [paths objectAtIndex:i];
		NSString *destination = [self destinationForSource:source directory:directory error:error];
		BOOL ok = NO;

		if (destination == nil) {
			continue;
		}
		if (fn_same_volume(source, directory)) {
			ok = [manager moveItemAtPath:source toPath:destination error:error];
		} else {
			ok = [manager copyItemAtPath:source toPath:destination error:error];
			if (ok) {
				ok = [manager removeItemAtPath:source error:error];
			}
		}
		if (!ok) {
			[destinations release];
			[sources release];
			return nil;
		}
		[destinations addObject:destination];
		[sources addObject:source];
		[self report:i + 1 total:[paths count] path:destination];
	}
	[self registerUndo:@"Move" handler:^(id target) {
		NSUInteger j;

		for (j = 0; j < [destinations count]; j++) {
			NSString *from = [destinations objectAtIndex:j];
			NSString *to = [[sources objectAtIndex:j] stringByDeletingLastPathComponent];

			(void)[(WSFileOperations *)target movePaths:[NSArray arrayWithObject:from]
							 toDirectory:to error:NULL];
		}
	}];
	[sources release];
	return [destinations autorelease];
}

/* **THE DROP'S OWN MOVE.** `-movePaths:` resolves a conflict by keeping both, which is right for Paste and wrong for
 * a drop: a file dragged onto a folder where the name is taken must be refused, not silently duplicated. So the
 * preflight is this method's, in `WSItemDragPerform`'s own terms, and the move that follows is the one that records the
 * undo. */
- (BOOL)movePathsForDrop:(NSArray *)paths toDirectory:(NSString *)directory error:(NSError **)error
{
	NSFileManager *manager = [NSFileManager defaultManager];
	NSUInteger i;

	if ([paths count] == 0 || directory == nil) {
		return NO;
	}
	for (i = 0; i < [paths count]; i++) {
		NSString *source = [paths objectAtIndex:i];
		NSString *destination = [directory stringByAppendingPathComponent:[source lastPathComponent]];

		if (![manager fileExistsAtPath:source] || [manager fileExistsAtPath:destination]) {
			return NO;
		}
		if ([directory isEqual:source] || [directory hasPrefix:[source stringByAppendingString:@"/"]]) {
			return NO;
		}
	}
	return [self movePaths:paths toDirectory:directory error:error] != nil;
}

- (NSArray *)copyPaths:(NSArray *)paths toDirectory:(NSString *)directory error:(NSError **)error
{
	NSFileManager *manager = [NSFileManager defaultManager];
	NSMutableArray *destinations = [[NSMutableArray alloc] init];
	NSUInteger i;

	for (i = 0; i < [paths count]; i++) {
		NSString *source = [paths objectAtIndex:i];
		NSString *destination = [self destinationForSource:source directory:directory error:error];

		if (destination == nil) {
			continue;
		}
		if (![manager copyItemAtPath:source toPath:destination error:error]) {
			[destinations release];
			return nil;
		}
		[destinations addObject:destination];
		[self report:i + 1 total:[paths count] path:destination];
	}
	[self registerUndo:@"Copy" handler:^(id target) {
		NSUInteger j;

		for (j = 0; j < [destinations count]; j++) {
			(void)[[NSFileManager defaultManager] removeItemAtPath:[destinations objectAtIndex:j] error:NULL];
		}
		(void)target;
	}];
	return [destinations autorelease];
}

- (NSArray *)movePathsToTrash:(NSArray *)paths error:(NSError **)error
{
	NSArray *items = [_trash recyclePaths:paths error:error];

	if (items != nil) {
		NSUInteger i;

		for (i = 0; i < [paths count]; i++) {
			[self report:i + 1 total:[paths count] path:[paths objectAtIndex:i]];
		}
		[self registerUndo:@"Move to Trash" handler:^(id target) {
			(void)[(WSFileOperations *)target putBackTrashItems:items error:NULL];
		}];
	}
	return items;
}

- (BOOL)putBackTrashItems:(NSArray *)items error:(NSError **)error
{
	return [_trash putBackItems:items error:error];
}

- (BOOL)emptyTrash:(NSError **)error
{
	return [_trash emptyTrash:error];
}

/* **HOW MANY FILES ARE IN THERE, SO THE BAR HAS A DENOMINATOR.** A compress of ONE folder reported "1 of 1", which the
 * progress window does not even show — so the one operation a person most expects a bar for was the one with none. The
 * count is a walk of names and `lstat`s, which is the cheap half of the work. */
static unsigned long long fn_count_entries_at_path(NSString *path)
{
	struct stat st;
	unsigned long long total = 0;

	if (lstat([path fileSystemRepresentation], &st) != 0) {
		return 0;
	}
	if (!S_ISDIR(st.st_mode)) {
		return 1;		/* a file, or a symlink, which is one entry like a file */
	}
	{
		DIR *directory = opendir([path fileSystemRepresentation]);
		struct dirent *entry;

		if (directory == NULL) {
			return 0;
		}
		while ((entry = readdir(directory)) != NULL) {
			if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
				continue;
			}
			total += fn_count_entries_at_path([path stringByAppendingPathComponent:
				[NSString stringWithUTF8String:entry->d_name]]);
		}
		closedir(directory);
	}
	return total;
}

- (NSString *)compressPaths:(NSArray *)paths inDirectory:(NSString *)directory error:(NSError **)error
{
	NSString *baseName = @"Archive";
	NSString *archivePath;
	AGZipBuilder *builder;
	__block NSUInteger done = 0;
	NSUInteger total;
	NSUInteger i;

	if ([paths count] == 0) {
		if (error != NULL) *error = fn_error(20, @"there is nothing to compress");
		return nil;
	}
	if ([paths count] == 1) {
		baseName = [[paths objectAtIndex:0] lastPathComponent];
		if ([[baseName pathExtension] length] > 0) {
			baseName = [baseName stringByDeletingPathExtension];
		}
	}
	archivePath = [directory stringByAppendingPathComponent:
		fn_unique_name(directory, [baseName stringByAppendingPathExtension:@"zip"])];
	total = (NSUInteger)fn_count_entries_at_path([paths objectAtIndex:0]);
	for (i = 1; i < [paths count]; i++) {
		total += (NSUInteger)fn_count_entries_at_path([paths objectAtIndex:i]);
	}
	/* **THE ARCHIVE IS THE BUILDER'S FILE FROM THE FIRST BYTE**, so a failure anywhere below takes it away rather than
	 * leaving a stub: `-discard` is what every exit past this point goes through. */
	builder = [[AGZipBuilder alloc] initWithPath:archivePath progress:^(NSString *path) {
		done += 1;
		[self report:done total:total path:path];
	}];
	if (builder == nil) {
		if (error != NULL) *error = fn_error(30, @"the archive could not be written");
		return nil;
	}
	for (i = 0; i < [paths count]; i++) {
		NSString *path = [paths objectAtIndex:i];

		if (![builder addPath:path entryName:[path lastPathComponent] error:error]) {
			[builder discard];
			[builder release];
			return nil;
		}
	}
	if (![builder finishWithError:error]) {
		[builder discard];
		[builder release];
		return nil;
	}
	[builder release];
	[self registerUndo:@"Compress" handler:^(id target) {
		(void)[[NSFileManager defaultManager] removeItemAtPath:archivePath error:NULL];
		(void)target;
	}];
	return archivePath;
}


/* ---- EXTRACTION ------------------------------------------------------------------------------- */

+ (BOOL)cg_isArchivePath:(NSString *)path
{
	return (path != nil) && [[[path pathExtension] lowercaseString] isEqualToString:@"zip"];
}

/* **THE CENTRAL DIRECTORY, WHICH IS WHAT AN ARCHIVE SAYS IT CONTAINS.** Read whole — a directory is a few dozen bytes
 * an entry — and followed back through the ZIP64 locator when the plain end record carries its sentinels. */
- (nullable NSArray *)cg_directoryOfArchive:(FILE *)file size:(uint64_t)size error:(NSError **)error
{
	NSMutableArray *entries = [[NSMutableArray alloc] init];
	unsigned char *tail;
	size_t tailLength;
	uint64_t eocd = 0;
	BOOL found = NO;
	uint64_t count = 0;
	uint64_t cdOffset = 0;
	uint64_t cdSize = 0;
	unsigned char *directory = NULL;
	uint64_t at = 0;
	uint64_t i;

	tailLength = (size_t)((size < 66000) ? size : 66000);
	tail = malloc(tailLength);
	if (tail == NULL || fseek(file, (long)(size - tailLength), SEEK_SET) != 0) {
		free(tail);
		if (error != NULL) *error = fn_error(31, @"the archive could not be read");
		return nil;
	}
	if (fread(tail, 1, tailLength, file) != tailLength) {
		free(tail);
		if (error != NULL) *error = fn_error(31, @"the archive could not be read");
		return nil;
	}
	for (i = (uint64_t)tailLength; i >= 4; i--) {
		const unsigned char *p = tail + (i - 4);

		if (p[0] == 0x50 && p[1] == 0x4b && p[2] == 0x05 && p[3] == 0x06) {
			eocd = size - tailLength + (i - 4);
			found = YES;
			break;
		}
	}
	if (!found) {
		free(tail);
		if (error != NULL) *error = fn_error(31, @"this is not a zip archive");
		return nil;
	}
	count = fn_le16(tail + (eocd - (size - tailLength)) + 10);
	cdSize = fn_le32(tail + (eocd - (size - tailLength)) + 12);
	cdOffset = fn_le32(tail + (eocd - (size - tailLength)) + 16);
	free(tail);
	/* THE ZIP64 END OF CENTRAL DIRECTORY, WHOSE LOCATOR SITS IMMEDIATELY BEFORE THE END RECORD. */
	if (count == 0xffffu || cdSize == 0xffffffffu || cdOffset == 0xffffffffu) {
		unsigned char locator[20];

		if (eocd >= 20 && fseek(file, (long)(eocd - 20), SEEK_SET) == 0 &&
		    fread(locator, 1, sizeof locator, file) == sizeof locator &&
		    locator[0] == 0x50 && locator[1] == 0x4b && locator[2] == 0x06 && locator[3] == 0x07) {
			uint64_t recordAt = fn_le64(locator + 8);
			unsigned char record[56];

			if (fseek(file, (long)recordAt, SEEK_SET) == 0 &&
			    fread(record, 1, sizeof record, file) == sizeof record &&
			    record[0] == 0x50 && record[1] == 0x4b && record[2] == 0x06 && record[3] == 0x06) {
				count = fn_le64(record + 32);
				cdSize = fn_le64(record + 40);
				cdOffset = fn_le64(record + 48);
			}
		}
	}
	if (count == 0 || cdSize == 0 || cdOffset >= size || cdSize > size) {
		[entries release];
		if (error != NULL) *error = fn_error(31, @"the archive's directory is unreadable");
		return nil;
	}
	directory = malloc((size_t)cdSize);
	if (directory == NULL || fseek(file, (long)cdOffset, SEEK_SET) != 0 ||
	    fread(directory, 1, (size_t)cdSize, file) != (size_t)cdSize) {
		free(directory);
		[entries release];
		if (error != NULL) *error = fn_error(31, @"the archive's directory is unreadable");
		return nil;
	}
	for (i = 0; i < count && at + 46 <= cdSize; i++) {
		const unsigned char *p = directory + at;
		uint16_t nameLength;
		uint16_t extraLength;
		uint16_t commentLength;
		uint64_t uncompressed;
		uint64_t compressed;
		uint64_t localOffset;
		uint32_t external;
		NSString *name;

		if (p[0] != 0x50 || p[1] != 0x4b || p[2] != 0x01 || p[3] != 0x02) {
			break;
		}
		nameLength = fn_le16(p + 28);
		extraLength = fn_le16(p + 30);
		commentLength = fn_le16(p + 32);
		compressed = fn_le32(p + 20);
		uncompressed = fn_le32(p + 24);
		localOffset = fn_le32(p + 42);
		external = fn_le32(p + 38);
		if (at + 46 + nameLength + extraLength > cdSize) {
			break;
		}
		fn_zip64_values(p + 46 + nameLength, extraLength, &uncompressed, &compressed, &localOffset);
		name = [[NSString alloc] initWithBytes:p + 46 length:nameLength encoding:NSUTF8StringEncoding];
		if (name == nil) {
			[name release];
			at += 46 + nameLength + extraLength + commentLength;
			continue;
		}
		[entries addObject:[NSDictionary dictionaryWithObjectsAndKeys:
			name, @"name",
			[NSNumber numberWithUnsignedShort:fn_le16(p + 10)], @"method",
			[NSNumber numberWithUnsignedLongLong:compressed], @"csize",
			[NSNumber numberWithUnsignedLongLong:uncompressed], @"usize",
			[NSNumber numberWithUnsignedLongLong:localOffset], @"offset",
			[NSNumber numberWithUnsignedInt:fn_le32(p + 16)], @"crc",
			[NSNumber numberWithUnsignedShort:fn_le16(p + 12)], @"time",
			[NSNumber numberWithUnsignedShort:fn_le16(p + 14)], @"date",
			[NSNumber numberWithUnsignedInt:(external >> 16)], @"mode", nil]];
		[name release];
		at += 46 + nameLength + extraLength + commentLength;
	}
	free(directory);
	return [entries autorelease];
}

/* ONE ENTRY'S BYTES, STRAIGHT OR THROUGH zlib, INTO A FILE. The CRC is checked because a truncated or corrupt entry is
 * otherwise a file that looks fine until somebody opens it. */
- (BOOL)cg_writeEntry:(NSDictionary *)entry from:(FILE *)file toPath:(NSString *)path error:(NSError **)error
{
	unsigned char *in = NULL;
	unsigned char *out = NULL;
	uint16_t method = (uint16_t)[[entry objectForKey:@"method"] unsignedShortValue];
	uint64_t csize = [[entry objectForKey:@"csize"] unsignedLongLongValue];
	uint64_t localOffset = [[entry objectForKey:@"offset"] unsignedLongLongValue];
	uint32_t wantCrc = [[entry objectForKey:@"crc"] unsignedIntValue];
	uint32_t crc = (uint32_t)crc32(0L, Z_NULL, 0);
	unsigned char header[30];
	FILE *to = NULL;
	z_stream stream;
	BOOL deflateOpen = NO;
	uint64_t left = csize;
	BOOL ok = NO;

	memset(&stream, 0, sizeof stream);
	if (fseek(file, (long)localOffset, SEEK_SET) != 0 || fread(header, 1, sizeof header, file) != sizeof header) {
		if (error != NULL) *error = fn_error(32, @"an entry's header is unreadable");
		return NO;
	}
	if (fseek(file, (long)(fn_le16(header + 26) + fn_le16(header + 28)), SEEK_CUR) != 0) {
		if (error != NULL) *error = fn_error(32, @"an entry's header is unreadable");
		return NO;
	}
	in = malloc(AGUNZIP_CHUNK);
	out = malloc(AGUNZIP_CHUNK);
	to = fopen([path fileSystemRepresentation], "wb");
	if (in == NULL || out == NULL || to == NULL) {
		if (error != NULL) *error = fn_error(32, @"an entry could not be written");
		goto done;
	}
	if (method == 8) {
		if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) {
			if (error != NULL) *error = fn_error(33, @"zlib could not start");
			goto done;
		}
		deflateOpen = YES;
	}
	while (left > 0) {
		size_t got = (size_t)((left < AGUNZIP_CHUNK) ? left : AGUNZIP_CHUNK);

		if (fread(in, 1, got, file) != got) {
			if (error != NULL) *error = fn_error(32, @"an entry is truncated");
			goto done;
		}
		left -= got;
		if (!deflateOpen) {
			crc = (uint32_t)crc32(crc, in, (uInt)got);
			if (fwrite(in, 1, got, to) != got) {
				if (error != NULL) *error = fn_error(32, @"an entry could not be written");
				goto done;
			}
			continue;
		}
		stream.next_in = in;
		stream.avail_in = (uInt)got;
		for (;;) {
			size_t made;
			int zr;

			stream.next_out = out;
			stream.avail_out = AGUNZIP_CHUNK;
			zr = inflate(&stream, Z_NO_FLUSH);
			if (zr != Z_OK && zr != Z_STREAM_END) {
				if (error != NULL) *error = fn_error(33, @"an entry does not inflate");
				goto done;
			}
			made = AGUNZIP_CHUNK - stream.avail_out;
			crc = (uint32_t)crc32(crc, out, (uInt)made);
			if (made > 0 && fwrite(out, 1, made, to) != made) {
				if (error != NULL) *error = fn_error(32, @"an entry could not be written");
				goto done;
			}
			if (zr == Z_STREAM_END || stream.avail_in == 0) {
				break;
			}
		}
	}
	if (crc != wantCrc) {
		if (error != NULL) *error = fn_error(33, @"an entry's checksum does not match");
		goto done;
	}
	ok = YES;
done:
	if (deflateOpen) {
		inflateEnd(&stream);
	}
	if (to != NULL) {
		(void)fclose(to);
	}
	free(in);
	free(out);
	if (!ok) {
		(void)[[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
	}
	return ok;
}

- (nullable NSString *)extractArchive:(NSString *)path error:(NSError **)error
{
	NSFileManager *manager = [NSFileManager defaultManager];
	NSString *directory = [path stringByDeletingLastPathComponent];
	NSString *base = [[path lastPathComponent] stringByDeletingPathExtension];
	NSString *folder;
	NSArray *entries;
	FILE *file;
	uint64_t size;
	NSUInteger i;

	if (![[self class] cg_isArchivePath:path]) {
		if (error != NULL) *error = fn_error(34, @"that is not a zip archive");
		return nil;
	}
	file = fopen([path fileSystemRepresentation], "rb");
	if (file == NULL) {
		if (error != NULL) *error = fn_error(34, @"the archive could not be read");
		return nil;
	}
	if (fseek(file, 0, SEEK_END) != 0) {
		fclose(file);
		if (error != NULL) *error = fn_error(34, @"the archive could not be read");
		return nil;
	}
	size = (uint64_t)ftell(file);
	entries = [self cg_directoryOfArchive:file size:size error:error];
	if (entries == nil) {
		fclose(file);
		return nil;
	}
	/* **THE FOLDER IS NAMED FOR THE ARCHIVE AND SITS BESIDE IT**, and a second extraction of the same archive gets
	 * "Foo 2" rather than a merge into the first: what a person asked for twice is two folders. */
	folder = [directory stringByAppendingPathComponent:fn_unique_name(directory, base)];
	if (![manager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:error]) {
		fclose(file);
		return nil;
	}
	for (i = 0; i < [entries count]; i++) {
		NSDictionary *entry = [entries objectAtIndex:i];
		NSString *name = [entry objectForKey:@"name"];
		const char *utf8 = [name UTF8String];
		NSString *destination = nil;
		mode_t mode = (mode_t)[[entry objectForKey:@"mode"] unsignedIntValue];
		struct timespec stamp = { 0, 0 };
		BOOL isDirectory;

		if (!fn_entry_name_is_safe(utf8)) {
			if (error != NULL) {
				*error = fn_error(35, [NSString stringWithFormat:@"%@ tries to leave the folder", name]);
			}
			fclose(file);
			(void)[manager removeItemAtPath:folder error:NULL];
			return nil;
		}
		destination = [folder stringByAppendingPathComponent:name];
		isDirectory = (S_ISDIR(mode) || ([[entry objectForKey:@"csize"] unsignedLongLongValue] == 0 &&
						 [[entry objectForKey:@"usize"] unsignedLongLongValue] == 0 &&
						 [name hasSuffix:@"/"]));
		fn_dos_to_time((uint16_t)[[entry objectForKey:@"date"] unsignedShortValue],
			       (uint16_t)[[entry objectForKey:@"time"] unsignedShortValue], &stamp);
		if (isDirectory) {
			if (![manager createDirectoryAtPath:destination withIntermediateDirectories:YES
						 attributes:nil error:NULL] && error != NULL) {
				*error = fn_error(32, @"a folder could not be made");
				fclose(file);
				(void)[manager removeItemAtPath:folder error:NULL];
				return nil;
			}
		} else {
			NSString *parent = [destination stringByDeletingLastPathComponent];

			if (![manager createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:NULL]) {
				if (error != NULL) *error = fn_error(32, @"a folder could not be made");
				fclose(file);
				(void)[manager removeItemAtPath:folder error:NULL];
				return nil;
			}
			if (S_ISLNK(mode)) {
				/* A LINK IS WRITTEN BACK AS A LINK: its payload is the target path, and creating it needs the bytes in
				 * hand rather than a stream. */
				unsigned char *target = malloc((size_t)[[entry objectForKey:@"usize"] unsignedLongLongValue] + 1);
				uint64_t localOffset = [[entry objectForKey:@"offset"] unsignedLongLongValue];
				unsigned char header[30];
				BOOL made = NO;

				if (target != NULL && fseek(file, (long)localOffset, SEEK_SET) == 0 &&
				    fread(header, 1, sizeof header, file) == sizeof header &&
				    fseek(file, (long)(fn_le16(header + 26) + fn_le16(header + 28)), SEEK_CUR) == 0 &&
				    fread(target, 1, (size_t)[[entry objectForKey:@"usize"] unsignedLongLongValue], file) ==
					    (size_t)[[entry objectForKey:@"usize"] unsignedLongLongValue]) {
					target[[[entry objectForKey:@"usize"] unsignedLongLongValue]] = '\0';
					made = (symlink((const char *)target, [destination fileSystemRepresentation]) == 0);
				}
				free(target);
				if (!made) {
					if (error != NULL) *error = fn_error(32, @"a link could not be made");
					fclose(file);
					(void)[manager removeItemAtPath:folder error:NULL];
					return nil;
				}
			} else if (![self cg_writeEntry:entry from:file toPath:destination error:error]) {
				fclose(file);
				(void)[manager removeItemAtPath:folder error:NULL];
				return nil;
			}
			if ((mode & 07777) != 0) {
				(void)chmod([destination fileSystemRepresentation], mode & 07777);
			}
		}
		if (stamp.tv_sec != 0 && !S_ISLNK(mode)) {
			struct timespec times[2];

			times[0] = stamp;
			times[1] = stamp;
			(void)utimensat(AT_FDCWD, [destination fileSystemRepresentation], times, 0);
		}
		[self report:i + 1 total:[entries count] path:destination];
	}
	fclose(file);
	[self registerUndo:@"Extract Archive" handler:^(id target) {
		(void)[[NSFileManager defaultManager] removeItemAtPath:folder error:NULL];
		(void)target;
	}];
	return folder;
}
@end
