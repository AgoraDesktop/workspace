/*
 * WSItemIcons.m — the Icon Services lookup, wrapped for AppKit.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#import "WSItemIcons.h"

#import <AppKit/NSImage.h>

#import <IconServices/IconServices.h>

#import <CoreFoundation/CFString.h>
#import <CoreFoundation/CFURL.h>

#include <stdlib.h>

@implementation WSItemIcons

+ (NSImage *)iconForPath:(NSString *)path isDirectory:(BOOL)isDirectory size:(NSInteger)size
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

@end
