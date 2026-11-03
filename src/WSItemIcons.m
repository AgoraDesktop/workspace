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

/* **A THUMBNAIL COSTS A DECODE, SO ONE IS KEPT.** The icon views ask for every row they draw, and a four-megabyte JPEG
 * decoded per draw is a still window; the cache is keyed by path and size and dropped whole when it grows past a bound,
 * which is enough for a folder that is being scrolled and honest about being a cache rather than a model. */
static NSMutableDictionary *sThumbnails = nil;
#define WS_THUMBNAIL_CACHE_LIMIT 256

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

+ (NSImage *)thumbnailForPath:(NSString *)path size:(NSInteger)size
{
	NSString *key;
	NSImage *cached;
	NSImage *source;
	NSSize natural;
	NSBitmapImageRep *rep;
	NSGraphicsContext *context;
	NSGraphicsContext *previous;
	NSImage *answer;
	CGFloat scale;
	NSSize fitted;

	if (path == nil || size <= 0 || ![self isImageFile:path]) {
		return nil;
	}
	key = [NSString stringWithFormat:@"%@|%ld", path, (long)size];
	cached = [sThumbnails objectForKey:key];
	if (cached != nil) {
		return cached;
	}
	source = [[NSImage alloc] initWithContentsOfFile:path];
	if (source == nil) {
		return nil;	/* not a picture this tier can read: Icon Services still has the type icon */
	}
	natural = [source size];
	if (natural.width <= 0.0 || natural.height <= 0.0) {
		[source release];
		return nil;
	}
	scale = (CGFloat)size / ((natural.width > natural.height) ? natural.width : natural.height);
	if (scale > 1.0) {
		scale = 1.0;	/* a small picture is not blown up into a blocky one */
	}
	fitted = NSMakeSize(natural.width * scale, natural.height * scale);
	rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:size pixelsHigh:size
		bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
		colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:size * 4 bitsPerPixel:32];
	answer = nil;
	if (rep != nil) {
		context = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
		previous = [[NSGraphicsContext currentContext] retain];
		/* THE BOX IS THE WHOLE SQUARE, so a caller's square icon rect holds the picture and its margins and nothing has
		 * to know the picture's shape. The picture is centred; the box is transparent, which is what an icon surface
		 * draws over its own background. */
		[NSGraphicsContext setCurrentContext:context];
		[source drawInRect:NSMakeRect(((CGFloat)size - fitted.width) / 2.0,
					      ((CGFloat)size - fitted.height) / 2.0,
					      fitted.width, fitted.height)];
		[NSGraphicsContext setCurrentContext:previous];
		[previous release];
		answer = [[NSImage alloc] initWithSize:NSMakeSize((CGFloat)size, (CGFloat)size)];
		[answer addRepresentation:rep];
		[rep release];
	}
	[source release];
	if (answer != nil) {
		if (sThumbnails == nil) {
			sThumbnails = [[NSMutableDictionary alloc] init];
		}
		if ([sThumbnails count] >= WS_THUMBNAIL_CACHE_LIMIT) {
			[sThumbnails removeAllObjects];
		}
		[sThumbnails setObject:answer forKey:key];
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
