/*
 * WSItemIcons.m — the Icon Services lookup, wrapped for AppKit.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#import "WSItemIcons.h"

#import <AppKit/NSBitmapImageRep.h>
#import <AppKit/NSGraphicsContext.h>
#import <AppKit/NSImage.h>

#import <IconServices/IconServices.h>

#import <CoreFoundation/CFString.h>
#import <CoreFoundation/CFURL.h>

#include <stdlib.h>

/* ============================================================================================
 * THE CACHES: ONE DECODE PER PICTURE, ONE DRAW PER SIZE.
 *
 * **A DECODE IS THE WHOLE COST AND IT MUST HAPPEN ONCE PER PICTURE.** MEASURED over 300 800x600 PNGs: 21.6 ms a picture
 * to decode and fit, and the same 21.8 ms again for the same pictures at another size, because the size was part of the
 * key — a folder looked at in two views was decoded twice over. So a picture is decoded ONCE into a working image
 * (`WS_THUMBNAIL_WORKING` points on its long side, or the requested size when that is larger) and every size is fitted
 * from it; the working copy is what the second view pays nothing for.
 *
 * **AND THE CACHE EVICTS ONE ENTRY, NOT ALL OF THEM.** It used to be emptied wholesale at its bound, which a folder of
 * more pictures than the bound then re-decoded on every scroll: MEASURED, five redraws of a twenty-row list over 300
 * pictures cost 2.17 s. Insertion-ordered eviction (the oldest key goes) keeps a working set warm whatever the folder
 * holds, and the bounds are a memory ceiling rather than a policy.
 * ============================================================================================ */
#define WS_THUMBNAIL_CACHE_LIMIT	2048	/* finished thumbnails: 16 points square is a kilobyte, 64 is sixteen */
#define WS_THUMBNAIL_WORKING		128	/* points: everything a 64-point preview needs, and a grid's 96 */
#define WS_WORKING_CACHE_LIMIT		512	/* 512 x 128 x 128 x 4 bytes is thirty-two megabytes */

static NSMutableDictionary *sThumbnails = nil;	/* path|size -> NSImage, the finished thumbnail */
static NSMutableArray *sThumbnailOrder = nil;	/* RETAINED keys, oldest first */
static NSMutableDictionary *sWorking = nil;	/* path|working size -> NSImage, the decoded picture */
static NSMutableArray *sWorkingOrder = nil;	/* RETAINED keys, oldest first */
static NSInteger sDecodes = 0;			/* how many pictures have been decoded: a probe's door */

/* INSERT WITH A CEILING: the oldest key leaves, and the newest stays. */
static void fn_cache_put(NSMutableDictionary *cache, NSMutableArray *order, NSInteger limit,
			 id value, NSString *key)
{
	if (cache == nil || order == nil || value == nil || key == nil) {
		return;
	}
	if ([cache objectForKey:key] != nil) {
		[cache setObject:value forKey:key];
		return;
	}
	while ((NSInteger)[order count] >= limit && [order count] > 0) {
		NSString *oldest = [order objectAtIndex:0];

		[cache removeObjectForKey:oldest];
		[order removeObjectAtIndex:0];
	}
	[cache setObject:value forKey:key];
	[order addObject:key];
}

/* THE PICTURE ITSELF, DECODED ONCE AND FITTED INTO ITS WORKING BOX. */
static NSImage *fn_working_image(NSString *path, NSInteger working)
{
	NSString *key;
	NSImage *cached;
	NSImage *source;
	NSSize natural;
	CGFloat scale;
	NSSize fitted;
	NSBitmapImageRep *rep;
	NSGraphicsContext *context;
	NSGraphicsContext *previous;
	NSImage *answer;

	if (sWorking == nil) {
		sWorking = [[NSMutableDictionary alloc] init];
		sWorkingOrder = [[NSMutableArray alloc] init];
	}
	key = [NSString stringWithFormat:@"%@|%ld", path, (long)working];
	cached = [sWorking objectForKey:key];
	if (cached != nil) {
		return cached;
	}
	source = [[NSImage alloc] initWithContentsOfFile:path];
	if (source == nil) {
		return nil;	/* not a picture this tier can read: Icon Services still has the type icon */
	}
	sDecodes++;
	natural = [source size];
	if (natural.width <= 0.0 || natural.height <= 0.0) {
		[source release];
		return nil;
	}
	/* **THE WORKING BOX ALWAYS DESCRIBES THE PICTURE'S SHAPE.** The picture is fitted into it whatever its own size —
	 * a smaller one is scaled up here rather than left as a speck in a large transparent box — because every later fit
	 * works from the BOX, and a box that only half-fills would shrink the picture a second time: MEASURED, a 40x20 PNG
	 * arrived as a 10x5 speck in a 32-point icon before this. */
	scale = (CGFloat)working / ((natural.width > natural.height) ? natural.width : natural.height);
	fitted = NSMakeSize(natural.width * scale, natural.height * scale);
	rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:working pixelsHigh:working
		bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
		colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:working * 4 bitsPerPixel:32];
	answer = nil;
	if (rep != nil) {
		context = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
		previous = [[NSGraphicsContext currentContext] retain];
		[NSGraphicsContext setCurrentContext:context];
		/* **A THUMBNAIL TAKES ONE TAP, NOT THE HALVING CHAIN.** `NSImageRep -drawInRect:` halves a picture repeatedly
		 * when it is reduced more than 2:1, which is right for icon-scale art and is what its own comment describes —
		 * MEASURED here, 800x600 into a 128-point box costs 15.8 ms that way and 1.2 ms with one bilinear tap, because
		 * this tier's sampler spends its time per DESTINATION pixel and the chain's intermediates are 400x300 and
		 * 200x150. A thumbnail is shown at a fraction of its own size anyway, so the chain buys nothing and a folder of
		 * photographs pays it three hundred times; the hint says which of the two this draw wants. */
		[source drawInRect:NSMakeRect(((CGFloat)working - fitted.width) / 2.0,
					      ((CGFloat)working - fitted.height) / 2.0,
					      fitted.width, fitted.height)
			  fromRect:NSZeroRect
			 operation:NSCompositingOperationSourceOver
			  fraction:1.0
		    respectFlipped:YES
			     hints:[NSDictionary dictionaryWithObject:
					[NSNumber numberWithInteger:NSImageInterpolationMedium]
							      forKey:NSImageHintInterpolation]];
		[NSGraphicsContext setCurrentContext:previous];
		[previous release];
		answer = [[NSImage alloc] initWithSize:NSMakeSize((CGFloat)working, (CGFloat)working)];
		[answer addRepresentation:rep];
		[rep release];
	}
	[source release];
	if (answer != nil) {
		fn_cache_put(sWorking, sWorkingOrder, WS_WORKING_CACHE_LIMIT, answer, key);
		[answer autorelease];
	}
	return answer;
}

@implementation WSItemIcons

+ (BOOL)isImageFile:(NSString *)path
{
	NSString *extension;

	if (path == nil) {
		return NO;
	}
	extension = [[path pathExtension] lowercaseString];
	return [extension isEqualToString:@"png"] || [extension isEqualToString:@"jpg"]
	       || [extension isEqualToString:@"jpeg"];
}

+ (NSInteger)cg_thumbnailDecodeCount
{
	return sDecodes;
}

+ (NSImage *)thumbnailForPath:(NSString *)path size:(NSInteger)size
{
	NSString *key;
	NSImage *cached;
	NSImage *working;
	NSInteger workingSize;
	NSSize natural;
	CGFloat scale;
	NSBitmapImageRep *rep;
	NSGraphicsContext *context;
	NSGraphicsContext *previous;
	NSImage *answer;

	if (path == nil || size <= 0 || ![self isImageFile:path]) {
		return nil;
	}
	key = [NSString stringWithFormat:@"%@|%ld", path, (long)size];
	if (sThumbnails == nil) {
		sThumbnails = [[NSMutableDictionary alloc] init];
		sThumbnailOrder = [[NSMutableArray alloc] init];
	}
	cached = [sThumbnails objectForKey:key];
	if (cached != nil) {
		return cached;
	}
	/* ONE WORKING COPY PER PICTURE: a 16-point row and a 64-point preview of the same file share the decode. */
	workingSize = (size > WS_THUMBNAIL_WORKING) ? size : WS_THUMBNAIL_WORKING;
	working = fn_working_image(path, workingSize);
	if (working == nil) {
		return nil;
	}
	if (size == workingSize) {
		fn_cache_put(sThumbnails, sThumbnailOrder, WS_THUMBNAIL_CACHE_LIMIT, working, key);
		return working;
	}
	natural = [working size];
	scale = (CGFloat)size / ((natural.width > natural.height) ? natural.width : natural.height);
	rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:size pixelsHigh:size
		bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
		colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:size * 4 bitsPerPixel:32];
	answer = nil;
	if (rep != nil) {
		context = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
		previous = [[NSGraphicsContext currentContext] retain];
		[NSGraphicsContext setCurrentContext:context];
		[working drawInRect:NSMakeRect(((CGFloat)size - natural.width * scale) / 2.0,
					      ((CGFloat)size - natural.height * scale) / 2.0,
					      natural.width * scale, natural.height * scale)];
		[NSGraphicsContext setCurrentContext:previous];
		[previous release];
		answer = [[NSImage alloc] initWithSize:NSMakeSize((CGFloat)size, (CGFloat)size)];
		[answer addRepresentation:rep];
		[rep release];
	}
	if (answer != nil) {
		fn_cache_put(sThumbnails, sThumbnailOrder, WS_THUMBNAIL_CACHE_LIMIT, answer, key);
		[answer autorelease];
	}
	return answer;
}

+ (NSImage *)iconForPath:(NSString *)path isDirectory:(BOOL)isDirectory size:(NSInteger)size
{
	NSImage *thumbnail;

	/* **AN IMAGE FILE IS ITS OWN PICTURE.** The generic document icon says nothing about what is inside the file, and a
	 * folder of photographs is exactly what a person browses by picture; a type this tier cannot decode falls through to
	 * Icon Services, which still knows what kind of document it is. */
	if (!isDirectory && [self isImageFile:path]) {
		thumbnail = [self thumbnailForPath:path size:size];

		if (thumbnail != nil) {
			return thumbnail;
		}
	}
	{
	CFStringRef string;
	CFURLRef url;
	IconRef icon;
	CGImageRef image;
	NSImage *answer;

	if (path == nil || size <= 0) {
		return nil;
	}
	string = CFStringCreateWithCString(NULL, [path UTF8String], kCFStringEncodingUTF8);
	if (string == NULL) {
		return nil;
	}
	url = CFURLCreateWithFileSystemPath(NULL, string, kCFURLPOSIXPathStyle,
					    isDirectory ? true : false);
	CFRelease(string);
	if (url == NULL) {
		return nil;
	}
	icon = AGIconCreateWithURL(url);
	CFRelease(url);
	if (icon == NULL) {
		return nil;
	}
	image = AGIconCopyImage(icon, CGSizeMake((CGFloat)size, (CGFloat)size));
	AGIconRelease(icon);
	if (image == NULL) {
		return nil;
	}
	answer = [[NSImage alloc] initWithCGImage:image size:NSMakeSize((CGFloat)size, (CGFloat)size)];
	CGImageRelease(image);
	return [answer autorelease];
	}
}

@end
