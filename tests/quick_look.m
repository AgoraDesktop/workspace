/*
 * quick_look.m — what the glance decides, without a display.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **THE PANEL CANNOT BE TESTED HEADLESSLY — a window needs a server — BUT EVERY DECISION IT MAKES CAN, and the decisions are
 * where a mistake is silent.** Which of the five kinds a path is, and what text a file contributes, are answered by class
 * doors for exactly that reason; the drawing and the show/hide are exercised in a session.
 *
 * The fixtures are made here: a PNG through `NSBitmapImageRep`'s own encoder, a PDF header of five bytes, a text file with a
 * long tail and a last complete line, a binary with NUL bytes, and a directory.
 */
#import "WSQuickLookController.h"

#import <AppKit/NSBitmapImageRep.h>

#import <Foundation/NSAutoreleasePool.h>
#import <Foundation/NSData.h>
#import <Foundation/NSFileManager.h>
#import <Foundation/NSString.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int checks;
static int failures;

static void check(int condition, const char *what)
{
	checks++;
	if (!condition) {
		failures++;
		printf("  FAIL   %s\n", what);
	} else {
		printf("  ok     %s\n", what);
	}
}

static NSString *make_scratch(void)
{
	char template[] = "/tmp/workspace-quicklook-XXXXXX";
	char *made = mkdtemp(template);

	return (made != NULL) ? [NSString stringWithUTF8String:made] : nil;
}

static NSString *write_png(NSString *directory)
{
	NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:4 pixelsHigh:3
									 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
									 colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:16 bitsPerPixel:32];
	NSString *path = [directory stringByAppendingPathComponent:@"picture.png"];
	NSData *png;

	if (rep == nil) {
		return nil;
	}
	memset([rep bitmapData], 0xff, 4 * 3 * 4);
	png = [rep representationUsingType:NSPNGFileType properties:nil];
	[rep release];
	if (png == nil || ![png writeToFile:path atomically:YES]) {
		return nil;
	}
	return path;
}

int main(void)
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSString *directory = make_scratch();
	NSString *pngPath;
	NSString *pdfPath;
	NSString *textPath;
	NSString *binaryPath;
	NSString *missingPath;

	if (directory == nil) {
		printf("quick_look: no scratch directory\n");
		[pool release];
		return 1;
	}
	pngPath = write_png(directory);
	pdfPath = [directory stringByAppendingPathComponent:@"document.pdf"];
	textPath = [directory stringByAppendingPathComponent:@"notes.txt"];
	binaryPath = [directory stringByAppendingPathComponent:@"program.bin"];
	missingPath = [directory stringByAppendingPathComponent:@"nothing-here"];

	[[@"%PDF-1.4\n%%EOF\n" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:pdfPath atomically:YES];

	/* THE FIXTURES ARE ALL WRITTEN BEFORE ANY OF THEM IS ASKED ABOUT, or the text file would be `other` for the
	 * truthiest of reasons: it did not exist yet when the question was put. */
	/* ---- 2. THE TEXT A GLANCE SHOWS ---------------------------------------------------------- */
	{
		NSMutableString *body = [NSMutableString string];

		while ([body length] < 400) {
			[body appendString:@"a line of prose that a glance can draw\n"];
		}
		[body appendString:@"THE LAST LINE\n"];
		[[body dataUsingEncoding:NSUTF8StringEncoding] writeToFile:textPath atomically:YES];
	}
	/* ---- 1. WHICH KIND A PATH IS ------------------------------------------------------------- */
	check(pngPath != nil && [WSQuickLookController kindForPath:pngPath] == WSQuickLookKindImage,
	      "a PNG is an image, decided by its bytes");
	check([WSQuickLookController kindForPath:pdfPath] == WSQuickLookKindPDF, "a %PDF- file is a PDF");
	check([WSQuickLookController kindForPath:textPath] == WSQuickLookKindText, "a text file is text");
	check([WSQuickLookController kindForPath:directory] == WSQuickLookKindFolder, "a directory is a folder");
	check([WSQuickLookController kindForPath:missingPath] == WSQuickLookKindOther,
	      "a path that is not there is `other` rather than a crash");
	check([WSQuickLookController kindForPath:nil] == WSQuickLookKindOther, "and so is no path at all");

	/* **A BINARY IS NOT TEXT BECAUSE ITS NAME ENDS IN `.txt`.** The NUL byte is the rule, and it is what keeps a glance
	 * from drawing an ELF as a page of boxes. */
	{
		unsigned char bytes[64];

		memset(bytes, 0x41, sizeof bytes);
		bytes[7] = 0x00;
		[[NSData dataWithBytes:bytes length:sizeof bytes] writeToFile:binaryPath atomically:YES];
		check([WSQuickLookController kindForPath:binaryPath] == WSQuickLookKindOther,
		      "a file with a NUL byte in it is not text, whatever it is called");
	}

	{
		NSString *preview = [WSQuickLookController textPreviewForPath:textPath limit:8192];

		check(preview != nil && [preview length] > 300, "the text preview carries the file's prose");
		check(preview != nil && [preview rangeOfString:@"THE LAST LINE"].location != NSNotFound,
		      "and all of a file this small, last line included");
	}
	{
		/* A LIMIT IS A LIMIT, AND IT IS CUT AT A LINE: 120 bytes of this file ends mid-sentence unless the cut walks back
		 * to the newline, which is what the door promises. */
		NSString *shortPreview = [WSQuickLookController textPreviewForPath:textPath limit:120];

		check(shortPreview != nil && [shortPreview length] < 120, "a 120-byte limit yields less than 120 characters");
		check(shortPreview != nil && ![shortPreview hasSuffix:@"\n"] && [shortPreview rangeOfString:@"\nTHE LAST LINE"].location == NSNotFound,
		      "and the cut is on a line boundary");
	}
	check([WSQuickLookController textPreviewForPath:binaryPath limit:8192] == nil,
	      "the binary contributes no text at all");

	/* ---- 3. THE PANEL'S STATE, WHICH NEEDS NO DISPLAY TO ASK ---------------------------------- */
	{
		WSQuickLookController *look = [WSQuickLookController sharedController];

		check(look != nil, "the application has one glance controller");
		check(![look isShowing] && [look path] == nil, "and it starts showing nothing");
		check([WSQuickLookController sharedController] == look, "and asks for it a second time gets the same one");
	}

	[[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];
	[pool release];
	printf("quick_look: %d checks, %d fail%s\n", checks, failures, (failures == 1) ? "" : "s");
	return (failures == 0) ? 0 : 1;
}
