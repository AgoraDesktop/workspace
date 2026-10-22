/*
 * WSPrintService.m — a listing per file, printed, with the launch's reply.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Portions of this file may derive from GNUstep; see THIRD-PARTY.md.
 *
 * **ONE TICKET PER FILE, COPIED FROM THE SHARED ONE.** A print request that set the paper size on the shared ticket would
 * change every later print in the application; the copy is the same rule `NSDocument -printInfo` follows, one level up.
 */
#import "WSPrintService.h"

#import "WSPrintView.h"

#import <AppKit/NSPrintInfo.h>
#import <AppKit/NSPrintOperation.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSString.h>

@implementation WSPrintService

+ (NSApplicationPrintReply)printFiles:(NSArray *)paths
			     settings:(NSDictionary *)settings
		      showPrintPanels:(BOOL)showPrintPanels
{
	BOOL printed = NO;
	BOOL cancelled = NO;
	NSUInteger i;

	for (i = 0; i < [paths count]; i++) {
		NSString *path = [paths objectAtIndex:i];
		WSPrintView *view = [WSPrintView printViewForPaths:[NSArray arrayWithObject:path] title:nil];
		NSPrintInfo *ticket = [[[NSPrintInfo alloc] initWithDictionary:
			[[NSPrintInfo sharedPrintInfo] dictionary]] autorelease];
		NSPrintOperation *operation;
		BOOL ok;

		if (settings != nil) {
			[[ticket dictionary] addEntriesFromDictionary:settings];
		}
		operation = [NSPrintOperation printOperationWithView:view printInfo:ticket];
		[operation setJobTitle:[path lastPathComponent]];
		[operation setShowsPrintPanel:showPrintPanels];
		ok = [operation runOperation];
		if (ok) {
			printed = YES;
		} else if ([[ticket jobDisposition] isEqual:NSPrintCancelJob]) {
			cancelled = YES;
		}
	}
	if (cancelled) {
		return NSPrintingCancelled;
	}
	return printed ? NSPrintingSuccess : NSPrintingFailure;
}

@end
