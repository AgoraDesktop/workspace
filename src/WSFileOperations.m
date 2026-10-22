/*
 * WSFileOperations.m — the operations, their conflicts, their progress and their undo.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Portions of this file may derive from GNUstep; see THIRD-PARTY.md.
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

/* ---- a ZIP writer: store or raw-deflate, central directory, EOCD ------------------------------- */

static void fn_put16(NSMutableData *data, uint16_t value)
{
	unsigned char bytes[2] = { (unsigned char)(value & 0xff), (unsigned char)((value >> 8) & 0xff) };

	[data appendBytes:bytes length:2];
}

static void fn_put32(NSMutableData *data, uint32_t value)
{
	unsigned char bytes[4] = { (unsigned char)(value & 0xff), (unsigned char)((value >> 8) & 0xff),
				   (unsigned char)((value >> 16) & 0xff), (unsigned char)((value >> 24) & 0xff) };

	[data appendBytes:bytes length:4];
}

@interface AGZipBuilder : NSObject
{
	NSMutableData *_data;		/* RETAINED: local headers and file data */
	NSMutableArray *_entries;	/* RETAINED: NSDictionary per central record */
	uint16_t _dosTime;
	uint16_t _dosDate;
}
- (instancetype)initWithTime:(time_t)now;
- (BOOL)addPath:(NSString *)path entryName:(NSString *)entryName error:(NSError **)error;
- (nullable NSData *)finishWithError:(NSError **)error;
@end

@implementation AGZipBuilder

- (instancetype)initWithTime:(time_t)now
{
	struct tm broken;

	self = [super init];
	if (self != nil) {
		_data = [[NSMutableData alloc] init];
		_entries = [[NSMutableArray alloc] init];
		if (localtime_r(&now, &broken) != NULL) {
			_dosTime = (uint16_t)((broken.tm_hour << 11) | (broken.tm_min << 5) | (broken.tm_sec / 2));
			_dosDate = (uint16_t)(((broken.tm_year - 80) << 9) | ((broken.tm_mon + 1) << 5) | broken.tm_mday);
		}
	}
	return self;
}

- (void)dealloc
{
	[_data release];
	[_entries release];
	[super dealloc];
}

- (BOOL)appendFileData:(NSData *)contents entryName:(NSString *)entryName isDirectory:(BOOL)isDirectory
		 error:(NSError **)error
{
	const unsigned char *name = (const unsigned char *)[entryName UTF8String];
	NSUInteger nameLength = strlen((const char *)name);
	NSData *payload = contents;
	uint16_t method = 0;
	uint32_t crc = 0;
	uint32_t compressedSize;
	uint32_t uncompressedSize;
	uint32_t offset;
	NSDictionary *record;

	if (nameLength > 0xffffu || [contents length] > 0xffffffffu || [_data length] > 0xffffffffu) {
		if (error != NULL) *error = fn_error(10, @"the archive is too large for a ZIP without ZIP64");
		return NO;
	}
	if (!isDirectory) {
		uLong crcValue = crc32(0L, Z_NULL, 0);

		crcValue = crc32(crcValue, [contents bytes], (uInt)[contents length]);
		crc = (uint32_t)crcValue;
		uncompressedSize = (uint32_t)[contents length];
		compressedSize = uncompressedSize;
		if ([contents length] > 0) {
			z_stream stream;
			unsigned char *buffer;
			uLong bound;
			int zr;

			memset(&stream, 0, sizeof stream);
			if (deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8,
					 Z_DEFAULT_STRATEGY) != Z_OK) {
				if (error != NULL) *error = fn_error(11, @"zlib could not start");
				return NO;
			}
			bound = deflateBound(&stream, (uLong)[contents length]);
			buffer = malloc((size_t)bound);
			stream.next_in = (Bytef *)[contents bytes];
			stream.avail_in = (uInt)[contents length];
			stream.next_out = buffer;
			stream.avail_out = (uInt)bound;
			zr = deflate(&stream, Z_FINISH);
			if (zr == Z_STREAM_END) {
				uint32_t size = (uint32_t)stream.total_out;

				if (size < uncompressedSize) {
					payload = [NSData dataWithBytes:buffer length:size];
					method = 8;
					compressedSize = size;
				}
			}
			deflateEnd(&stream);
			free(buffer);
		}
	} else {
		uncompressedSize = 0;
		compressedSize = 0;
	}
	offset = (uint32_t)[_data length];
	/* LOCAL HEADER */
	fn_put32(_data, 0x04034b50u);
	fn_put16(_data, 20);
	fn_put16(_data, 0x0800u);	/* names are UTF-8 */
	fn_put16(_data, method);
	fn_put16(_data, _dosTime);
	fn_put16(_data, _dosDate);
	fn_put32(_data, crc);
	fn_put32(_data, compressedSize);
	fn_put32(_data, uncompressedSize);
	fn_put16(_data, (uint16_t)nameLength);
	fn_put16(_data, 0);
	[_data appendBytes:name length:nameLength];
	if (compressedSize > 0) {
		[_data appendData:payload];
	}
	record = [NSDictionary dictionaryWithObjectsAndKeys:
		entryName, @"name",
		[NSNumber numberWithUnsignedInt:crc], @"crc",
		[NSNumber numberWithUnsignedInt:compressedSize], @"csize",
		[NSNumber numberWithUnsignedInt:uncompressedSize], @"usize",
		[NSNumber numberWithUnsignedShort:method], @"method",
		[NSNumber numberWithUnsignedInt:offset], @"offset",
		[NSNumber numberWithUnsignedShort:_dosTime], @"time",
		[NSNumber numberWithUnsignedShort:_dosDate], @"date", nil];
	[_entries addObject:record];
	return YES;
}

- (BOOL)addPath:(NSString *)path entryName:(NSString *)entryName error:(NSError **)error
{
	NSFileManager *manager = [NSFileManager defaultManager];
	BOOL isDirectory = NO;

	if (![manager fileExistsAtPath:path isDirectory:&isDirectory]) {
		if (error != NULL) *error = fn_error(12, [NSString stringWithFormat:@"%@ is not there", path]);
		return NO;
	}
	if (isDirectory) {
		NSArray *children;
		NSString *directoryName = [entryName hasSuffix:@"/"] ? entryName
			: [entryName stringByAppendingString:@"/"];
		NSUInteger i;

		if (![self appendFileData:[NSData data] entryName:directoryName isDirectory:YES error:error]) {
			return NO;
		}
		children = [manager contentsOfDirectoryAtPath:path error:error];
		if (children == nil) {
			return NO;
		}
		for (i = 0; i < [children count]; i++) {
			NSString *child = [children objectAtIndex:i];
			NSString *childPath = [path stringByAppendingPathComponent:child];

			if (![self addPath:childPath entryName:[directoryName stringByAppendingString:child]
				     error:error]) {
				return NO;
			}
		}
		return YES;
	}
	return [self appendFileData:[manager contentsAtPath:path] entryName:entryName
			isDirectory:NO error:error];
}

- (NSData *)finishWithError:(NSError **)error
{
	uint32_t centralOffset = (uint32_t)[_data length];
	NSUInteger i;

	if ([_entries count] > 0xffffu) {
		if (error != NULL) *error = fn_error(13, @"too many entries for a ZIP without ZIP64");
		return nil;
	}
	for (i = 0; i < [_entries count]; i++) {
		NSDictionary *record = [_entries objectAtIndex:i];
		NSString *name = [record objectForKey:@"name"];
		const unsigned char *bytes = (const unsigned char *)[name UTF8String];
		NSUInteger length = strlen((const char *)bytes);

		fn_put32(_data, 0x02014b50u);
		fn_put16(_data, 20);
		fn_put16(_data, 20);
		fn_put16(_data, 0x0800u);
		fn_put16(_data, (uint16_t)[[record objectForKey:@"method"] unsignedShortValue]);
		fn_put16(_data, (uint16_t)[[record objectForKey:@"time"] unsignedShortValue]);
		fn_put16(_data, (uint16_t)[[record objectForKey:@"date"] unsignedShortValue]);
		fn_put32(_data, [[record objectForKey:@"crc"] unsignedIntValue]);
		fn_put32(_data, [[record objectForKey:@"csize"] unsignedIntValue]);
		fn_put32(_data, [[record objectForKey:@"usize"] unsignedIntValue]);
		fn_put16(_data, (uint16_t)length);
		fn_put16(_data, 0);	/* extra */
		fn_put16(_data, 0);	/* comment */
		fn_put16(_data, 0);	/* disk */
		fn_put16(_data, 0);	/* internal attributes */
		fn_put32(_data, 0);	/* external attributes */
		fn_put32(_data, [[record objectForKey:@"offset"] unsignedIntValue]);
		[_data appendBytes:bytes length:length];
	}
	{
		uint32_t centralSize = (uint32_t)[_data length] - centralOffset;

		fn_put32(_data, 0x06054b50u);
		fn_put16(_data, 0);
		fn_put16(_data, 0);
		fn_put16(_data, (uint16_t)[_entries count]);
		fn_put16(_data, (uint16_t)[_entries count]);
		fn_put32(_data, centralSize);
		fn_put32(_data, centralOffset);
		fn_put16(_data, 0);
	}
	return _data;
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

- (NSString *)compressPaths:(NSArray *)paths inDirectory:(NSString *)directory error:(NSError **)error
{
	AGZipBuilder *builder = [[AGZipBuilder alloc] initWithTime:time(NULL)];
	NSData *archive;
	NSString *baseName = @"Archive";
	NSString *archivePath;
	NSUInteger i;

	if ([paths count] == 1) {
		baseName = [[paths objectAtIndex:0] lastPathComponent];
		if ([[baseName pathExtension] length] > 0) {
			baseName = [baseName stringByDeletingPathExtension];
		}
	}
	archivePath = [directory stringByAppendingPathComponent:
		fn_unique_name(directory, [baseName stringByAppendingPathExtension:@"zip"])];
	for (i = 0; i < [paths count]; i++) {
		NSString *path = [paths objectAtIndex:i];
		NSString *entryName = [path lastPathComponent];

		if (![builder addPath:path entryName:entryName error:error]) {
			[builder release];
			return nil;
		}
		[self report:i + 1 total:[paths count] path:path];
	}
	/* THE BUILDER OWNS ITS BYTES; RETAIN THEM ACROSS ITS RELEASE BEFORE WRITING. */
	archive = [[builder finishWithError:error] retain];
	[builder release];
	if (archive == nil || ![archive writeToFile:archivePath atomically:YES]) {
		if (error != NULL) *error = fn_error(30, @"the archive could not be written");
		[archive release];
		return nil;
	}
	[archive release];
	[self registerUndo:@"Compress" handler:^(id target) {
		(void)[[NSFileManager defaultManager] removeItemAtPath:archivePath error:NULL];
		(void)target;
	}];
	return archivePath;
}

@end
