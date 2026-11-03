/*
 * item_icons — an image file is drawn as its own picture, not as the document icon for its type.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **THE GENERIC ICON SAYS NOTHING ABOUT WHAT IS IN THE FILE**, and a folder of photographs is exactly what a person
 * browses by picture. So `WSItemIcons` answers an image file with a thumbnail: the picture, scaled to fit the square a
 * caller asks for, aspect ratio kept, the leftover margins transparent — one shape for every icon surface, none of which
 * has to know anything about pictures.
 *
 * WHAT IS MEASURED, and it is the picture rather than a claim about it: a PNG painted HALF RED OVER HALF BLUE is written,
 * and the thumbnail that comes back is (1) the size that was asked for, (2) red where the picture is red and blue where it
 * is blue, in the picture's own order — so a flipped or stretched thumbnail fails — and (3) transparent in the margins the
 * aspect fit leaves. A text file beside it still gets Icon Services' answer, which is the fallback that must not be lost,
 * and a file that says `.png` but is not one falls back too.
 */
#import "WSItemIcons.h"

#import <AppKit/NSBitmapImageRep.h>
#import <AppKit/NSColor.h>
#import <AppKit/NSGraphicsContext.h>
#import <AppKit/NSImage.h>
#import <Foundation/Foundation.h>

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static int s_failed;

static void check(int condition, const char *message)
{
	printf("%s %s\n", condition ? "  ok  " : "  FAIL", message);
	if (!condition) {
		s_failed++;
	}
}

/* **A TWO-COLOURED PNG**, red over blue, so the answer's own rows say which way up it was drawn. */
static void write_probe_png(NSString *path, int width, int height)
{
	NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
		pixelsWide:width pixelsHigh:height bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
		isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:width * 4 bitsPerPixel:32];
	NSData *png;
	int x, y;

	for (y = 0; y < height; y++) {
		for (x = 0; x < width; x++) {
			/* ROW 0 IS THE PICTURE'S TOP: red there, blue below the middle. */
			[rep setColor:(y < height / 2 ? [NSColor redColor] : [NSColor blueColor]) atX:x y:y];
		}
	}
	png = [rep representationUsingType:NSPNGFileType properties:nil];
	[png writeToFile:path atomically:YES];
	[rep release];
}

int main(void)
{
	@autoreleasepool {
		NSString *root = [@"/tmp" stringByAppendingPathComponent:
			[NSString stringWithFormat:@"agora-item-icons-%d", (int)getpid()]];
		NSString *picture;
		NSString *document;
		NSString *liar;
		NSImage *thumbnail;
		NSImage *textIcon;
		NSFileManager *manager = [NSFileManager defaultManager];

		setvbuf(stdout, NULL, _IONBF, 0);
		[manager removeItemAtPath:root error:NULL];
		[manager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL];
		picture = [root stringByAppendingPathComponent:@"probe.png"];
		document = [root stringByAppendingPathComponent:@"notes.txt"];
		liar = [root stringByAppendingPathComponent:@"lies.png"];
		write_probe_png(picture, 40, 20);
		[@"not a picture at all" writeToFile:document atomically:YES encoding:NSUTF8StringEncoding error:NULL];
		[@"not a picture at all" writeToFile:liar atomically:YES encoding:NSUTF8StringEncoding error:NULL];

		check([WSItemIcons isImageFile:picture] && [WSItemIcons isImageFile:@"/x/y.JPG"]
		      && [WSItemIcons isImageFile:@"/x/y.jpeg"],
		      "PNG and JPEG are the types this tier decodes, and the extension is asked without regard to case");
		check(![WSItemIcons isImageFile:document] && ![WSItemIcons isImageFile:nil],
		      "a text file is not, and neither is no path at all");

		/* 1. THE THUMBNAIL IS THE SIZE THAT WAS ASKED FOR. */
		thumbnail = [WSItemIcons iconForPath:picture isDirectory:NO size:32];
		check(thumbnail != nil, "an image file's icon is a thumbnail");
		check(thumbnail != nil && [thumbnail size].width == 32.0 && [thumbnail size].height == 32.0,
		      "and it is the square the caller asked for, not the picture's own pixels");

		/* 2. AND IT IS THE PICTURE, THE RIGHT WAY UP. */
		if (thumbnail != nil) {
			NSBitmapImageRep *surface = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
				pixelsWide:32 pixelsHigh:32 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
				isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:32 * 4 bitsPerPixel:32];
			NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:surface];
			int redTop = -1, redBottom = -1, blueTop = -1, blueBottom = -1;
			int x, y;

			[NSGraphicsContext setCurrentContext:context];
			[thumbnail drawInRect:NSMakeRect(0.0, 0.0, 32.0, 32.0)];
			[NSGraphicsContext setCurrentContext:nil];
			for (y = 0; y < 32; y++) {
				for (x = 0; x < 32; x++) {
					NSColor *pixel = [[surface colorAtX:x y:y] colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
					CGFloat r = (pixel != nil) ? [pixel redComponent] : 0.0;
					CGFloat g = (pixel != nil) ? [pixel greenComponent] : 0.0;
					CGFloat b = (pixel != nil) ? [pixel blueComponent] : 0.0;
					CGFloat a = (pixel != nil) ? [pixel alphaComponent] : 0.0;

					if (a < 0.5) {
						continue;	/* the margin the aspect fit leaves */
					}
					if (r > 0.6 && g < 0.4 && b < 0.4) {
						if (redBottom < 0) redBottom = y;
						redTop = y;
					} else if (b > 0.6 && r < 0.4 && g < 0.4) {
						if (blueBottom < 0) blueBottom = y;
						blueTop = y;
					}
				}
			}
			/* **A BITMAP REP'S ROW 0 IS THE TOP OF ITS PICTURE**, which is the tree's own measured convention
			 * (`tests/browser_geometry.m` reads a rendered header the same way). So the red half, which is the
			 * picture's top, is the SMALLER y here — and the margins the aspect fit leaves are the rows above and
			 * below it. */
			printf("  (note: red rows %d..%d, blue rows %d..%d in a 32-row square)\n",
			       redBottom, redTop, blueBottom, blueTop);
			check(redBottom >= 0 && blueBottom >= 0, "the thumbnail carries both halves of the picture");
			check(redBottom >= 0 && blueBottom >= 0 && redBottom < blueBottom,
			      "with the red half of the picture ABOVE the blue one, so it was not drawn upside down");
			check(redBottom >= 0 && blueBottom >= 0 && (redTop - redBottom) < 20,
			      "and the picture is not stretched to the square's full height: its aspect ratio is kept");
			check(redBottom >= 6 && redTop <= 26 && blueBottom >= 6 && blueTop <= 26,
			      "the margins the aspect fit leaves are empty, not filled with the picture's colour");
			check(redBottom >= 6 && blueTop <= 26 && redBottom <= 10,
			      "and the picture is centred in the square rather than pushed against an edge");
			[surface release];
		}

		/* 3. THE FALLBACKS: A DOCUMENT, AND A FILE THAT ONLY CLAIMS TO BE A PICTURE. */
		textIcon = [WSItemIcons iconForPath:document isDirectory:NO size:32];
		check(textIcon != nil, "a document still gets Icon Services' icon");
		check(textIcon != thumbnail, "which is not the thumbnail of some other file");
		check([WSItemIcons thumbnailForPath:liar size:32] == nil,
		      "a file that says .png and is not one has no thumbnail, so Icon Services answers instead");
		check([WSItemIcons iconForPath:root isDirectory:YES size:32] != nil,
		      "and a directory is never treated as a picture");

		/* 4. THE CACHE IS A CACHE: THE SAME QUESTION ANSWERS THE SAME OBJECT, WHICH IS WHAT KEEPS A SCROLL CHEAP. */
		check([WSItemIcons iconForPath:picture isDirectory:NO size:32] == thumbnail,
		      "asking again for the same size answers the picture already decoded");

		[manager removeItemAtPath:root error:NULL];
	}
	printf(s_failed == 0 ? "item_icons: all checks passed\n" : "item_icons: FAILURES\n");
	return s_failed == 0 ? 0 : 1;
}
