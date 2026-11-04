/*
 * icon_view — W3's icon view: the grid, the keyboard, rename, and the drop policies.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **THE THREE HALVES ARE ASKED SEPARATELY.** The GRID is `WSIconLayout`'s left-to-right row order; the KEYBOARD and
 * TYPE-SELECT are `WSIconView`'s own state; the RENAME is a field over the label and an `NSFileManager` move; and the
 * DROP is the pasteboard's paths plus the policy arithmetic (same volume -> Move, across -> Copy, Command+Option ->
 * Link) and the file operation each policy performs. Offscreen, with a temporary tree on `/tmp` and a second on
 * `/dev/shm` so "across a volume" is a fact rather than a claim.
 */
#import "WSIconLabel.h"
#import "WSIconCell.h"
#import "WSIconLayout.h"
#import "WSDesktopView.h"
#import "WSIconView.h"
#import "WSItemModel.h"
#import "WSFileOperations.h"
#import "WSSelectionBand.h"
#import "WSTrash.h"

#import <AppKit/NSApplication.h>
#import <AppKit/NSBitmapImageRep.h>
#import <AppKit/NSBezierPath.h>
#import <AppKit/NSColor.h>
#import <AppKit/NSGraphicsContext.h>
#import <AppKit/NSDragging.h>
#import <AppKit/NSEvent.h>
#import <AppKit/NSMenu.h>
#import <AppKit/NSMenuItem.h>
#import <AppKit/NSPasteboard.h>
#import <AppKit/NSStringDrawing.h>
#import <AppKit/NSText.h>
#import <AppKit/NSTextField.h>
#import <AppKit/NSWindow.h>
#import <Foundation/Foundation.h>

#include <CoreGraphics/CGContext.h>

#include <math.h>
#include <stdio.h>
#include <unistd.h>

static int s_failed;

static void check(int ok, const char *name)
{
	printf("  %s   %s\n", ok ? "ok  " : "FAIL", name);
	if (!ok) {
		s_failed++;
	}
}

/* **INK IS A PIXEL FAR FROM THE BACKGROUND THE SURFACE PAINTS.** A threshold on brightness alone measures a black name
 * on white and a white name on a wallpaper at different rows, because the antialiased first row of ink is dark ink over
 * one surface and bright ink over the other. */
static int ink_at(NSColor *colour, NSColor *background)
{
	if (colour == nil) {
		return 0;
	}
	return fabs([colour redComponent] - [background redComponent]) > 0.5
		|| fabs([colour greenComponent] - [background greenComponent]) > 0.5
		|| fabs([colour blueComponent] - [background blueComponent]) > 0.5;
}

static int near(double a, double b)
{
	return a > b - 0.01 && a < b + 0.01;
}

static BOOL makeDirectory(NSString *path)
{
	return [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES
								  attributes:nil error:NULL];
}

/* **A PICTURE OF A KNOWN SIZE**, which is all this probe needs: the icon path decodes it, and a decode is what the
 * wait is for. */
static BOOL writePNG(NSString *path, int width, int height)
{
	NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:width pixelsHigh:height
		bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
		colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:width * 4 bitsPerPixel:32];
	NSData *png;
	BOOL ok;
	int x, y;

	for (y = 0; y < height; y++) {
		for (x = 0; x < width; x++) {
			[rep setColor:[NSColor colorWithCalibratedRed:(CGFloat)x / width green:(CGFloat)y / height
								blue:0.5 alpha:1.0] atX:x y:y];
		}
	}
	png = [rep representationUsingType:NSPNGFileType properties:nil];
	ok = (png != nil) && [png writeToFile:path atomically:YES];
	[rep release];
	return ok;
}

static BOOL makeFile(NSString *path)
{
	return [[NSFileManager defaultManager] createFileAtPath:path contents:[NSData data] attributes:nil];
}

static NSEvent *key(unichar character, NSUInteger flags)
{
	NSString *string = [NSString stringWithCharacters:&character length:1];

	return [NSEvent keyEventWithType:NSKeyDown location:NSZeroPoint modifierFlags:flags
			       timestamp:0.0 windowNumber:0 context:nil
				characters:string charactersIgnoringModifiers:string
				isARepeat:NO keyCode:0];
}

/* **A VIEW PAINTED INTO A BITMAP, so the band's two colours are measured rather than asserted.** The white underlay
 * matters: the band is SEMITRANSPARENT, so what it looks like is the accent over whatever is beneath — and a probe that
 * drew it over black would be measuring a different colour. */
static NSBitmapImageRep *new_rep(int width, int height)
{
	return [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:width pixelsHigh:height
		bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
		colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:width * 4 bitsPerPixel:32];
}

static NSBitmapImageRep *draw_view_over(NSView *view, int width, int height, NSColor *background)
{
	NSBitmapImageRep *rep = new_rep(width, height);

	NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
	CGContextRef cg;

	[NSGraphicsContext setCurrentContext:context];
	/* **A FLIPPED VIEW IS ENTERED MIRRORED, WHICH IS HOW APPKIT DRAWS IT.** `-displayRect:`'s child branch mirrors a view
	 * whose direction differs from its parent's, and a flipped view drawn into an unmirrored rep is a picture no surface
	 * ever shows — every row upside down, and a line of text placed from the wrong edge of its box. */
	cg = (CGContextRef)[context graphicsPort];
	if ([view isFlipped]) {
		CGContextTranslateCTM(cg, 0.0, (CGFloat)height);
		CGContextScaleCTM(cg, 1.0, -1.0);
	}
	[background setFill];
	[[NSBezierPath bezierPathWithRect:NSMakeRect(0.0, 0.0, (CGFloat)width, (CGFloat)height)] fill];
	[view drawRect:[view bounds]];
	return rep;
}

static NSBitmapImageRep *draw_view(NSView *view, int width, int height)
{
	return draw_view_over(view, width, height, [NSColor whiteColor]);
}

/* **WHERE THE SELECTION'S WASH IS, in a rep.** The wash is the accent at 35% over white, so the pixels it tints have one
 * exact colour; the icon drawn on top of it does not, which is what leaves the wash visible around the icon and gives the
 * rectangle its bounds. */
static NSRect wash_bounds(NSBitmapImageRep *rep, int width, int height)
{
	int x, y;
	int minX = width, minY = height, maxX = -1, maxY = -1;
	/* The wash is a fill with an alpha, so what a rep shows is it composited over the white the view painted first. */
	NSColor *wash = WSIconCellSelectionColor();
	CGFloat alpha = [wash alphaComponent];
	CGFloat wantR = alpha * [wash redComponent] + (1.0 - alpha);
	CGFloat wantG = alpha * [wash greenComponent] + (1.0 - alpha);
	CGFloat wantB = alpha * [wash blueComponent] + (1.0 - alpha);

	for (y = 0; y < height; y++) {
		for (x = 0; x < width; x++) {
			NSColor *c = [rep colorAtX:x y:y];

			if (c == nil || fabs([c redComponent] - wantR) > 0.02 || fabs([c greenComponent] - wantG) > 0.02
			    || fabs([c blueComponent] - wantB) > 0.02) {
				continue;
			}
			if (x < minX) minX = x;
			if (y < minY) minY = y;
			if (x > maxX) maxX = x;
			if (y > maxY) maxY = y;
		}
	}
	if (maxX < 0) {
		return NSZeroRect;
	}
	return NSMakeRect((CGFloat)minX, (CGFloat)minY, (CGFloat)(maxX - minX + 1), (CGFloat)(maxY - minY + 1));
}

static NSEvent *mouse(NSEventType type, NSPoint point)
{
	return [NSEvent mouseEventWithType:type location:point modifierFlags:0
				 timestamp:0.0 windowNumber:0 context:nil
				 eventNumber:0 clickCount:1 pressure:1.0f];
}

static NSEvent *mouseWithFlags(NSEventType type, NSPoint point, NSUInteger flags)
{
	return [NSEvent mouseEventWithType:type location:point modifierFlags:flags
				 timestamp:0.0 windowNumber:0 context:nil
				 eventNumber:0 clickCount:1 pressure:1.0f];
}

static NSInteger indexNamed(WSIconView *view, NSString *name)
{
	NSArray *items = [[view model] items];
	NSUInteger i;

	for (i = 0; i < [items count]; i++) {
		if ([[[items objectAtIndex:i] name] isEqual:name]) {
			return (NSInteger)i;
		}
	}
	return -1;
}

/* THE UNION OF THE VIEW'S INVALIDATED RECTANGLES: the window's private seam, declared here as the other probes do. */
@interface NSView (AGIconDamageProbe)
- (NSRect)cg_dirtyUnion;
@end

@interface WSIconView (AGIconBandProbe)
- (NSRect)cg_bandRect;
@end

/* The desktop's own probe doors, declared as its test declares them. */
@interface WSDesktopView (AGIconSelectionProbe)
- (NSArray *)cg_selection;
- (NSArray *)cg_positions;
- (NSRect)cg_highlightRectAtIndex:(NSInteger)index;
@end

@interface NSApplication (APPKITIconProbe)
- (void)cg_addWindow:(NSWindow *)window;
- (void)cg_removeWindow:(NSWindow *)window;
@end

static NSPoint centerOfIndex(WSIconView *view, NSInteger index)
{
	NSArray *positions = [view cg_positions];
	NSPoint position = [[positions objectAtIndex:(NSUInteger)index] pointValue];

	return NSMakePoint(position.x + 32.0, position.y + 32.0);
}

/* ---- A DRAGGING INFO WITHOUT A SESSION ------------------------------------------------------- */

@interface AGDropInfo : NSObject <NSDraggingInfo>
{
	NSPasteboard *_pasteboard;	/* RETAINED */
	NSPoint _location;
	NSDragOperation _mask;
	id _source;			/* NOT RETAINED */
}
- (instancetype)initWithPaths:(NSArray *)paths location:(NSPoint)location mask:(NSDragOperation)mask;
@end

@implementation AGDropInfo
- (instancetype)initWithPaths:(NSArray *)paths location:(NSPoint)location mask:(NSDragOperation)mask
{
	self = [super init];
	if (self != nil) {
		_pasteboard = [[NSPasteboard pasteboardWithUniqueName] retain];
		[_pasteboard declareTypes:[NSArray arrayWithObject:NSFilenamesPboardType] owner:nil];
		[_pasteboard setPropertyList:paths forType:NSFilenamesPboardType];
		_location = location;
		_mask = mask;
	}
	return self;
}
- (void)dealloc
{
	[_pasteboard release];
	[super dealloc];
}
- (NSWindow *)draggingDestinationWindow { return nil; }
- (NSDragOperation)draggingSourceOperationMask { return _mask; }
- (NSPoint)draggingLocation { return _location; }
- (NSPoint)draggedImageLocation { return NSZeroPoint; }
- (NSImage *)draggedImage { return nil; }
- (NSPasteboard *)draggingPasteboard { return _pasteboard; }
- (id)draggingSource { return _source; }
- (NSInteger)draggingSequenceNumber { return 1; }
- (void)slideDraggedImageTo:(NSPoint)screenPoint { (void)screenPoint; }
- (NSArray *)namesOfPromisedFilesDroppedAtDestination:(NSURL *)dropDestination
{
	(void)dropDestination;
	return nil;
}
- (void)setSource:(id)source { _source = source; }
@end

/* ---- A DELEGATE THAT RECORDS OPENS ---------------------------------------------------------- */

@interface AGIconProbe : NSObject <WSIconViewDelegate>
{
@public
	NSString *opened;
	int changes;
	int finishes;
}
@end

@implementation AGIconProbe
- (void)iconView:(WSIconView *)view openItem:(WSItem *)item
{
	(void)view;
	[opened release];
	opened = [[item name] copy];
}
- (void)iconViewDidChangeModel:(WSIconView *)view
{
	(void)view;
	changes++;
}
- (void)iconViewDidFinishOperation:(WSIconView *)view
{
	(void)view;
	finishes++;
}
- (void)dealloc
{
	[opened release];
	[super dealloc];
}
@end

/* ---- A SPRING OBSERVER ---------------------------------------------------------------------- */

@interface AGSpringProbe : NSObject
{
@public
	NSString *path;
	int requests;
}
@end

@implementation AGSpringProbe
- (void)requested:(NSNotification *)notification
{
	requests++;
	[path release];
	path = [[[notification userInfo] objectForKey:WSIconViewFolderPathKey] copy];
}
- (void)dealloc
{
	[path release];
	[super dealloc];
}
@end

int main(void)
{
	NSApplication *application = [NSApplication sharedApplication];
	NSString *root = [@"/tmp" stringByAppendingPathComponent:
		[NSString stringWithFormat:@"agora-icon-view-%d", (int)getpid()]];
	NSString *sourceRoot = [@"/tmp" stringByAppendingPathComponent:
		[NSString stringWithFormat:@"agora-icon-source-%d", (int)getpid()]];
	NSString *otherRoot = [@"/dev/shm" stringByAppendingPathComponent:
		[NSString stringWithFormat:@"agora-icon-other-%d", (int)getpid()]];
	NSString *target = [root stringByAppendingPathComponent:@"Target"];
	NSString *otherTarget = [otherRoot stringByAppendingPathComponent:@"Dest"];
	WSItemModel *model;
	WSIconView *view;
	NSWindow *window;
	AGIconProbe *probe;
	AGSpringProbe *spring;

	setvbuf(stdout, NULL, _IONBF, 0);
	[application finishLaunching];
	[[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
	[[NSFileManager defaultManager] removeItemAtPath:sourceRoot error:NULL];
	[[NSFileManager defaultManager] removeItemAtPath:otherRoot error:NULL];
	check(makeDirectory(root), "the probe made the temporary tree");
	makeDirectory(target);
	makeDirectory(sourceRoot);
	makeFile([sourceRoot stringByAppendingPathComponent:@"move.txt"]);
	makeFile([sourceRoot stringByAppendingPathComponent:@"copy.txt"]);
	makeFile([sourceRoot stringByAppendingPathComponent:@"link.txt"]);
	makeFile([sourceRoot stringByAppendingPathComponent:@"into-folder.txt"]);
	makeDirectory(otherRoot);
	makeDirectory(otherTarget);
	makeDirectory([root stringByAppendingPathComponent:@"Archive"]);
	makeDirectory([root stringByAppendingPathComponent:@"Documents"]);
	makeFile([root stringByAppendingPathComponent:@"delta.txt"]);
	makeFile([root stringByAppendingPathComponent:@"notes.txt"]);

	model = [[WSItemModel alloc] initWithDirectory:root];
	view = [[WSIconView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 400.0, 400.0) model:model];
	window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0.0, 0.0, 400.0, 400.0)
					     styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
	[window setContentView:view];
	probe = [[AGIconProbe alloc] init];
	[view setDelegate:probe];

	/* 0. THE LABEL IS CUT TO THE CELL, NOT TO ITS OWN MEASURED WIDTH. */
	{
		NSDictionary *attributes = [NSDictionary dictionary];
		NSString *shortName = WSIconLabelText(@"notes.txt", 76.0, attributes);
		NSString *longName = WSIconLabelText(@"64 Ultimax Banked Cartridge Template", 76.0, attributes);

		check([shortName isEqual:@"notes.txt"], "a short name is unchanged");
		check([longName length] < [@"64 Ultimax Banked Cartridge Template" length]
		      && [longName rangeOfString:@"…"].location != NSNotFound,
		      "a long name is cut in the middle with an ellipsis");
		check([longName sizeWithAttributes:attributes].width <= 76.01,
		      "and the cut label fits the cell it is drawn in");
	}

	/* **A DRAW THAT IS ABOUT TO DECODE A PILE OF PICTURES SAYS "WORKING" FIRST.** A folder of photographs costs a decode
	 * per cell the first time it is shown — seconds of it — and a pointer that stays an arrow through that reads as a
	 * hung window. The shape is the compositor's, so what is measured here is the REQUEST: the view's count of draws
	 * that put the busy pointer up. A grid of documents must not ask for one, because nothing is being decoded. */
	{
		NSString *pictures = [root stringByAppendingPathComponent:@"Pictures"];
		NSString *papers = [root stringByAppendingPathComponent:@"Papers"];
		WSItemModel *pictureModel;
		WSItemModel *paperModel;
		WSIconView *pictureView;
		WSIconView *paperView;
		NSWindow *pictureWindow;
		NSWindow *paperWindow;
		int k;

		[[NSFileManager defaultManager] createDirectoryAtPath:pictures withIntermediateDirectories:YES
								   attributes:nil error:NULL];
		[[NSFileManager defaultManager] createDirectoryAtPath:papers withIntermediateDirectories:YES
								   attributes:nil error:NULL];
		for (k = 0; k < 6; k++) {
			writePNG([pictures stringByAppendingPathComponent:
				[NSString stringWithFormat:@"p%d.png", k]], 24, 16);
			makeFile([papers stringByAppendingPathComponent:
				[NSString stringWithFormat:@"d%d.txt", k]]);
		}
		pictureModel = [[WSItemModel alloc] initWithDirectory:pictures];
		paperModel = [[WSItemModel alloc] initWithDirectory:papers];
		pictureView = [[WSIconView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 480.0, 320.0) model:pictureModel];
		paperView = [[WSIconView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 480.0, 320.0) model:paperModel];
		pictureWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0.0, 0.0, 480.0, 320.0)
			styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:YES];
		paperWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0.0, 0.0, 480.0, 320.0)
			styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:YES];
		[pictureWindow setContentView:pictureView];
		[paperWindow setContentView:paperView];

		[pictureView displayRect:[pictureView bounds]];
		[paperView displayRect:[paperView bounds]];
		printf("  (note: a grid of six pictures asked for the wait %ld time(s); six documents %ld time(s)\n",
		       (long)[pictureView cg_busyCursorUses], (long)[paperView cg_busyCursorUses]);
		check([pictureView cg_busyCursorUses] == 1,
		      "a grid that decodes six pictures puts the busy pointer up for the draw");
		check([paperView cg_busyCursorUses] == 0,
		      "a grid of documents does not, because it decodes nothing");
		[pictureView release];
		[paperView release];
		[pictureWindow release];
		[paperWindow release];
		[pictureModel release];
		[paperModel release];
	}

	/* 1. THE GRID IS THE DESKTOP'S ENGINE IN THE FILE WINDOW'S ORDER. */
	check(near([[[view cg_positions] objectAtIndex:0] pointValue].x, 16.0)
	      && near([[[view cg_positions] objectAtIndex:0] pointValue].y, 16.0),
	      "the first cell is the top-left margin");
	check(near([[[view cg_positions] objectAtIndex:1] pointValue].x, 96.0)
	      && near([[[view cg_positions] objectAtIndex:1] pointValue].y, 16.0),
	      "the second item is one cell to the RIGHT, in the same row");
	{
		/* **THE PITCH IS THE CELL, NOT A NUMBER.** The cell's height is the icon, the air between it and the name, and
		 * the name, so a gap that is asked for twice as large moves the second row down with it. */
		NSSize cell = [WSIconLayout cellSizeForIconSize:WSIconDefaultSize];

		check(near([[[view cg_positions] objectAtIndex:4] pointValue].x, 16.0)
		      && near([[[view cg_positions] objectAtIndex:4] pointValue].y, 16.0 + cell.height),
		      "and the fifth wraps to the next ROW at the left edge");
		check(near([view contentHeightForWidth:400.0], 16.0 + 2.0 * cell.height),
		      "and two rows make a document that is two cells tall plus the margin");
	}

	/* 1b. **ONE RECTANGLE WEARS BOTH THE WASH AND THE RING, CENTRED ON THE ICON AND CLEAR OF THE NAME.** The wash used
	 * to be the cell's — which carries its padding to the right and above, so it sat off-centre on the folder — while the
	 * ring was the bare icon's, two points out, with its top edge on the label's first line. The names below are the
	 * arithmetic that made the screenshot wrong. */
	{
		NSRect icon = NSMakeRect([[[view cg_positions] objectAtIndex:0] pointValue].x,
					  [[[view cg_positions] objectAtIndex:0] pointValue].y, 64.0, 64.0);
		NSRect highlight = [view cg_highlightRectAtIndex:0];
		CGFloat labelTop = NSMaxY(icon) + 2.0 + 16.0;	/* the icon, the gap, the label height */

		check(near(NSMidX(highlight), NSMidX(icon)),
		      "the selection's rectangle is centred on the icon, not on the cell's padding");
		/* **THE CELL'S WIDTH LESS ITS AIR, SO NEIGHBOURS NEVER MEET.** A wash the width of the cell left nothing between
		 * a run of selected icons — the rows stayed apart but the columns were one slab — so the highlight is inset by
		 * the same figure at each end that it keeps above and below. */
		check(near(highlight.size.width,
			   [WSIconLayout cellSizeForIconSize:WSIconDefaultSize].width - 2.0 * (CGFloat)WSIconHighlightInset),
		      "it is the cell's width less its own air, so neighbours never share a wash");
		check(NSMinY(highlight) < NSMinY(icon) && NSMaxY(highlight) > labelTop,
		      "and it encloses the icon and the whole label band");
	}

	/* 1c. **A SELECTION THAT MOVES ONE CELL REPAINTS ONE CELL.** The view used to answer a click with
	 * `-setNeedsDisplay:`, which is "all of me": the window then drew every folder and every name and copied the whole
	 * frame to move a wash from one cell to the next — MEASURED at 20-45 ms a click against 3-7 ms for the cells. So
	 * what is asserted here is the SHAPE of the invalidation: the cell that was selected, the cell that now is, and
	 * nothing else in the grid. */
	[view setNeedsDisplay:NO];
	[view selectIndex:0];
	{
		NSRect first = [view cg_highlightRectAtIndex:0];
		NSRect second = [view cg_highlightRectAtIndex:1];
		NSRect elsewhere = [view cg_highlightRectAtIndex:[view itemCount] - 1];

		check([view needsDisplayInRect:first], "selecting a cell invalidates that cell");
		/* **AND THE RING IS ON THE CELL'S EDGE, SO ITS STROKE IS OUTSIDE THE CELL.** A one-point stroke centred on
		 * the highlight's edge paints half a point beyond it and antialiases a point either side; an invalidation
		 * that stopped at the rectangle left a thin outline behind in the cell the selection had left. */
		check(NSEqualRects([view cg_dirtyUnion], NSInsetRect(first, -2.0, -2.0)),
		      "and the damage reaches two points past it, which is what erases the ring stroked on the edge");
		check(![view needsDisplayInRect:elsewhere],
		      "and not the rest of the grid, which is what makes a click a two-cell paint");

		[view setNeedsDisplay:NO];
		[view selectIndex:1];
		check([view needsDisplayInRect:first] && [view needsDisplayInRect:second],
		      "moving the selection invalidates the cell it left AND the cell it entered");
		check(![view needsDisplayInRect:elsewhere], "and still nothing else");
	}

	/* 1d. **A PRESS IN THE EMPTY SPACE BEGINS A BAND, AND THE BAND IS DRAWN.** There was no gesture: every press between
	 * icons cleared the selection and stopped, so several icons could only be taken with the keyboard. What is asserted
	 * is the three things a band is — the rectangle it reports, the damage it asks for, and the two colours it paints (an
	 * accent wash inside a darker edge), sampled out of a real draw.
	 *
	 * **THE PAINT IS MEASURED OVER THE VIEW'S OWN WHITE**, so the band used for it is the narrow strip left of the first
	 * column: over a folder's blue artwork the wash tints the picture, and the question "which colour is the band" would
	 * be answered by the picture instead. The strip is also SYMMETRIC about the view's middle (y 100..300 of 400), so the
	 * sample point is the same row whichever way a bitmap counts its rows. */
	{
		NSPoint paintStart = NSMakePoint(2.0, 100.0);
		NSPoint paintEnd = NSMakePoint(6.0, 300.0);	/* it must stop short of the first cell's wash at x 8 */
		NSPoint start = NSMakePoint(2.0, 2.0);		/* the gesture: an empty corner, across the first icon */
		NSPoint end = NSMakePoint(70.0, 55.0);
		NSRect band;
		NSBitmapImageRep *rep;
		NSColor *inside;
		NSColor *edge;
		NSColor *outside;

		[view selectIndex:-1];
		[view setNeedsDisplay:NO];
		[view mouseDown:mouse(NSLeftMouseDown, [view convertPoint:paintStart toView:nil])];
		[view mouseDragged:mouse(NSLeftMouseDragged, [view convertPoint:paintEnd toView:nil])];
		band = [view cg_bandRect];
		check(near(NSMinX(band), 2.0) && near(NSMinY(band), 100.0)
		      && near(NSWidth(band), 4.0) && near(NSHeight(band), 200.0),
		      "the band is the rectangle between the press and the pointer, in either direction");
		check(NSContainsRect([view cg_dirtyUnion], NSInsetRect(band, -2.0, -2.0)),
		      "and the damage covers it, with the margin the hairline needs");

		rep = draw_view(view, 400, 400);
		inside = [rep colorAtX:4 y:200];
		edge = [rep colorAtX:2 y:200];
		outside = [rep colorAtX:380 y:380];
		/* **THE FILL IS THE ACCENT AT ITS STATED ALPHA OVER WHITE** — not "a blue something". The expectation is computed
		 * from `+cg_accentColor` and `WSSelectionBandFillAlpha`, so a hue or an alpha change shows up here. */
		{
			NSColor *accent = [[NSColor cg_accentColor] colorUsingColorSpaceName:NSCalibratedRGBColorSpace];

			if (accent == nil) {
				accent = [NSColor cg_accentColor];	/* already an RGB colour; the conversion refuses its own space */
			}
			{
				CGFloat alpha = WSSelectionBandFillAlpha;
				CGFloat r = alpha * [accent redComponent] + (1.0 - alpha);
				CGFloat g = alpha * [accent greenComponent] + (1.0 - alpha);
				CGFloat b = alpha * [accent blueComponent] + (1.0 - alpha);

				check(inside != nil && near([inside redComponent], r) && near([inside greenComponent], g)
				      && near([inside blueComponent], b),
				      "the band's fill is the accent at its stated alpha over the view's white");
				check(inside != nil && [inside redComponent] < 0.999,
				      "and it is SEMITRANSPARENT — white shows through it");
			}
		}
		check(edge != nil && [edge blueComponent] < [inside blueComponent] - 0.2,
		      "the border is a darker shade of that same accent");
		check(outside != nil && [outside redComponent] > 0.999 && [outside greenComponent] > 0.999
		      && [outside blueComponent] > 0.999,
		      "and outside the band the view is untouched white");
		[view mouseUp:mouse(NSLeftMouseUp, [view convertPoint:paintEnd toView:nil])];
		check([[view selectedIndexes] count] == 0, "a band over the empty margin selects nothing");
		check(NSEqualRects([view cg_bandRect], NSZeroRect), "and the band is gone");

		/* **THE SELECTION IS APPLIED WHEN THE BUTTON COMES UP**, which is the desktop's own rule: a drag across the grid
		 * must not repaint the selection under the hand that is following it. */
		[view mouseDown:mouse(NSLeftMouseDown, [view convertPoint:start toView:nil])];
		[view mouseDragged:mouse(NSLeftMouseDragged, [view convertPoint:end toView:nil])];
		check([[view selectedIndexes] count] == 0, "nothing is selected while the band is still being dragged");
		[view mouseUp:mouse(NSLeftMouseUp, [view convertPoint:end toView:nil])];
		check([[view selectedIndexes] count] == 1 && [[view selectedIndexes] containsIndex:0],
		      "letting go selects the one item the band touched");

		/* **AND A SHIFT-BAND ADDS TO WHAT WAS CHOSEN** rather than replacing it, which is the only reason to press in the
		 * empty space with Shift held. */
		[view selectIndex:3];
		{
			NSEvent *down = [NSEvent mouseEventWithType:NSLeftMouseDown
							  location:[view convertPoint:start toView:nil]
						     modifierFlags:NSShiftKeyMask timestamp:0.0 windowNumber:0 context:nil
						       eventNumber:0 clickCount:1 pressure:1.0f];

			[view mouseDown:down];
			[view mouseDragged:mouse(NSLeftMouseDragged, [view convertPoint:end toView:nil])];
			[view mouseUp:mouse(NSLeftMouseUp, [view convertPoint:end toView:nil])];
		}
		check([[view selectedIndexes] containsIndex:3] && [[view selectedIndexes] containsIndex:0],
		      "a Shift-band keeps the item that was already selected and adds the ones it touches");
	}

	/* 1e. **ONE SELECTION FOR THE WHOLE WORKSPACE.** The desktop and every file window are separate views with
	 * separate models, and their highlights were separate too — an icon could be chosen on the desktop and another in
	 * each open window at once, which says "these are all chosen" about files in three different folders. Choosing in one
	 * surface now takes the selection away from every other, and clearing one's own (a press in the empty space) is NOT
	 * choosing, so the window next door keeps what it had. */
	{
		WSItemModel *otherModel = [[WSItemModel alloc] initWithDirectory:otherRoot];
		WSIconView *second = [[WSIconView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 400.0, 400.0)
								 model:otherModel];
		NSWindow *secondWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0.0, 0.0, 400.0, 400.0)
								     styleMask:NSBorderlessWindowMask
								       backing:NSBackingStoreBuffered defer:NO];
		WSDesktopView *desktop = [[WSDesktopView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 520.0, 400.0)
								     directory:root];
		NSWindow *desktopWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0.0, 0.0, 520.0, 400.0)
								      styleMask:NSBorderlessWindowMask
									backing:NSBackingStoreBuffered defer:NO];

		[secondWindow setContentView:second];
		[desktopWindow setContentView:desktop];
		[otherModel release];

		/* A SELECTS: the other window and the desktop are empty. */
		[view selectIndex:1];
		check([[view selectedIndexes] count] == 1, "the window that chose holds the selection");
		check([[second selectedIndexes] count] == 0, "the window next door lets go of its own");
		check([[desktop cg_selection] count] == 0, "and so does the desktop");

		/* B SELECTS: the first window is empty. */
		[second selectIndex:0];
		check([[second selectedIndexes] count] == 1, "choosing in the second window takes the selection");
		check([[view selectedIndexes] count] == 0, "the first window lets go");

		/* THE DESKTOP SELECTS — through the mouse, which is the only way it chooses: the first icon's cell. */
		{
			NSPoint position = [[[desktop cg_positions] objectAtIndex:0] pointValue];
			NSRect bounds = [desktop bounds];
			NSPoint windowPoint = NSMakePoint(position.x + 32.0, bounds.size.height - (position.y + 32.0));
			NSEvent *down = mouse(NSLeftMouseDown, windowPoint);
			NSEvent *up = mouse(NSLeftMouseUp, windowPoint);

			[desktop mouseDown:down];
			[desktop mouseUp:up];
		}
		check([[desktop cg_selection] count] == 1, "the desktop holds the selection after a click on one of its icons");
		check([[view selectedIndexes] count] == 0 && [[second selectedIndexes] count] == 0,
		      "and both windows let go of theirs");

		/* AND BACK: a window choosing takes it off the desktop. */
		[view selectIndex:0];
		check([[view selectedIndexes] count] == 1 && [[desktop cg_selection] count] == 0,
		      "a window choosing takes the selection off the desktop");

		/* **CLEARING IS NOT CHOOSING.** A press in the empty space of the second window empties only itself, so the first
		 * window keeps the icon it holds — which is what makes "the selection moved" different from "nothing was chosen
		 * here". */
		{
			NSPoint empty = NSMakePoint(380.0, 380.0);	/* below the second window's items */

			[second mouseDown:mouse(NSLeftMouseDown, [second convertPoint:empty toView:nil])];
			[second mouseUp:mouse(NSLeftMouseUp, [second convertPoint:empty toView:nil])];
		}
		check([[second selectedIndexes] count] == 0, "the emptied window has nothing selected");
		check([[view selectedIndexes] count] == 1, "and the window that held the selection still does");

		/* **AND THE SPACE BETWEEN AN ICON AND ITS NAME IS ONE NUMBER, MEASURED ON BOTH.** The desktop's rep is read from
		 * its bottom and a flipped view's from the top, so each gap is taken in VISUAL terms: away from the icon, downward
		 * on the screen. What is asserted is that the two agree — the first row of ink is the same distance below the icon
		 * on a desktop and in a file window — and that the distance is a gap rather than a number that happens to match
		 * because both surfaces stopped drawing. */
		{
			NSColor *inkBackground = [NSColor colorWithCalibratedRed:0.10 green:0.20 blue:0.09 alpha:1.0];
			NSBitmapImageRep *viewRep = draw_view(view, 400, 400);
			NSBitmapImageRep *deskRep = draw_view_over(desktop, 520, 400, inkBackground);
			NSPoint dp = [[[desktop cg_positions] objectAtIndex:0] pointValue];
			int deskIconBottomRow = (int)dp.y + (int)[desktop iconSize];
			int viewIconBottomRow = (int)[[[view cg_positions] objectAtIndex:0] pointValue].y
				+ (int)WSIconDefaultSize;
			int y, x, viewFirst = -1, deskFirst = -1;
			int viewGap, deskGap;

			/* **THE SAME RULE ON BOTH**: a row is the ink's when a pixel is far from the background that surface
			 * paints, so a black name on white and a white name on a wallpaper are measured the same way. */
			for (y = viewIconBottomRow; y < viewIconBottomRow + 40 && viewFirst < 0; y++) {
				for (x = (int)[[[view cg_positions] objectAtIndex:0] pointValue].x; x < 96; x++) {
					if (ink_at([viewRep colorAtX:x y:y], [NSColor whiteColor])) {
						viewFirst = y;
						break;
					}
				}
			}
			for (y = deskIconBottomRow; y < deskIconBottomRow + 40 && y < 400 && deskFirst < 0; y++) {
				for (x = (int)dp.x; x < (int)dp.x + 80; x++) {
					if (ink_at([deskRep colorAtX:x y:y], inkBackground)) {
						deskFirst = y;
						break;
					}
				}
			}
			viewGap = viewFirst - viewIconBottomRow;
			deskGap = deskFirst - deskIconBottomRow;
			check(viewFirst >= 0 && deskFirst >= 0, "both surfaces draw a name under their icon");
			check(viewGap == deskGap,
			      "and the space between the icon and the first row of ink is the SAME on both");
			/* The box is the line's own height and the ink sits inside it, so the air a person sees is this number
			 * plus the ink's own bearing: the gap, and never a blank band. */
			check(viewGap >= (int)WSIconLabelGap && viewGap <= (int)WSIconLabelGap + 6,
			      "which is the air the grid reserves, plus the line's own bearing");
		}

		/* THE VIEWS STAY: they registered for the shared selection, and the tier's centre holds them WEAKLY — a view
		 * released here is not the test's to free while a post could still be in flight. A probe leaks four objects. */
		(void)desktop;
		(void)second;
		(void)desktopWindow;
		(void)secondWindow;
	}

	/* 1f. **THE DESKTOP AND A FILE WINDOW DRAW THE SAME SELECTED CELL.** The complaint was visual: a desktop selection was
	 * a square four points outside the icon, unrounded and stopping above the name, while a file window's was a rounded
	 * rectangle the width of the cell that enclosed the label. Two questions, asked two ways: the RECTANGLE each view
	 * answers (exact, and where the geometry lives) and the WASH each view actually paints (the thing a person sees, and
	 * the reason the rectangle cannot be believed on its own). */
	{
		WSDesktopView *desktop = [[WSDesktopView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 520.0, 400.0)
								     directory:root];
		NSWindow *desktopWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0.0, 0.0, 520.0, 400.0)
								      styleMask:NSBorderlessWindowMask
									backing:NSBackingStoreBuffered defer:NO];
		NSSize cell = [WSIconLayout cellSizeForIconSize:[desktop iconSize]];
		CGFloat wantWidth = cell.width - 2.0 * (CGFloat)WSIconHighlightInset;
		CGFloat wantHeight = (CGFloat)[desktop iconSize] + (CGFloat)WSIconLabelGap
			+ (CGFloat)WSIconLabelHeight + 2.0 * (CGFloat)WSIconHighlightInset;
		NSRect iconWash;
		NSRect desktopWash;

		[desktopWindow setContentView:desktop];

		[view selectIndex:0];
		iconWash = wash_bounds(draw_view(view, 400, 400), 400, 400);
		/* The corners are rounded, so the outermost rows and columns are only PARTLY tinted and the pure-colour box is a
		 * point or two inside the rectangle. What it pins is the thing that changed: the wash reaches past the icon. */
		check(NSWidth(iconWash) > (CGFloat)WSIconDefaultSize + 4.0
		      && NSHeight(iconWash) > (CGFloat)WSIconDefaultSize + 8.0,
		      "a file window's wash is wider than the icon and tall enough for the name");

		{
			NSPoint position = [[[desktop cg_positions] objectAtIndex:0] pointValue];
			NSRect bounds = [desktop bounds];
			NSPoint windowPoint = NSMakePoint(position.x + 32.0, bounds.size.height - (position.y + 32.0));

			[desktop mouseDown:mouse(NSLeftMouseDown, windowPoint)];
			[desktop mouseUp:mouse(NSLeftMouseUp, windowPoint)];
		}
		/* Over the white a file window paints, so the SHAPE can be compared: the wash is semitransparent, so its colour
		 * depends on the background and only this page makes the two surfaces' pixels comparable. */
		desktopWash = wash_bounds(draw_view(desktop, 520, 400), 520, 400);
		/* **AND THE WASH IS SEMITRANSPARENT ON BOTH.** The accent is a fill with an alpha, so what a person sees is it
		 * composited over whatever is behind the cell — a white page, a wallpaper, another window. So the desktop is
		 * painted over TWO backgrounds, and the same point inside the highlight must be two different colours, each of
		 * them the same blend: that is what "semitransparent" means, and a plate of white under the wash would fail it. */
		check(near(NSWidth(desktopWash), NSWidth(iconWash)) && near(NSHeight(desktopWash), NSHeight(iconWash)),
		      "and the desktop paints the SAME wash rectangle as a file window");
		{
			NSColor *dark = [NSColor colorWithCalibratedRed:0.10 green:0.20 blue:0.09 alpha:1.0];
			NSBitmapImageRep *overGreen = draw_view_over(desktop, 520, 400, dark);
			NSBitmapImageRep *overWhite = draw_view(desktop, 520, 400);
			NSRect highlight = [desktop cg_highlightRectAtIndex:0];
			NSInteger sx = (NSInteger)NSMinX(highlight) + 3;
			NSInteger syTop = (NSInteger)(400.0 - NSMidY(highlight));	/* this rep counts its rows from the top */
			NSColor *onGreen = [overGreen colorAtX:sx y:syTop];
			NSColor *onWhite = [overWhite colorAtX:sx y:syTop];
			NSColor *wash = WSIconCellSelectionColor();
			CGFloat a = [wash alphaComponent];
			CGFloat wantR = a * [wash redComponent] + (1.0 - a) * [dark redComponent];
			CGFloat wantG = a * [wash greenComponent] + (1.0 - a) * [dark greenComponent];
			CGFloat wantB = a * [wash blueComponent] + (1.0 - a) * [dark blueComponent];

			check(onGreen != nil && near([onGreen redComponent], wantR) && near([onGreen greenComponent], wantG)
			      && near([onGreen blueComponent], wantB),
			      "the wash over a wallpaper is the accent at its own alpha, not a plate");
			check(onWhite != nil && near([onWhite redComponent], a * [wash redComponent] + (1.0 - a))
			      && near([onWhite blueComponent], a * [wash blueComponent] + (1.0 - a)),
			      "and over a white page it is the same alpha over that page");
			check(onGreen != nil && onWhite != nil
			      && (fabs([onGreen redComponent] - [onWhite redComponent]) > 0.2),
			      "so the background shows THROUGH the selection");
		}
		/* **AND THE DESKTOP'S NAME IS WHITE WITH A BLACK SHADOW; A FILE WINDOW'S IS BLACK WITH NONE.** White ink over a
		 * wallpaper needs an edge a white page never asks for, so the desktop draws the same name once in black, one
		 * point down and right, before the white. Painted over a WHITE page — where white ink is invisible — the only
		 * thing that can leave a dark pixel under the icon is that shadow. */
		{
			NSBitmapImageRep *page = draw_view(desktop, 520, 400);
			NSRect highlight = [desktop cg_highlightRectAtIndex:0];
			int yTop = (int)(400.0 - NSMidY(highlight));	/* the name hangs below the icon */
			int yBottom = (int)(400.0 - NSMinY(highlight));
			int dark = 0, x, y;

			for (y = yTop; y < yBottom; y++) {
				for (x = (int)NSMinX(highlight); x < (int)NSMaxX(highlight); x++) {
					NSColor *c = [page colorAtX:x y:y];

					if (c != nil && [c redComponent] < 0.25 && [c greenComponent] < 0.25
					    && [c blueComponent] < 0.25) {
						dark++;
					}
				}
			}
			check(dark > 4,
			      "and a desktop name is white with a BLACK SHADOW — over a white page its ink is invisible, its shadow is not");
		}

		/* **AND THE RECTANGLES ARE THE SAME SHAPE**, which the pixels cannot say — the desktop's first icon sits against
		 * the edge of its view, so its wash is clipped. Each view answers the rectangle it fills; what is compared is its
		 * size and its position RELATIVE to the icon, so two different layouts are held to one presentation. */
		{
			NSPoint viewIconPosition = [[[view cg_positions] objectAtIndex:0] pointValue];
			NSRect viewIcon = NSMakeRect(viewIconPosition.x, viewIconPosition.y,
						     (CGFloat)WSIconDefaultSize, (CGFloat)WSIconDefaultSize);
			NSRect inView = [view cg_highlightRectAtIndex:0];
			NSRect inDesktop = [desktop cg_highlightRectAtIndex:0];
			NSPoint desktopIconPosition = [[[desktop cg_positions] objectAtIndex:0] pointValue];
			NSRect desktopIcon = NSMakeRect(desktopIconPosition.x,
							[desktop bounds].size.height - desktopIconPosition.y
							- (CGFloat)[desktop iconSize],
							(CGFloat)[desktop iconSize], (CGFloat)[desktop iconSize]);

			check(near(NSWidth(inDesktop), NSWidth(inView)) && near(NSHeight(inDesktop), NSHeight(inView)),
			      "the two surfaces answer the same highlight SIZE for the same cell");
			/* **"THE SAME WAY" HAS TO BE SAID IN VISUAL TERMS, NOT IN y.** A file window is flipped and the desktop is
			 * not, so the name hanging BELOW the icon is a larger y in one and a smaller y in the other. What must match
			 * is the AIR above the icon and the AIR below it, whichever way the numbers run. */
			{
				CGFloat viewAirAbove = NSMinY(viewIcon) - NSMinY(inView);
				CGFloat viewAirBelow = NSMaxY(inView) - NSMaxY(viewIcon);
				CGFloat desktopAirAbove = NSMaxY(inDesktop) - NSMaxY(desktopIcon);
				CGFloat desktopAirBelow = NSMinY(desktopIcon) - NSMinY(inDesktop);
				CGFloat wantAirAbove = (CGFloat)WSIconHighlightInset;
				CGFloat wantAirBelow = (CGFloat)WSIconLabelGap + (CGFloat)WSIconLabelHeight
					+ (CGFloat)WSIconHighlightInset;

				check(near(NSMinX(inDesktop) - NSMinX(desktopIcon), NSMinX(inView) - NSMinX(viewIcon)),
				      "and sits the same way around the icon horizontally");
				check(near(viewAirAbove, wantAirAbove) && near(desktopAirAbove, wantAirAbove),
				      "with the same air above the icon in both — the name is on the other side");
				check(near(viewAirBelow, wantAirBelow) && near(desktopAirBelow, wantAirBelow),
				      "and the same room below it for the name");
			}
			check(near(NSWidth(inView), wantWidth) && near(NSHeight(inView), wantHeight),
			      "which is the cell's width less its air, and tall enough for the icon and the name");
		}

		/* THE VIEWS STAY: they registered for the shared selection, and a released observer is not this probe's business
		 * (a probe leaks two objects rather than freeing one the centre may still be holding). */
		(void)desktop;
		(void)desktopWindow;
	}

	/* 2. THE KEYBOARD MOVES THE SELECTION IN THE GRID. */
	[view selectIndex:0];
	[view keyDown:key(NSRightArrowFunctionKey, 0)];
	check([view selectedIndex] == 1, "Right moves to the next item");
	[view keyDown:key(NSDownArrowFunctionKey, 0)];
	check([view selectedIndex] == 4, "Down moves by one row of four columns");
	[view keyDown:key(NSUpArrowFunctionKey, 0)];
	check([view selectedIndex] == 0, "Up returns to the top row");
	[view keyDown:key(NSLeftArrowFunctionKey, 0)];
	check([view selectedIndex] == 0, "Left at the first cell stays there");
	[view keyDown:key(NSEndFunctionKey, 0)];
	check([view selectedIndex] == [view itemCount] - 1, "End selects the last item");
	[view keyDown:key(NSHomeFunctionKey, 0)];
	check([view selectedIndex] == 0, "Home selects the first");

	[view selectIndex:0];
	[view keyDown:key(NSRightArrowFunctionKey, NSShiftKeyMask)];
	check([[view selectedIndexes] containsIndex:0] && [[view selectedIndexes] containsIndex:1],
	      "Shift-Right extends the selection from the anchor");
	[view keyDown:key('a', NSCommandKeyMask)];
	check([[view selectedIndexes] count] == (NSUInteger)[view itemCount], "Command-A selects all");

	/* 2a. **A CLICK WITH CONTROL, COMMAND OR SHIFT EXTENDS THE SELECTION**, which is what those three keys mean in every
	 * grid: Control and Command add or take away one icon, and Shift takes the run from the anchor to the one clicked.
	 * Control is the spelling every non-Mac desktop taught the hand, and it must not be the one that does nothing. */
	{
		NSPoint row[3];

		row[0] = [view convertPoint:centerOfIndex(view, 0) toView:nil];
		row[1] = [view convertPoint:centerOfIndex(view, 1) toView:nil];
		row[2] = [view convertPoint:centerOfIndex(view, 2) toView:nil];

		[view selectIndex:-1];
		[view mouseDown:mouse(NSLeftMouseDown, row[0])];
		[view mouseUp:mouse(NSLeftMouseUp, row[0])];
		check([[view selectedIndexes] count] == 1 && [[view selectedIndexes] containsIndex:0],
		      "a plain click on an icon selects it alone");
		[view mouseDown:mouseWithFlags(NSLeftMouseDown, row[2], NSControlKeyMask)];
		[view mouseUp:mouse(NSLeftMouseUp, row[2])];
		check([[view selectedIndexes] count] == 2 && [[view selectedIndexes] containsIndex:0]
		      && [[view selectedIndexes] containsIndex:2],
		      "a Control-click adds the icon it is on to the selection");
		[view mouseDown:mouseWithFlags(NSLeftMouseDown, row[2], NSControlKeyMask)];
		[view mouseUp:mouse(NSLeftMouseUp, row[2])];
		check([[view selectedIndexes] count] == 1 && ![[view selectedIndexes] containsIndex:2],
		      "and a second one takes it away again");
		[view mouseDown:mouseWithFlags(NSLeftMouseDown, row[2], NSCommandKeyMask)];
		[view mouseUp:mouse(NSLeftMouseUp, row[2])];
		check([[view selectedIndexes] count] == 2 && [[view selectedIndexes] containsIndex:2],
		      "Command-click does the same, so neither modifier is the only one that works");
		[view mouseDown:mouse(NSLeftMouseDown, row[2])];
		[view mouseUp:mouse(NSLeftMouseUp, row[2])];
		[view mouseDown:mouseWithFlags(NSLeftMouseDown, row[0], NSShiftKeyMask)];
		[view mouseUp:mouse(NSLeftMouseUp, row[0])];
		check([[view selectedIndexes] count] == 3 && [[view selectedIndexes] containsIndex:0]
		      && [[view selectedIndexes] containsIndex:1] && [[view selectedIndexes] containsIndex:2],
		      "and a Shift-click takes the run between the anchor and the icon clicked");
		[view mouseDown:mouse(NSLeftMouseDown, row[1])];
		[view mouseUp:mouse(NSLeftMouseUp, row[1])];
	}

	/* 3. TYPE-SELECT ACCUMULATES A PREFIX AND RESTARTS AFTER A SECOND. */
	[view selectIndex:-1];
	[view keyDown:key('d', 0)];
	check([view selectedIndex] == 1, "typing d selects delta.txt");
	[view keyDown:key('o', 0)];
	check([view selectedIndex] == 2, "and do selects Documents rather than restarting at d");

	/* 4. INLINE RENAME: A MOVE, A RELOAD, AND A REFUSAL. */
	[view selectIndex:indexNamed(view, @"delta.txt")];
	check([view beginRenamingSelectedItem], "Return/begin starts a rename over the label");
	check([[view cg_renameField] stringValue] != nil
	      && [[[view cg_renameField] stringValue] isEqual:@"delta.txt"],
	      "the field starts with the current name");
	[[view cg_renameField] setStringValue:@"renamed.txt"];
	check([view commitRenaming], "committing the field renames the file");
	check([[NSFileManager defaultManager] fileExistsAtPath:[root stringByAppendingPathComponent:@"renamed.txt"]]
	      && ![[NSFileManager defaultManager] fileExistsAtPath:[root stringByAppendingPathComponent:@"delta.txt"]],
	      "the file on disk has the new name");
	check([view selectedIndex] == indexNamed(view, @"renamed.txt"), "and the selection follows it");

	[view selectIndex:indexNamed(view, @"notes.txt")];
	check([view beginRenamingSelectedItem], "a second rename begins");
	[[view cg_renameField] setStringValue:@"other.txt"];
	[view cancelRenaming];
	check([[NSFileManager defaultManager] fileExistsAtPath:[root stringByAppendingPathComponent:@"notes.txt"]]
	      && ![[NSFileManager defaultManager] fileExistsAtPath:[root stringByAppendingPathComponent:@"other.txt"]],
	      "cancel leaves the file alone");

	[view selectIndex:indexNamed(view, @"notes.txt")];
	[view beginRenamingSelectedItem];
	[[view cg_renameField] setStringValue:@""];
	check(![view commitRenaming], "an empty name is refused");
	[view selectIndex:indexNamed(view, @"notes.txt")];
	[view beginRenamingSelectedItem];
	[[view cg_renameField] setStringValue:@"bad/name"];
	check(![view commitRenaming], "a slash is refused");

	/* 5. THE SOURCE PUTS THE SELECTED PATHS ON THE DRAG PASTEBOARD. */
	[view selectIndex:indexNamed(view, @"notes.txt")];
	{
		/* **THE EVENT'S LOCATION IS IN THE WINDOW'S SPACE, WHICH IS NOT THE VIEW'S** — this grid is flipped, so handing
		 * a view point over as a window point is a mirror, not an identity. The session converts from the window (see
		 * `NSDragging.m`), so the probe says what a real event says. */
		NSPoint iconPoint = centerOfIndex(view, [view selectedIndex]);
		NSEvent *drag = mouse(NSLeftMouseDragged, [view convertPoint:iconPoint toView:nil]);
		NSDraggingSession *session = [view cg_beginDragWithEvent:drag];
		id plist;

		check(session != nil && [NSDraggingSession cg_activeSession] == session,
		      "a selected icon begins the tier's drag session");
		plist = [[session draggingPasteboard] propertyListForType:NSFilenamesPboardType];
		check([plist isKindOfClass:[NSArray class]] && [plist count] == 1
		      && [[plist objectAtIndex:0] isEqual:[root stringByAppendingPathComponent:@"notes.txt"]],
		      "with the selected path on NSFilenamesPboardType");
		[window sendEvent:mouse(NSLeftMouseUp, [view convertPoint:iconPoint toView:nil])];
		check([NSDraggingSession cg_activeSession] == nil, "and the release ends it");
	}

	/* 5b. A REAL SESSION BETWEEN TWO WINDOWS: the source begins it, the destination is found by SCREEN point,
	 * the release performs it, and both models reload. */
	{
		WSItemModel *targetModel = [[WSItemModel alloc] initWithDirectory:target];
		WSIconView *targetView = [[WSIconView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 400.0, 400.0)
								     model:targetModel];
		NSWindow *targetWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(500.0, 0.0, 400.0, 400.0)
								     styleMask:NSBorderlessWindowMask
								       backing:NSBackingStoreBuffered defer:NO];

		[targetWindow setContentView:targetView];
		[[NSApplication sharedApplication] cg_addWindow:window];
		[[NSApplication sharedApplication] cg_addWindow:targetWindow];
		[view selectIndex:indexNamed(view, @"notes.txt")];
		(void)[view cg_beginDragWithEvent:mouse(NSLeftMouseDragged, centerOfIndex(view, [view selectedIndex]))];
		[window sendEvent:mouse(NSLeftMouseDragged, NSMakePoint(520.0, 50.0))];
		[window sendEvent:mouse(NSLeftMouseUp, NSMakePoint(520.0, 50.0))];
		check([[NSFileManager defaultManager] fileExistsAtPath:
			[target stringByAppendingPathComponent:@"notes.txt"]]
		      && ![[NSFileManager defaultManager] fileExistsAtPath:
			[root stringByAppendingPathComponent:@"notes.txt"]],
		      "a drag from one window's icon view to another's moves the file");
		check([targetView itemCount] == 1 && indexNamed(view, @"notes.txt") == -1,
		      "and both models reloaded");
		[[NSApplication sharedApplication] cg_removeWindow:targetWindow];
		[[NSApplication sharedApplication] cg_removeWindow:window];
		[targetWindow release];
		[targetView release];
		[targetModel release];
	}

	/* 6. THE DROP POLICY IS A FACT ABOUT VOLUMES AND MODIFIERS. */
	check([view cg_proposedOperationForSameVolume:YES modifiers:0] == NSDragOperationMove,
	      "same volume, no modifier: Move");
	check([view cg_proposedOperationForSameVolume:YES modifiers:NSAlternateKeyMask] == NSDragOperationCopy,
	      "Option: Copy");
	check([view cg_proposedOperationForSameVolume:NO modifiers:0] == NSDragOperationCopy,
	      "another volume: Copy");
	check([view cg_proposedOperationForSameVolume:NO modifiers:NSCommandKeyMask] == NSDragOperationMove,
	      "Command across a volume: Move");
	check([view cg_proposedOperationForSameVolume:YES
					     modifiers:(NSAlternateKeyMask | NSCommandKeyMask)] == NSDragOperationLink,
	      "Command-Option: Link");

	/* 7. THE OPERATIONS THEMSELVES, AGAINST THE TWO VOLUMES. */
	{
		WSItemModel *targetModel = [[WSItemModel alloc] initWithDirectory:target];
		WSIconView *targetView = [[WSIconView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 400.0, 400.0)
								     model:targetModel];

		check([targetView cg_performDropOfPaths:
			[NSArray arrayWithObject:[sourceRoot stringByAppendingPathComponent:@"move.txt"]]
			intoDirectory:target operation:NSDragOperationMove],
		      "Move performs a move into the destination folder");
		check([[NSFileManager defaultManager] fileExistsAtPath:[target stringByAppendingPathComponent:@"move.txt"]]
		      && ![[NSFileManager defaultManager] fileExistsAtPath:[sourceRoot stringByAppendingPathComponent:@"move.txt"]],
		      "and the source is gone");

		check([targetView cg_performDropOfPaths:
			[NSArray arrayWithObject:[sourceRoot stringByAppendingPathComponent:@"copy.txt"]]
			intoDirectory:target operation:NSDragOperationCopy],
		      "Copy leaves the source and makes the copy");
		check([[NSFileManager defaultManager] fileExistsAtPath:[target stringByAppendingPathComponent:@"copy.txt"]]
		      && [[NSFileManager defaultManager] fileExistsAtPath:[sourceRoot stringByAppendingPathComponent:@"copy.txt"]],
		      "both names exist");

		check([targetView cg_performDropOfPaths:
			[NSArray arrayWithObject:[sourceRoot stringByAppendingPathComponent:@"link.txt"]]
			intoDirectory:target operation:NSDragOperationLink],
		      "Link makes a link");
		check([[[NSFileManager defaultManager]
			destinationOfSymbolicLinkAtPath:[target stringByAppendingPathComponent:@"link.txt"] error:NULL]
			isEqual:[sourceRoot stringByAppendingPathComponent:@"link.txt"]],
		      "and it points at the source path");

		{
			WSItemModel *otherModel = [[WSItemModel alloc] initWithDirectory:otherTarget];
			WSIconView *otherView = [[WSIconView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 400.0, 400.0)
									 model:otherModel];

			check([otherView cg_performDropOfPaths:
				[NSArray arrayWithObject:[sourceRoot stringByAppendingPathComponent:@"copy.txt"]]
				intoDirectory:otherTarget operation:NSDragOperationCopy],
			      "a copy onto /dev/shm crosses a volume and performs");
			check([[NSFileManager defaultManager] fileExistsAtPath:
				[otherTarget stringByAppendingPathComponent:@"copy.txt"]]
			      && [[NSFileManager defaultManager] fileExistsAtPath:
				[sourceRoot stringByAppendingPathComponent:@"copy.txt"]],
			      "with the source still on the first volume");
			[otherView release];
			[otherModel release];
		}

		check(makeFile([target stringByAppendingPathComponent:@"conflict.txt"]), "a conflict is planted");
		check(makeFile([sourceRoot stringByAppendingPathComponent:@"conflict.txt"]), "on the source side");
		check(![targetView cg_performDropOfPaths:
			[NSArray arrayWithObject:[sourceRoot stringByAppendingPathComponent:@"conflict.txt"]]
			intoDirectory:target operation:NSDragOperationMove],
		      "an existing destination refuses the drop");
		check([[NSFileManager defaultManager] fileExistsAtPath:[sourceRoot stringByAppendingPathComponent:@"conflict.txt"]],
		      "and the source is untouched");

		[targetView release];
		[targetModel release];
	}

	/* 8. THE DESTINATION'S VIEW OF A DRAG: ENTER, DROP, AND A FOLDER AS THE TARGET. */
	{
		WSItemModel *rootModel = [[WSItemModel alloc] initWithDirectory:root];
		WSIconView *dropView = [[WSIconView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 400.0, 400.0)
								   model:rootModel];
		NSWindow *dropWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0.0, 0.0, 400.0, 400.0)
								   styleMask:NSBorderlessWindowMask
								     backing:NSBackingStoreBuffered defer:NO];
		NSString *source = [sourceRoot stringByAppendingPathComponent:@"into-folder.txt"];
		NSPoint point = centerOfIndex(dropView, indexNamed(dropView, @"Target"));
		AGDropInfo *info = [[AGDropInfo alloc] initWithPaths:[NSArray arrayWithObject:source]
							    location:point mask:NSDragOperationEvery];
		NSDragOperation entered;

		[dropWindow setContentView:dropView];
		entered = [dropView draggingEntered:info];
		check(entered == NSDragOperationMove, "dropping on a folder icon targets that folder with Move");
		check([dropView performDragOperation:info], "and the drop is performed");
		check([[NSFileManager defaultManager]
			fileExistsAtPath:[target stringByAppendingPathComponent:@"into-folder.txt"]],
		      "the file landed inside the folder");
		[dropView draggingExited:info];
		[info release];
		[dropWindow release];
		[dropView release];
		[rootModel release];
	}

	/* 9. SPRING-LOADING ASKS THE APPLICATION FOR THE FOLDER'S WINDOW. */
	{
		WSItemModel *rootModel = [[WSItemModel alloc] initWithDirectory:root];
		WSIconView *dropView = [[WSIconView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 400.0, 400.0)
								   model:rootModel];
		NSWindow *dropWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0.0, 0.0, 400.0, 400.0)
								   styleMask:NSBorderlessWindowMask
								     backing:NSBackingStoreBuffered defer:NO];
		NSPoint point = centerOfIndex(dropView, indexNamed(dropView, @"Target"));
		AGDropInfo *info = [[AGDropInfo alloc] initWithPaths:
			[NSArray arrayWithObject:[sourceRoot stringByAppendingPathComponent:@"copy.txt"]]
			location:point mask:NSDragOperationEvery];

		spring = [[AGSpringProbe alloc] init];
		[[NSNotificationCenter defaultCenter] addObserver:spring selector:@selector(requested:)
			name:WSIconViewRequestFolderWindowNotification object:nil];
		[dropWindow setContentView:dropView];
		(void)[dropView draggingEntered:info];
		[dropView cg_springOpen];
		check(spring->requests == 1 && [spring->path isEqual:target],
		      "a hovered folder asks for its window, with its path");
		[dropView draggingExited:info];
		[[NSNotificationCenter defaultCenter] removeObserver:spring];
		[spring release];
		[info release];
		[dropWindow release];
		[dropView release];
		[rootModel release];
	}

	/* 11. **THE CONTEXT MENU: THE REFERENCE FILE MANAGER'S ROWS, ONE ITEM, AND A CLICK THAT NAMES ITS SUBJECT.**
	 *
	 * The menu is built by `WSContextMenu` and returned by `-menuForEvent:` — the door `NSView -rightMouseDown:` asks —
	 * so what is measured is the rows and their order, the command each one sends, and the two rows that are GREY today
	 * because their features are not written (Get Info is W8; Cut has no Paste to feed). */
	{
		NSString *trashRoot = [@"/tmp" stringByAppendingPathComponent:
			[NSString stringWithFormat:@"agora-icon-trash-%d", (int)getpid()]];
		WSTrash *trash = [[WSTrash alloc] initWithRoot:trashRoot];
		WSFileOperations *operations = [[WSFileOperations alloc] initWithUndoManager:nil trash:trash];
		NSInteger notes;
		NSMenu *menu;
		NSArray *rows;

		/* **A FILE OF ITS OWN, BECAUSE EARLIER SECTIONS MOVED AND RENAMED THE OTHERS.** The menu is about "the item under
		 * the pointer", so the probe makes one and reads the directory again rather than depending on what is left. */
		makeFile([root stringByAppendingPathComponent:@"menu.txt"]);
		[view reloadAfterChange];
		notes = indexNamed(view, @"menu.txt");
		check(notes >= 0, "the probe's own file is in the grid");

		[view setFileOperations:operations];
		[view selectIndex:notes];
		menu = [view menuForEvent:mouse(NSRightMouseDown, centerOfIndex(view, notes))];
		rows = (menu != nil) ? [menu itemArray] : nil;
		check([rows count] == 8, "a right-click on an icon answers a menu of eight rows");
		if ([rows count] == 8) {
			NSArray *titles = [NSArray arrayWithObjects:@"Get Info", @"Cut", @"Copy", @"Rename", @"Compress",
									   @"Move to Trash", nil];
			NSInteger want[8] = { 0, -1, 1, 2, -1, 3, 4, 5 };	/* -1 is a separator */
			NSInteger i;
			BOOL shape = YES;

			for (i = 0; i < 8; i++) {
				NSMenuItem *item = [rows objectAtIndex:(NSUInteger)i];

				if (want[i] < 0) {
					shape = shape && [item isSeparatorItem];
				} else {
					shape = shape && [[item title] isEqual:[titles objectAtIndex:(NSUInteger)want[i]]];
				}
			}
			check(shape, "Get Info | Cut, Copy | Rename, Compress, Move to Trash, in that order with those separators");
			check([[rows objectAtIndex:0] action] == @selector(getInfo:)
			      && [[rows objectAtIndex:2] action] == @selector(cut:)
			      && [[rows objectAtIndex:3] action] == @selector(copy:)
			      && [[rows objectAtIndex:5] action] == @selector(rename:)
			      && [[rows objectAtIndex:6] action] == @selector(compress:)
			      && [[rows objectAtIndex:7] action] == @selector(moveToTrash:),
			      "and each row sends its own command");
			check([[rows objectAtIndex:0] target] == view && [[rows objectAtIndex:7] target] == view,
			      "every row is aimed at the view the click landed in, not left to the responder chain");

			/* **AND A ROW THE GRID CANNOT ANSWER IS THE DEFECT THIS MEASURES.** The menu is aimed at the view, so a row
			 * whose command the view does not implement is a row that does nothing: MEASURED, Get Info and Compress were
			 * both dead in the grid while the list and the browser had them working, because those aim at the window. */
			[menu update];
			check([[rows objectAtIndex:0] isEnabled], "Get Info is live in the grid, as it is in the list");
			check([[rows objectAtIndex:2] isEnabled] && [[rows objectAtIndex:3] isEnabled]
			      && [[rows objectAtIndex:5] isEnabled] && [[rows objectAtIndex:6] isEnabled]
			      && [[rows objectAtIndex:7] isEnabled],
			      "and Cut, Copy, Rename, Compress and Move to Trash are live for a single selected item");
		}

		/* ---- CUT AND PASTE: THE ONE PAIR A CUT NEEDS TO MEAN ANYTHING ---- */
		{
			WSItemModel *thereModel = [[WSItemModel alloc] initWithDirectory:target];
			WSIconView *there = [[WSIconView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 400.0, 400.0)
								       model:thereModel];
			NSWindow *thereWindow = [[NSWindow alloc]
				initWithContentRect:NSMakeRect(500.0, 0.0, 400.0, 400.0)
					  styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
			BOOL wasCut = NO;
			NSArray *offered;

			[thereWindow setContentView:there];
			[there setFileOperations:operations];
			/* A FILE OF ITS OWN, because this one LEAVES: the rows below are still about `menu.txt`. */
			makeFile([root stringByAppendingPathComponent:@"cut.txt"]);
			[view reloadAfterChange];
			[view selectIndex:indexNamed(view, @"cut.txt")];
			[view cut:nil];
			offered = WSItemClipboardPaths(&wasCut);
			check([offered count] == 1 && wasCut,
			      "Cut offers the path on the pasteboard and marks the offer as one to take away");
			[there paste:nil];
			check(![[NSFileManager defaultManager] fileExistsAtPath:
								[ root stringByAppendingPathComponent:@"cut.txt"]]
				      && [[NSFileManager defaultManager] fileExistsAtPath:
								[ target stringByAppendingPathComponent:@"cut.txt"]],
				      "and a paste in another grid MOVES it there, which is what a cut promised");
			{
				BOOL stillCut = YES;

				(void)WSItemClipboardPaths(&stillCut);
				check(!stillCut, "and the cut is used up: a second paste copies rather than moves");
			}
			[view reloadAfterChange];
			[there release];
			[thereModel release];
			[thereWindow release];
		}

		/* ---- **THE GROUP'S MENU, AND THE TWO THINGS A CLICK CAN DO TO A GROUP.** A click on one of several HELD icons
		 * keeps the group (it must, or a group's menu could never be reached: the pointer is always over one of them);
		 * a click outside the group narrows to what it landed on. */
		{
			NSMenu *grouped;
			NSArray *groupRows;

			[view selectAll:nil];
			grouped = [view menuForEvent:mouse(NSRightMouseDown, centerOfIndex(view, notes))];
			groupRows = (grouped != nil) ? [grouped itemArray] : nil;
			check([[view selectedIndexes] count] == (NSUInteger)[view itemCount],
			      "a right-click on one of several held icons keeps the group");
			check([groupRows count] == 8, "and answers the group's own menu");
			if ([groupRows count] == 8) {
				NSArray *titles = [NSArray arrayWithObjects:@"Get Info", @"New Folder with Selection", @"Compress",
									   @"Cut", @"Copy", @"Move to Trash", nil];
				NSInteger want[8] = { 0, 1, 2, -1, 3, 4, -1, 5 }; /* -1 is a separator */
				NSInteger i;
				BOOL shape = YES;

				for (i = 0; i < 8; i++) {
					NSMenuItem *item = [groupRows objectAtIndex:(NSUInteger)i];

					if (want[i] < 0) {
						shape = shape && [item isSeparatorItem];
					} else {
						shape = shape && [[item title] isEqual:[titles objectAtIndex:(NSUInteger)want[i]]];
					}
				}
				check(shape, "Get Info, New Folder with Selection, Compress | Cut, Copy | Move to Trash");
				check([[groupRows objectAtIndex:1] action] == @selector(newFolderWithSelection:)
				      && [[groupRows objectAtIndex:2] action] == @selector(compress:)
				      && [[groupRows objectAtIndex:7] action] == @selector(moveToTrash:),
				      "and the group's rows send the group's commands");
				check([[groupRows objectAtIndex:1] target] == view,
				      "aimed at the grid the click landed in");
				check([grouped indexOfItemWithTitle:@"Rename"] == (NSInteger)NSNotFound,
				      "and an offer to rename MANY names is not one of them");
			}

			/* A click OUTSIDE the group narrows to what it landed on. The group is two NAMED items and the click is a
			 * third, so which ones the grid happens to sort where cannot change what this measures. */
			{
				NSInteger a = indexNamed(view, @"Documents");
				NSInteger b = notes;
				NSInteger third = -1;
				NSInteger i;

				for (i = 0; i < [view itemCount]; i++) {
					if (i != a && i != b) {
						third = i;
						break;
					}
				}
				check(a >= 0 && b >= 0 && third >= 0, "the probe has three distinct icons to click");
				if (third >= 0) {
					[view selectIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 0)]];
					[view selectIndex:a];
					[view keyDown:key(NSRightArrowFunctionKey, NSShiftKeyMask)];
					menu = [view menuForEvent:mouse(NSRightMouseDown, centerOfIndex(view, third))];
					check([[view selectedIndexes] count] == 1 && [view selectedIndex] == third
					      && [menu numberOfItems] == 8
					      && [menu indexOfItemWithTitle:@"Rename"] != (NSInteger)NSNotFound
					      && [menu indexOfItemWithTitle:@"Compress"] != (NSInteger)NSNotFound,
					      "and a right-click outside the group narrows to that icon's own menu");
				}
			}

			/* **NEW FOLDER WITH SELECTION GATHERS THE GROUP INTO A FOLDER OF ITS OWN.** Two files of its own, because
			 * this command TAKES what it gathers out of the grid — the rows below are still about `menu.txt`. */
			{
				NSString *made = [root stringByAppendingPathComponent:@"New Folder with Selection"];

				makeFile([root stringByAppendingPathComponent:@"gather-a.txt"]);
				makeFile([root stringByAppendingPathComponent:@"gather-b.txt"]);
				[view reloadAfterChange];
				[view selectIndex:indexNamed(view, @"gather-a.txt")];
				[view keyDown:key(NSRightArrowFunctionKey, NSShiftKeyMask)];
				check([[view selectedIndexes] count] == 2, "two files are held for the gather");
				[view newFolderWithSelection:nil];
				check([[NSFileManager defaultManager] fileExistsAtPath:made]
				      && [[NSFileManager defaultManager]
					  fileExistsAtPath:[made stringByAppendingPathComponent:@"gather-a.txt"]],
				      "New Folder with Selection makes a folder and moves the group into it");
				check([[view cg_selectedPaths] count] == 1
				      && [[[view cg_selectedPaths] objectAtIndex:0] isEqual:made],
				      "and the folder it made is what the grid holds");
			}
		}
		/* ---- AND THE EMPTY GRID ASKS THE FOLDER'S OWN QUESTIONS ---- */
		{
			NSMenu *background = [view menuForEvent:mouse(NSRightMouseDown, NSMakePoint(390.0, 390.0))];
			NSArray *bgRows = (background != nil) ? [background itemArray] : nil;

			check([bgRows count] == 4, "a right-click on empty grid answers the folder's own menu, not nothing");
			if ([bgRows count] == 4) {
				check([[[bgRows objectAtIndex:0] title] isEqual:@"New Folder"]
				      && [[bgRows objectAtIndex:1] isSeparatorItem]
				      && [[[bgRows objectAtIndex:2] title] isEqual:@"Paste"]
				      && [[[bgRows objectAtIndex:3] title] isEqual:@"Select All"],
				      "New Folder | Paste, Select All — the reference file manager's rows and its separator");
				check([[bgRows objectAtIndex:0] action] == @selector(newFolder:)
				      && [[bgRows objectAtIndex:2] action] == @selector(paste:)
				      && [[bgRows objectAtIndex:3] action] == @selector(selectAll:),
				      "and each row sends its own command");
				check([[bgRows objectAtIndex:0] target] == view && [[bgRows objectAtIndex:3] target] == view,
				      "aimed at the grid the click landed in");
				[background update];
				check([[bgRows objectAtIndex:0] isEnabled] && [[bgRows objectAtIndex:3] isEnabled],
				      "New Folder and Select All are live");
			}

			/* New Folder makes one in this grid's directory, and the new folder is what the hand is on. */
			{
				NSInteger before = [view itemCount];
				NSInteger held;
				int finishes = probe->finishes;

				[view newFolder:nil];
				held = [view selectedIndex];
				check([view itemCount] == before + 1 && held >= 0
				      && [[[[[view model] items] objectAtIndex:(NSUInteger)held] name]
					  hasPrefix:@"untitled folder"],
				      "New Folder makes a folder in the grid's directory and holds it");
				check(probe->finishes > finishes,
				      "and the window that owns the grid is told the OPERATION is over (it closes the progress plate)");
			}

			/* Select All holds everything the grid can show. */
			[view selectIndex:-1];
			[view selectAll:nil];
			check([[view selectedIndexes] count] == (NSUInteger)[view itemCount],
			      "Select All holds every item in the grid");
		}

		/* ---- COPY IS THE PATHS ON THE GENERAL PASTEBOARD ---- */
		{
			NSArray *onPasteboard;

			[view selectIndex:notes];
			[view copy:nil];
			onPasteboard = [[NSPasteboard generalPasteboard] propertyListForType:NSFilenamesPboardType];
			check([onPasteboard count] == 1
			      && [[onPasteboard objectAtIndex:0] isEqual:[root stringByAppendingPathComponent:@"menu.txt"]],
			      "Copy leaves the selected item's path on the general pasteboard, in the drag's own type");
		}

		/* ---- RENAME IS THE INLINE FIELD OVER THE LABEL ---- */
		[view selectIndex:indexNamed(view, @"menu.txt")];
		[view rename:nil];
		check([view isRenaming] && [view cg_renameField] != nil,
		      "Rename opens the inline field over the selected icon's label");
		[[view cg_renameField] setStringValue:@"menu-renamed.txt"];
		check([view commitRenaming]
		      && [[NSFileManager defaultManager] fileExistsAtPath:[root stringByAppendingPathComponent:@"menu-renamed.txt"]],
		      "and committing it renames the file on disk");

		/* ---- MOVE TO TRASH GOES THROUGH W6'S OPERATION, INTO A TRASH OF THE PROBE'S OWN ---- */
		{
			NSInteger count = [view itemCount];
			NSString *doomed = [root stringByAppendingPathComponent:@"menu-renamed.txt"];

			[view selectIndex:indexNamed(view, @"menu-renamed.txt")];
			[view moveToTrash:nil];
			check(![[NSFileManager defaultManager] fileExistsAtPath:doomed]
			      && [view itemCount] == count - 1,
			      "Move to Trash takes the item off the grid and out of the directory");
			check([[NSFileManager defaultManager] fileExistsAtPath:trashRoot],
			      "and the probe's own trash received it, not the account's");
		}

		/* ---- AND THE DESKTOP OFFERS THE SAME MENU AND ANSWERS IT TOO ---- */
		{
			WSDesktopView *desktop = [[WSDesktopView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 520.0, 400.0)
								     directory:root];
			NSWindow *desktopWindow = [[NSWindow alloc]
				initWithContentRect:NSMakeRect(0.0, 0.0, 520.0, 400.0)
					  styleMask:NSBorderlessWindowMask
					    backing:NSBackingStoreBuffered defer:NO];
			NSArray *items = [[desktop model] items];
			NSInteger index = -1;
			NSInteger i;

			[desktopWindow setContentView:desktop];
			[desktop setFileOperations:operations];
			for (i = 0; i < (NSInteger)[items count]; i++) {
				if ([[[items objectAtIndex:(NSUInteger)i] name] isEqual:@"Archive"]) {
					index = i;
					break;
				}
			}
			check(index >= 0, "the desktop's grid holds the folder the next checks act on");
			if (index >= 0) {
				NSPoint cell = [[[desktop cg_positions] objectAtIndex:(NSUInteger)index] pointValue];
				NSPoint click = NSMakePoint(cell.x + 32.0, 400.0 - (cell.y + 32.0));
				NSMenu *desktopMenu = [desktop menuForEvent:mouse(NSRightMouseDown, click)];

				check(desktopMenu != nil && [desktopMenu numberOfItems] == 8,
				      "the desktop's right-click raises the same eight-row menu, Compress among them");
				check([[desktop cg_selection] count] == 1,
				      "and it selects the icon under the pointer first");

				/* The desktop's rename is a field over the label, which on this unflipped view hangs BELOW the icon. */
				[desktop rename:nil];
				check([desktop isRenaming] && [desktop cg_renameField] != nil,
				      "Rename on the desktop opens a field over the icon's name");
				{
					NSRect field = [[desktop cg_renameField] frame];
					NSRect wash = [desktop cg_highlightRectAtIndex:index];

					check(near(NSMidX(field), NSMidX(wash))
					      && NSMinY(field) >= NSMinY(wash) && NSMaxY(field) <= NSMaxY(wash),
					      "and the field sits where the name is drawn: centred, inside the cell's foot");
				}
				[[desktop cg_renameField] setStringValue:@"Archive-renamed"];
				check([desktop commitRenaming]
				      && [[NSFileManager defaultManager] fileExistsAtPath:
								[ root stringByAppendingPathComponent:@"Archive-renamed"]],
				      "and committing it renames the folder on disk");
				check([[desktop cg_selection] count] == 1,
				      "the renamed item is what the desktop holds afterwards");

				/* **AND THE EMPTY DESKTOP ASKS THE SAME THREE QUESTIONS.** The band this click is nowhere near:
				 * the grid places its icons from the top right, so the bottom-left corner is a cell nothing holds. */
				{
					NSMenu *background = [desktop menuForEvent:mouse(NSRightMouseDown,
											 NSMakePoint(20.0, 20.0))];
					NSArray *bgRows = (background != nil) ? [background itemArray] : nil;
					NSInteger items = (NSInteger)[[[desktop model] items] count];

					check([bgRows count] == 4
					      && [[[bgRows objectAtIndex:0] title] isEqual:@"New Folder"]
					      && [[[bgRows objectAtIndex:3] title] isEqual:@"Select All"],
					      "the empty desktop answers the folder's menu, as its grid does");
					[desktop newFolder:nil];
					check((NSInteger)[[[desktop model] items] count] == items + 1
					      && [[desktop cg_selection] count] == 1,
					      "New Folder makes one in the desktop's directory and holds it");
					[desktop selectAll:nil];
					check([[desktop cg_selection] count] == [[desktop cg_positions] count],
					      "Select All holds every icon the desktop can show");

					/* **AND THE GROUP'S MENU IS THE SAME LIST HERE**, which is the whole point of one builder: two icons
					 * held, a click on one of them, and the rows are the group's rather than one item's. */
					{
						NSArray *two = [desktop cg_positions];

						if ([two count] >= 2) {
							NSArray *items = [[desktop model] items];
							NSArray *held = [NSArray arrayWithObjects:
								[[items objectAtIndex:0] path], [[items objectAtIndex:1] path], nil];
							NSPoint cell = [[two objectAtIndex:0] pointValue];
							NSMenu *group;

							[desktop cg_selectPaths:held];
							group = [desktop menuForEvent:mouse(NSRightMouseDown,
											   NSMakePoint(cell.x + 32.0,
												       400.0 - (cell.y + 32.0)))];
							check([[desktop cg_selection] count] == 2
							      && [group numberOfItems] == 8
							      && [group indexOfItemWithTitle:@"New Folder with Selection"]
								  != (NSInteger)NSNotFound,
							      "the desktop's group menu is the same list, with New Folder with Selection");
						}
					}
				}
			}

			[desktop release];
			[desktopWindow release];
		}

		[operations release];
		[trash release];
		[[NSFileManager defaultManager] removeItemAtPath:trashRoot error:NULL];
	}

	/* 10. OPENING FROM THE KEYBOARD GOES THROUGH THE DELEGATE. */
	[view selectIndex:indexNamed(view, @"Documents")];
	[view keyDown:key(NSDownArrowFunctionKey, NSCommandKeyMask)];
	check(probe->opened != nil && [probe->opened isEqual:@"Documents"],
	      "Command-Down asks the delegate to open the selected folder/item");

	[probe release];
	[window release];
	[view release];
	[model release];
	[[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
	[[NSFileManager defaultManager] removeItemAtPath:sourceRoot error:NULL];
	[[NSFileManager defaultManager] removeItemAtPath:otherRoot error:NULL];

	printf("icon_view: %s\n", s_failed == 0 ? "all checks passed" : "FAILURES");
	return s_failed == 0 ? 0 : 1;
}
