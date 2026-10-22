/*
 * WSItemKind.m — Launch Services' Kind string for one item.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Portions of this file may derive from GNUstep; see THIRD-PARTY.md.
 */
#import "WSItemKind.h"

#import "WSItemModel.h"

#import <Foundation/NSString.h>

#import <LaunchServices/LSInfo.h>

#import <CoreFoundation/CFString.h>
#import <CoreFoundation/CFURL.h>

@implementation WSItemKind

+ (NSString *)kindForItem:(WSItem *)item
{
	CFStringRef path;
	CFURLRef url;
	CFStringRef kind;
	NSString *answer = nil;

	if ([item isDirectory]) {
		return @"Folder";
	}
	path = CFStringCreateWithCString(NULL, [[item path] UTF8String], kCFStringEncodingUTF8);
	if (path != NULL) {
		url = CFURLCreateWithFileSystemPath(NULL, path, kCFURLPOSIXPathStyle, false);
		CFRelease(path);
		if (url != NULL) {
			kind = LSCopyKindStringForURL(url);
			CFRelease(url);
			if (kind != NULL) {
				answer = [(NSString *)kind copy];
				CFRelease(kind);
				/* **A UTI IS NOT A KIND STRING.** For an extension no Agora bundle declares, Launch Services answers
				 * its dynamic `dyn.…` identifier (or a `public.…` one); showing that in the Kind column would be
				 * an internal name in a person's window. A UTI-shaped answer — a dot and no space — falls through
				 * to the extension fallback below, and the declared descriptions ("Plain Text", "Folder") do not. */
				if ([answer length] == 0
				    || ([answer rangeOfString:@"."].location != NSNotFound
					&& [answer rangeOfString:@" "].location == NSNotFound)) {
					[answer release];
					answer = nil;
				}
			}
		}
	}
	if (answer == nil) {
		NSString *extension = [[item path] pathExtension];

		answer = ([extension length] > 0) ? [[extension uppercaseString] copy] : [@"Document" copy];
	}
	return [answer autorelease];
}

@end
