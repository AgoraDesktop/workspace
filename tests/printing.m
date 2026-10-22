/*
 * printing — what a file manager can print, and the two doors into it.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Portions of this file may derive from GNUstep; see THIRD-PARTY.md.
 *
 * **A FILE MANAGER PRINTS A LISTING, SO THE LISTING IS WHAT IS MEASURED.** The view's rows are its paths in order, its
 * height is the rows' arithmetic, and the pages are what the AppKit's paginator makes of that height. No printer is
 * touched: every job here is a PREVIEW or a SAVE, and the one check that runs the launch's door uses a ticket that
 * previews — a probe that printed paper would be a probe nobody could run twice.
 *
 * WHAT IS MEASURED:
 *
 *   1. THE ROWS. One per path, in the order given; the kind comes from the same registry the list view uses (a folder
 *      is "Folder"), the size is the file's, and a title falls back to the first path's name.
 *   2. THE PAGES. A listing's height is `title + rows × row height + padding`, and a ticket's imageable height cuts it:
 *      three rows are one page, a hundred are three.
 *   3. THE INK. Page one of a listing is not blank — the title and the rows are drawn.
 *   4. THE SERVICE. A preview request succeeds, a save request writes the PDF it was asked for, and a cancel request
 *      reports `NSPrintingCancelled` rather than success.
 *   5. THE TWO DOORS. The application's delegate door and the window's `-printSelection:` both reach the service: the
 *      second is measured through NSApplication (a recording delegate), which is what makes the menu row the launch
 *      door's first real caller rather than a second printing path.
 */
#import "WSPrintService.h"
#import "WSPrintView.h"
#import "WSFileWindowController.h"
#import "WSApplication.h"

#import <AppKit/NSPrintInfo.h>
#import <AppKit/NSPrintOperation.h>
#import <AppKit/NSPDFImageRep.h>
#import <AppKit/NSBitmapImageRep.h>
#import <AppKit/NSGraphicsContext.h>
#import <AppKit/NSBezierPath.h>
#import <AppKit/NSColor.h>
#import <AppKit/NSApplication.h>
#import <AppKit/NSView.h>
#import <Foundation/Foundation.h>

#include <math.h>
#include <stdio.h>
#include <string.h>

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
	return [[NSFileManager defaultManager] createFileAtPath:path
						       contents:[NSMutableData dataWithLength:bytes]
						     attributes:nil];
}

/* THE PDF'S PAGE COUNT, through the same reader a viewer uses. */
static NSInteger pageCountOfData(NSData *data)
{
	NSPDFImageRep *rep = [[NSPDFImageRep alloc] initWithData:data];
	NSInteger pages = (rep != nil) ? [rep pageCount] : -1;

	[rep release];
	return pages;
}

/* **DARK PIXELS ON PAGE ONE**, drawn through the PDF rep into a bitmap. Two points per unit of a page, so the title's
 * glyphs are more than a pixel tall. */
static int inkOnFirstPage(NSData *data)
{
	NSPDFImageRep *rep = [[NSPDFImageRep alloc] initWithData:data];
	NSBitmapImageRep *canvas;
	NSSize size;
	NSInteger x, y, ink = 0;

	if (rep == nil) {
		return 0;
	}
	size = [rep size];
	canvas = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
							 pixelsWide:(NSInteger)size.width
							 pixelsHigh:(NSInteger)size.height
							 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
							 colorSpaceName:NSCalibratedRGBColorSpace
							    bytesPerRow:(NSInteger)size.width * 4 bitsPerPixel:32];
	[NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:canvas]];
	[[NSColor whiteColor] setFill];
	[[NSBezierPath bezierPathWithRect:NSMakeRect(0.0, 0.0, size.width, size.height)] fill];
	[rep drawInRect:NSMakeRect(0.0, 0.0, size.width, size.height)];
	for (y = 0; y < (NSInteger)size.height; y++) {
		for (x = 0; x < (NSInteger)size.width; x++) {
			NSColor *pixel = [canvas colorAtX:x y:y];

			if (pixel != nil && [pixel redComponent] < 0.5 && [pixel greenComponent] < 0.5
			    && [pixel blueComponent] < 0.5) {
				ink++;
			}
		}
	}
	[canvas release];
	[rep release];
	return ink;
}

/* A RECORDING DELEGATE, so the window's verb can be driven through NSApplication WITHOUT printing anything. */
@interface WSPrintRecordingDelegate : NSObject
{
@public
	NSArray *lastPaths;
	NSInteger calls;
}
@end

@implementation WSPrintRecordingDelegate
- (void)dealloc { [lastPaths release]; [super dealloc]; }
- (NSApplicationPrintReply)application:(NSApplication *)application printFiles:(NSArray *)fileNames
			  withSettings:(NSDictionary *)printSettings showPrintPanels:(BOOL)showPrintPanels
{
	(void)application; (void)printSettings; (void)showPrintPanels;
	calls++;
	[lastPaths release];
	lastPaths = [fileNames copy];
	return NSPrintingSuccess;
}
@end

/* ============================================================================================ *
 * THE ROWS AND THE PAGES.                                                                       *
 * ============================================================================================ */

static void test_listing(NSString *root)
{
	NSArray *paths = [NSArray arrayWithObjects:
		[root stringByAppendingPathComponent:@"alpha.txt"],
		[root stringByAppendingPathComponent:@"beta.txt"],
		[root stringByAppendingPathComponent:@"sub"], nil];
	WSPrintView *view = [WSPrintView printViewForPaths:paths title:@"A Listing"];
	NSArray *rows = [view cg_rows];
	NSPrintInfo *info;
	NSPrintOperation *operation;
	NSPDFImageRep *rep;

	printf("the listing\n");
	check([[view cg_title] isEqual:@"A Listing"], "the title is the one asked for");
	check([rows count] == 3, "one row per path");
	check(fabs([view cg_requiredHeight] - (WS_PRINT_TITLE_HEIGHT + 3.0 * WS_PRINT_ROW_HEIGHT
					       + WS_PRINT_BOTTOM_PADDING)) < 0.01,
	      "and the height is the rows' arithmetic");
	check([[view cg_nameAtRow:0] isEqual:@"alpha.txt"], "a row carries its file's name");
	check([[view cg_kindAtRow:2] isEqual:@"Folder"], "a directory's kind is Folder");
	check([[view cg_sizeAtRow:0] isEqual:@"2.0 KB"], "a 2048-byte file's size is 2.0 KB");
	check([[view cg_kindAtRow:0] length] > 0, "and every row names a kind");
	check([view cg_nameAtRow:99] == nil, "a row past the end answers nil");

	/* A DEFAULT TITLE FALLS BACK TO THE FIRST PATH. */
	{
		WSPrintView *untitled = [WSPrintView printViewForPaths:paths title:nil];

		check([[untitled cg_title] isEqual:@"alpha.txt"], "an untitled listing names its first item");
	}

	/* AND THREE ROWS ARE ONE PAGE OF AN A4 SHEET. */
	info = [[NSPrintInfo alloc] init];
	[info setJobDisposition:NSPrintPreviewJob];
	operation = [NSPrintOperation printOperationWithView:view printInfo:info];
	[operation setShowsPrintPanel:NO];
	check([operation runOperation], "the listing prints");
	check(pageCountOfData([operation cg_resultData]) == 1, "three rows are one page");
	check(inkOnFirstPage([operation cg_resultData]) > 0, "and page one is not blank");
	[info release];

	/* A HUNDRED ROWS ARE THREE PAGES: 56 + 1800 + 24 = 1880 points at 698 per page. */
	{
		NSMutableArray *many = [NSMutableArray array];
		NSPrintInfo *ticket = [[NSPrintInfo alloc] init];
		NSPrintOperation *longOperation;
		NSInteger i;

		for (i = 0; i < 100; i++) {
			[many addObject:[root stringByAppendingPathComponent:[NSString stringWithFormat:@"f%03d.txt", (int)i]]];
		}
		[ticket setJobDisposition:NSPrintPreviewJob];
		longOperation = [NSPrintOperation printOperationWithView:[WSPrintView printViewForPaths:many title:@"Many"]
							       printInfo:ticket];
		[longOperation setShowsPrintPanel:NO];
		check([longOperation runOperation], "a hundred-row listing prints");
		rep = [[NSPDFImageRep alloc] initWithData:[longOperation cg_resultData]];
		check(rep != nil && [rep pageCount] == 3, "and it is three pages");
		[rep release];
		[ticket release];
	}
}

/* ============================================================================================ *
 * THE SERVICE AND THE TWO DOORS.                                                                *
 * ============================================================================================ */

static void test_service(NSString *root)
{
	NSArray *paths = [NSArray arrayWithObjects:
		[root stringByAppendingPathComponent:@"alpha.txt"], nil];
	NSString *saved = @"/tmp/workspace-print-probe.pdf";
	NSDictionary *preview = [NSDictionary dictionaryWithObject:NSPrintPreviewJob forKey:NSPrintJobDisposition];
	NSDictionary *cancel = [NSDictionary dictionaryWithObject:NSPrintCancelJob forKey:NSPrintJobDisposition];
	NSDictionary *save = [NSDictionary dictionaryWithObjectsAndKeys:
		NSPrintSaveJob, NSPrintJobDisposition, saved, NSPrintSavePath, nil];
	WSApplication *application = [[WSApplication alloc] init];

	printf("the service and the doors\n");
	check([WSPrintService printFiles:paths settings:preview showPrintPanels:NO] == NSPrintingSuccess,
	      "a preview request succeeds");
	check([[NSFileManager defaultManager] fileExistsAtPath:saved] == NO, "and writes no file");
	check([WSPrintService printFiles:paths settings:save showPrintPanels:NO] == NSPrintingSuccess,
	      "a save request succeeds");
	check([[NSFileManager defaultManager] fileExistsAtPath:saved], "and writes the file it was given");
	check(pageCountOfData([NSData dataWithContentsOfFile:saved]) == 1, "which is one page of listing");
	[[NSFileManager defaultManager] removeItemAtPath:saved error:NULL];
	check([WSPrintService printFiles:paths settings:cancel showPrintPanels:NO] == NSPrintingCancelled,
	      "a cancelled request reports a cancel, not a success");
	check([WSPrintService printFiles:[NSArray array] settings:preview showPrintPanels:NO] == NSPrintingFailure,
	      "an empty request reports failure, because nothing printed");

	/* THE APPLICATION'S DELEGATE DOOR IS THE LAUNCH'S, AND IT REACHES THE SAME SERVICE. */
	check([application application:[NSApplication sharedApplication] printFiles:paths
			  withSettings:preview showPrintPanels:NO] == NSPrintingSuccess,
	      "the application's print-files door prints a file");
	[application release];

	/* AND THE WINDOW'S VERB ARRIVES THROUGH `-application:printFiles:` — measured with a delegate that records. */
	{
		WSFileWindowController *controller = [[WSFileWindowController alloc] initWithDirectory:root];
		WSPrintRecordingDelegate *recorder = [[WSPrintRecordingDelegate alloc] init];
		NSApplication *app = [NSApplication sharedApplication];

		check([[controller printablePaths] count] == 3, "an unselected window prints the folder's items");
		[app setDelegate:(id)recorder];
		[controller printSelection:nil];
		check(recorder->calls == 1 && [recorder->lastPaths count] == 3,
		      "and the verb hands those paths to the launch's print request");
		[app setDelegate:nil];
		[recorder release];
		[controller close];
		[controller release];
	}
}

int main(void)
{
	NSString *root = @"/tmp/workspace-print-probe";

	printf("printing — the listing a file manager can print\n");
	[[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
	makeDirectory(root);
	makeFile([root stringByAppendingPathComponent:@"alpha.txt"], 2048);
	makeFile([root stringByAppendingPathComponent:@"beta.txt"], 10);
	makeDirectory([root stringByAppendingPathComponent:@"sub"]);

	test_listing(root);
	test_service(root);

	[[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
	printf("\nworkspace printing: %d check(s) failed\n", s_failed);
	return s_failed == 0 ? 0 : 1;
}
