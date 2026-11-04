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
#define AGZIP_MADE_BY		((3u << 8) | 20u)	/* 3 = unix, and version 2.0 */

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

/* THE HEADER, WITH THE THREE NUMBERS IT DOES NOT KNOW YET LEFT AT ZERO. */
- (BOOL)beginEntry:(NSString *)entryName method:(uint16_t)method time:(uint16_t)dosTime date:(uint16_t)dosDate
      headerAt:(unsigned long long *)headerOffset
{
	const char *name = [entryName fileSystemRepresentation];
	size_t nameLength = strlen(name);
	AGBytes header;

	if (nameLength == 0 || nameLength > 0xffffu) {
		return NO;
	}
	header.length = 0;
	fn_bytes32(&header, 0x04034b50u);
	fn_bytes16(&header, 20);
	fn_bytes16(&header, 0x0800u);	/* names are UTF-8 */
	fn_bytes16(&header, method);
	fn_bytes16(&header, dosTime);
	fn_bytes16(&header, dosDate);
	fn_bytes32(&header, 0);		/* crc, patched */
	fn_bytes32(&header, 0);		/* compressed size, patched */
	fn_bytes32(&header, 0);		/* uncompressed size, patched */
	fn_bytes16(&header, (uint16_t)nameLength);
	fn_bytes16(&header, 0);		/* extra */
	if (headerOffset != NULL) {
		*headerOffset = _offset;
	}
	return [self writeBytes:header.bytes length:header.length] && [self writeBytes:name length:nameLength];
}

- (BOOL)patchHeaderAt:(unsigned long long)headerOffset crc:(uint32_t)crc compressed:(uint64_t)compressed
	 uncompressed:(uint64_t)uncompressed
{
	unsigned char patch[12];
	unsigned long long end = _offset;
	unsigned long i;

	for (i = 0; i < 4; i++) {
		patch[i] = (unsigned char)((crc >> (8 * i)) & 0xff);
		patch[4 + i] = (unsigned char)((compressed >> (8 * i)) & 0xff);
		patch[8 + i] = (unsigned char)((uncompressed >> (8 * i)) & 0xff);
	}
	if (fseek(_file, (long)(headerOffset + 14), SEEK_SET) != 0) {
		return NO;
	}
	if (fwrite(patch, 1, sizeof patch, _file) != sizeof patch) {
		return NO;
	}
	return fseek(_file, (long)end, SEEK_SET) == 0;
}

- (void)recordEntry:(NSString *)entryName crc:(uint32_t)crc compressed:(uint64_t)compressed
	 uncompressed:(uint64_t)uncompressed method:(uint16_t)method offset:(unsigned long long)offset
	       time:(uint16_t)dosTime date:(uint16_t)dosDate mode:(mode_t)mode
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
		[NSNumber numberWithUnsignedInt:(unsigned int)mode], @"mode", nil]];
}

/* **THE PAYLOAD, STRAIGHT THROUGH OR THROUGH ZLIB, A BLOCK AT A TIME.** The CRC and both sizes come out of the same
 * pass, which is the whole point: nothing here holds more than `AGZIP_CHUNK` bytes of the file. */
- (BOOL)addFile:(NSString *)path entryName:(NSString *)entryName stat:(const struct stat *)st error:(NSError **)error
{
	FILE *in;
	unsigned char *buffer = NULL;
	size_t sample;
	uint16_t method = 0;
	unsigned long long headerOffset = 0;
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
	if (![self beginEntry:entryName method:method time:dosTime date:dosDate headerAt:&headerOffset]) {
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
			if (total > 0xffffffffULL) {
				if (error != NULL) *error = fn_error(10, @"the archive is too large for a ZIP without ZIP64");
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
		if (written > 0xffffffffULL) {
			if (error != NULL) *error = fn_error(10, @"the archive is too large for a ZIP without ZIP64");
			goto done;
		}
	}
	if (![self patchHeaderAt:headerOffset crc:crc compressed:written uncompressed:total]) {
		if (error != NULL) *error = fn_error(12, @"the archive could not be written");
		goto done;
	}
	[self recordEntry:entryName crc:crc compressed:written uncompressed:total method:method offset:headerOffset
		     time:dosTime date:dosDate mode:st->st_mode];
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
	if (![self beginEntry:name method:0 time:dosTime date:dosDate headerAt:&headerOffset]) {
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
	if (![self patchHeaderAt:headerOffset crc:crc compressed:length uncompressed:length]) {
		if (error != NULL) *error = fn_error(12, @"the archive could not be written");
		return NO;
	}
	[self recordEntry:name crc:crc compressed:length uncompressed:length method:0 offset:headerOffset
		     time:dosTime date:dosDate mode:st->st_mode];
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
	NSUInteger i;

	if ([_entries count] > 0xffffu) {
		if (error != NULL) *error = fn_error(13, @"too many entries for a ZIP without ZIP64");
		return NO;
	}
	for (i = 0; i < [_entries count]; i++) {
		NSDictionary *record = [_entries objectAtIndex:i];
		NSString *name = [record objectForKey:@"name"];
		const char *bytes = [name fileSystemRepresentation];
		size_t length = strlen(bytes);
		uint64_t compressed = [[record objectForKey:@"csize"] unsignedLongLongValue];
		uint64_t uncompressed = [[record objectForKey:@"usize"] unsignedLongLongValue];
		mode_t mode = (mode_t)[[record objectForKey:@"mode"] unsignedIntValue];
		uint32_t attributes = (uint32_t)(mode << 16);
		AGBytes header;

		if (S_ISDIR(mode)) {
			attributes |= AGZIP_DOS_DIRECTORY;
		}
		header.length = 0;
		fn_bytes32(&header, 0x02014b50u);
		fn_bytes16(&header, (uint16_t)AGZIP_MADE_BY);
		fn_bytes16(&header, 20);
		fn_bytes16(&header, 0x0800u);
		fn_bytes16(&header, (uint16_t)[[record objectForKey:@"method"] unsignedShortValue]);
		fn_bytes16(&header, (uint16_t)[[record objectForKey:@"time"] unsignedShortValue]);
		fn_bytes16(&header, (uint16_t)[[record objectForKey:@"date"] unsignedShortValue]);
		fn_bytes32(&header, [[record objectForKey:@"crc"] unsignedIntValue]);
		fn_bytes32(&header, (uint32_t)compressed);
		fn_bytes32(&header, (uint32_t)uncompressed);
		fn_bytes16(&header, (uint16_t)length);
		fn_bytes16(&header, 0);		/* extra */
		fn_bytes16(&header, 0);		/* comment */
		fn_bytes16(&header, 0);		/* disk */
		fn_bytes16(&header, 0);		/* internal attributes */
		fn_bytes32(&header, attributes);
		fn_bytes32(&header, (uint32_t)[[record objectForKey:@"offset"] unsignedLongLongValue]);
		if (![self writeBytes:header.bytes length:header.length] || ![self writeBytes:bytes length:length]) {
			if (error != NULL) *error = fn_error(12, @"the archive could not be written");
			return NO;
		}
	}
	{
		AGBytes end;
		uint32_t centralSize = (uint32_t)(_offset - centralOffset);

		end.length = 0;
		fn_bytes32(&end, 0x06054b50u);
		fn_bytes16(&end, 0);
		fn_bytes16(&end, 0);
		fn_bytes16(&end, (uint16_t)[_entries count]);
		fn_bytes16(&end, (uint16_t)[_entries count]);
		fn_bytes32(&end, centralSize);
		fn_bytes32(&end, (uint32_t)centralOffset);
		fn_bytes16(&end, 0);
		if (![self writeBytes:end.bytes length:end.length]) {
			if (error != NULL) *error = fn_error(12, @"the archive could not be written");
			return NO;
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

/* ---- THE OPERATIONS -------------------------------------------------------------------------- */

@implementation WSFileOperations

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

@end
